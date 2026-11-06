#!/usr/bin/env bash
# audit-infographic.sh — the weekly audit's *Week in numbers* as one PNG for
# the report's Slack thread (docs/audit.md → **Infographic**).
#
# The agent writes the report; this script draws it. It reads the composed
# report text and never recomputes a number. Each bullet is cut into its parts
# at " · " and " — " (and at ", " for the severity and hot-area lists); the
# picture shows the parts it has a place for, and `rest` is every other part,
# per bullet — the text that goes under the picture, so no number is lost.
#
#   renderer                       which headless browser draws the PNG
#   html <report-file>             the page, on stdout
#   rest <report-file>             the parts the page leaves out, on stdout
#   render <report-file> <out.png>
#
# `renderer` and `render` print one JSON object and exit 0: {outcome:"ok",
# renderer, path?, rest?} | {outcome:"no_renderer", rest?} | {outcome:"error",
# error}. The renderer is the first of chromium, chromium-browser,
# google-chrome, google-chrome-stable, chrome-headless-shell and chrome on
# PATH, then the macOS Chrome app; CG_INFOGRAPHIC_RENDERERS replaces that
# list (tests). Requires bash, sed, grep, od, jq — awk-free.

set -u
export LC_ALL=C

W=1200 H=965      # page size in CSS px (fixed card heights); the PNG is twice that
MAC_CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"

out() { printf '%s\n' "$1"; exit 0; }
fail() { out "$(jq -nc --arg e "$1" '{outcome:"error", error:$e}')"; }

find_renderer() {
  local c
  for c in ${CG_INFOGRAPHIC_RENDERERS:-chromium chromium-browser google-chrome google-chrome-stable chrome-headless-shell chrome}; do
    command -v "$c" 2>/dev/null && return 0
  done
  [ -z "${CG_INFOGRAPHIC_RENDERERS:-}" ] && [ -x "$MAC_CHROME" ] && { printf '%s\n' "$MAC_CHROME"; return 0; }
  return 1
}

esc() { printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'; }

# 1228.99 → 1,229
money() {
  local n="${1//,/}" i f r=""
  i="${n%%.*}"; f="${n#"$i"}"; f="${f#.}"
  [ -n "$f" ] && [ "${f:0:1}" -ge 5 ] 2>/dev/null && i=$((i + 1))
  while [ "${#i}" -gt 3 ]; do r=",${i: -3}$r"; i="${i:0:${#i}-3}"; done
  printf '%s%s' "$i" "$r"
}

# 32471188 → 32.5 M, 428768 → 428.8 k
human() {
  local n="$1" t
  if [ "$n" -ge 1000000 ]; then t=$(( (n + 50000) / 100000 )); printf '%s.%s M' $((t / 10)) $((t % 10))
  elif [ "$n" -ge 1000 ]; then t=$(( (n + 50) / 100 )); printf '%s.%s k' $((t / 10)) $((t % 10))
  else printf '%s' "$n"; fi
}

pct() { [ "$2" -gt 0 ] && printf '%s' $(( ($1 * 200 + $2) / ($2 * 2) )) || printf '0'; }

# ▲… → up, ▼… → down, else flat
trend_class() { case "$1" in ("▲"*) printf up;; ("▼"*) printf down;; (*) printf flat;; esac; }

# the report's header, *Week in numbers* line and bullets → globals
parse() {
  local f="$1" line in=0 l v
  HEAD=""; SINCE=""; LABELS=(); VALUES=()
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"
    case "$line" in
      (*"weekly audit"*) [ -z "$HEAD" ] && HEAD="$line";;
    esac
    if [ "$in" = 0 ]; then
      case "$line" in
        ("*Week in numbers*"*)
          in=1; SINCE="${line#*since }"; SINCE="${SINCE%)*}"
          [ "$SINCE" = "$line" ] && SINCE="";;
      esac
      continue
    fi
    case "$line" in
      ("• "*) line="${line#• }"
        if [ "${line#*: }" != "$line" ]; then l="${line%%: *}"; v="${line#*: }"; else l=""; v="$line"; fi
        LABELS+=("$l"); VALUES+=("$v");;
      ("") [ "${#LABELS[@]}" -gt 0 ] && break;;
      (*) break;;
    esac
  done < "$f"
  segment
}

# every bullet → its parts: SEG_I (bullet index), SEG_T (text), SEG_U (used)
segment() {
  local i v p
  SEG_I=(); SEG_T=(); SEG_U=()
  for i in "${!LABELS[@]}"; do
    v="${VALUES[$i]// · /$'\n'}"; v="${v// — /$'\n'}"
    case "${LABELS[$i]}" in ('Findings acceptance by severity'|'Findings sit in') v="${v//, /$'\n'}";; esac
    while IFS= read -r p; do
      [ -n "$p" ] || continue
      SEG_I+=("$i"); SEG_T+=("$p"); SEG_U+=(0)
    done <<< "$v"
  done
}

# take <label-prefix> <regex>: the first unused part of a bullet with that
# label matching the regex; marks it used, leaves BASH_REMATCH set. peek: the
# same without marking.
take() { _find "$@" && SEG_U[$J]=1; }
peek() { _find "$@"; }
_find() {
  local j
  for j in "${!SEG_T[@]}"; do
    case "${LABELS[${SEG_I[$j]}]}" in ("$1"*) ;; (*) continue;; esac
    [ "${SEG_U[$j]}" = 0 ] || continue
    [[ ${SEG_T[$j]} =~ $2 ]] && { J=$j; return 0; }
  done
  return 1
}

# the unused parts, one bullet per line, in report order
rest() {
  local i j line
  for i in "${!LABELS[@]}"; do
    line=""
    for j in "${!SEG_T[@]}"; do
      [ "${SEG_I[$j]}" = "$i" ] && [ "${SEG_U[$j]}" = 0 ] || continue
      line="${line:+$line · }${SEG_T[$j]}"
    done
    [ -n "$line" ] && printf '• %s%s\n' "${LABELS[$i]:+${LABELS[$i]}: }" "$line"
  done
  return 0
}

tile() { # <label> <value> <note-html>
  printf '<div class="card kpi"><div class="k-label">%s</div><div class="k-val">%s</div><div class="k-note">%s</div></div>\n' \
    "$(esc "$1")" "$(esc "$2")" "$3"
}
delta() { # <delta text> [neutral] → a coloured span and a separator, or nothing
  [ -n "$1" ] || return 0
  local c; c="$(trend_class "$1")"; [ "${2:-}" = neutral ] && c=flat
  printf '<span class="%s">%s</span> · ' "$c" "$(esc "$1")"
}
stat() { printf '<div class="stat"><span>%s</span><b>%s</b></div>' "$(esc "$1")" "$(esc "$2")"; }
mini() { printf '<div><b>%s</b><span>%s</span></div>' "$(esc "$1")" "$(esc "$2")"; }
alert() { # <colour> <mark> <title> <detail>
  printf '<div class="alert"><div class="ic" style="background:var(--%s)">%s</div><div><b>%s</b><small>%s</small></div></div>' \
    "$1" "$2" "$(esc "$3")" "$(esc "$4")"
}

# builds the page into PAGE; marks what it shows as used
build() {
  local name="Code review agent" date="" ok=0 warn=0 red=0
  [[ $HEAD =~ \*([^*]+)\ weekly\ audit\* ]] && name="${BASH_REMATCH[1]}"
  [[ $HEAD =~ audit\*\ —\ ([^ ]+) ]] && date="${BASH_REMATCH[1]}"
  [[ $HEAD =~ 🟢\ ([0-9]+) ]] && ok="${BASH_REMATCH[1]}"
  [[ $HEAD =~ 🟡\ ([0-9]+) ]] && warn="${BASH_REMATCH[1]}"
  [[ $HEAD =~ 🔴\ ([0-9]+) ]] && red="${BASH_REMATCH[1]}"

  # trend deltas
  local d_rev="" d_acc="" d_cov="" d_new=""
  take Trend 'reviews [0-9]+ \(([^)]*)\)' && d_rev="${BASH_REMATCH[1]}"
  take Trend 'acceptance [0-9]+% \(([^)]*)\)' && d_acc="${BASH_REMATCH[1]}"
  take Trend 'coverage [0-9]+% \(([^)]*)\)' && d_cov="${BASH_REMATCH[1]}"
  take Trend '^new findings ([0-9]+ \([^)]*\))' && d_new="${BASH_REMATCH[1]}"

  # --- headline tiles
  local t_rev="—" n_rev="not in this report"
  if take Reviews '^([0-9]+) \(([0-9]+) first / ([0-9]+) re\)$'; then
    t_rev="${BASH_REMATCH[1]}"; n_rev="$(delta "$d_rev" neutral)${BASH_REMATCH[2]} first / ${BASH_REMATCH[3]} re"
  fi
  local t_acc="—" n_acc="not measured"
  if take 'Findings acceptance' '^([0-9]+)/([0-9]+) fixed'; then
    t_acc="$(pct "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}") %"
    n_acc="$(delta "$d_acc")${BASH_REMATCH[1]} of ${BASH_REMATCH[2]} by next re-review"
  fi
  local t_cov="—" n_cov="not measured" merged=0 reviewed=0 covp=""
  if take Project '^([0-9]+)/([0-9]+) merged PRs reviewed \(([0-9]+)%\)$'; then
    reviewed="${BASH_REMATCH[1]}"; merged="${BASH_REMATCH[2]}"; covp="${BASH_REMATCH[3]}"
    t_cov="$covp %"; n_cov="$(delta "$d_cov")$reviewed of $merged merged PRs reviewed"
  fi
  local t_sp="—" n_sp="not measured"
  if take Spend '^\$([0-9][0-9.,]*) actual'; then t_sp="\$$(money "${BASH_REMATCH[1]}")"; n_sp="actual"
  elif take Spend '^est \$([0-9][0-9.,]*)$'; then t_sp="\$$(money "${BASH_REMATCH[1]}")"; n_sp="estimate"; fi
  take Spend '^per review (est )?\$([0-9.]+)' && n_sp="\$${BASH_REMATCH[2]} per review · $n_sp"

  # --- verdicts
  local ap="" cm="" rc="" verdicts=""
  if take Reviews '✅[^0-9]*([0-9]+)'; then
    ap="${BASH_REMATCH[1]}"
    [[ ${SEG_T[$J]} =~ ⚠[^0-9]*([0-9]+) ]] && cm="${BASH_REMATCH[1]}"
    [[ ${SEG_T[$J]} =~ ❌[^0-9]*([0-9]+) ]] && rc="${BASH_REMATCH[1]}"
  elif take Reviews '^([0-9]+) ([0-9]+) ([0-9]+)$'; then  # the emoji lost in a copy
    ap="${BASH_REMATCH[1]}"; cm="${BASH_REMATCH[2]}"; rc="${BASH_REMATCH[3]}"
  fi
  if [ -n "$ap" ]; then
    local a="${ap:-0}" c="${cm:-0}" r="${rc:-0}" tot
    tot=$((a + c + r)); [ "$tot" -gt 0 ] || tot=1
    verdicts="<h2>Review verdicts <small>$((a + c + r)) reviews</small></h2><div class=\"stack\">"
    verdicts+="<div style=\"flex:$a;background:var(--green)\">$( [ $((a * 100 / tot)) -ge 6 ] && printf '%s' "$a")</div>"
    verdicts+="<div style=\"flex:$c;background:var(--amber)\">$( [ $((c * 100 / tot)) -ge 6 ] && printf '%s' "$c")</div>"
    verdicts+="<div style=\"flex:$r;background:var(--red)\">$( [ $((r * 100 / tot)) -ge 6 ] && printf '%s' "$r")</div></div>"
    verdicts+="<div class=\"legend\"><span><i class=\"dot\" style=\"background:var(--green)\"></i>Approve $a</span>"
    verdicts+="<span><i class=\"dot\" style=\"background:var(--amber)\"></i>Comment $c</span>"
    verdicts+="<span><i class=\"dot\" style=\"background:var(--red)\"></i>Request changes $r</span></div>"
  fi

  # --- severity bars
  local sev="" s fx al col
  while take 'Findings acceptance by severity' '^([a-z]+) ([0-9]+)/([0-9]+)$'; do
    s="${BASH_REMATCH[1]}"; fx="${BASH_REMATCH[2]}"; al="${BASH_REMATCH[3]}"
    case "$s" in (critical) col=red;; (warning) col=amber;; (suggestion) col=blue;; (*) col=grey;; esac
    sev+="<div class=\"bar\"><div class=\"lbl\"><span>$(esc "$s")</span><b>$fx / $al · $(pct "$fx" "$al") %</b></div>"
    sev+="<div class=\"track\"><div class=\"fill\" style=\"width:$(pct "$fx" "$al")%;background:var(--$col)\"></div></div></div>"
  done
  [ -n "$sev" ] && sev="<h2 style=\"margin-top:18px\">Findings fixed by severity <small>$( [ -n "$d_new" ] && printf '%s new findings' "$(esc "$d_new")")</small></h2>$sev"

  # --- review quality
  local q_mini="" q_rows=""
  take 'Refuted before posting' '^([0-9]+)$' && q_mini+="$(mini "${BASH_REMATCH[1]}" 'refuted before post')"
  if take 'Review style' '^([0-9]+)/([0-9]+) sentences over 20 words, average ([0-9.]+)$'; then
    local o="${BASH_REMATCH[1]}" t="${BASH_REMATCH[2]}" avg="${BASH_REMATCH[3]}" sh
    sh=$(( t > 0 ? (o * 1000 + t / 2) / t : 0 ))
    q_mini+="$(mini "$avg" 'avg words / sentence')$(mini "$((sh / 10)).$((sh % 10)) %" 'sentences > 20 words')"
  fi
  take 'Refuted before posting' '^overrides ([0-9]+) / context ([0-9]+) / decisions ([0-9]+)$' \
    && q_rows+="$(stat 'Context / overrides / decisions' "${BASH_REMATCH[2]} / ${BASH_REMATCH[1]} / ${BASH_REMATCH[3]}")"
  local ttfr=""
  if take 'Median time-to-first-review' '^(.*) \(review itself ([^,]+), n=([0-9]+)\)$'; then
    ttfr="${BASH_REMATCH[1]}"; q_rows+="$(stat "Review duration (median, n=${BASH_REMATCH[3]})" "${BASH_REMATCH[2]}")"
  fi
  local k=0
  while [ "$k" -lt 2 ] && take 'Review time by phase' '^([a-z_]+) (.+) \(n=[0-9]+\)$'; do
    q_rows+="$(stat "— ${BASH_REMATCH[1]//_/ } phase" "${BASH_REMATCH[2]}")"; k=$((k + 1))
  done
  take 'Wasted reviews' '.' && q_rows+="$(stat 'Wasted reviews' "${SEG_T[$J]}")"

  # --- project
  local p_rows=""
  take 'Median time-to-first-review' '^Open PRs: ([0-9]+)$' && p_rows+="$(stat 'Open PRs' "${BASH_REMATCH[1]}")"
  take 'Median time-to-first-review' '^awaiting_label: ([0-9]+)$' && p_rows+="$(stat 'Awaiting label' "${BASH_REMATCH[1]}")"
  take Project '^median PR ([0-9]+) files / ([0-9]+) lines' && p_rows+="$(stat 'Median PR size' "${BASH_REMATCH[1]} files · ${BASH_REMATCH[2]} lines")"
  take Project '^first human review (.+) \(n=[0-9]+\)$' && p_rows+="$(stat 'First human review (median)' "${BASH_REMATCH[1]}")"
  take Project '^merge conflicts: ([0-9]+) PRs?$' && p_rows+="$(stat 'PRs with merge conflicts' "${BASH_REMATCH[1]}")"
  take Project '^abandoned after review: ([0-9]+) PRs?$' && p_rows+="$(stat 'Abandoned after review' "${BASH_REMATCH[1]}")"
  take Project '^review rounds ([0-9.]+) \(n=([0-9]+)\)$' && p_rows+="$(stat "Review rounds (median, n=${BASH_REMATCH[2]})" "${BASH_REMATCH[1]}")"
  [ -n "$ttfr" ] && p_rows+="$(stat 'Time to first review' "$ttfr")"

  # --- needs attention
  local att=""
  if take Nudges '^reviewed ≤48h after nudge: ([0-9]+)/([0-9]+)$'; then
    local x="${BASH_REMATCH[1]}" y="${BASH_REMATCH[2]}" more=""
    take Nudges '^([0-9]+) PRs nudged' && more="${SEG_T[$J]}"
    take Nudges '^held/L4: ' && more="${more:+$more · }${SEG_T[$J]}"
    if [ "$y" -gt 0 ] && [ $((x * 2)) -lt "$y" ]; then att+="$(alert red '!' "Reviewed ≤ 48 h after a nudge: $x / $y" "$more")"
    else att+="$(alert green '✓' "Reviewed ≤ 48 h after a nudge: $x / $y" "$more")"; fi
  fi
  if take Log '^([0-9]+) errors / ([0-9]+) warns( \((.*)\))?$'; then
    local e="${BASH_REMATCH[1]}" wn="${BASH_REMATCH[2]}" rec="${BASH_REMATCH[4]}"
    att+="$(alert "$( [ "$e" -gt 0 ] && printf amber || printf green)" "$( [ "$e" -gt 0 ] && printf '!' || printf '✓')" "$e errors · $wn warnings in the log" "$rec")"
  fi
  if [ -n "$covp" ]; then
    local cc=green cm2='✓'; [ "$(trend_class "$d_cov")" = down ] && { cc=amber; cm2='!'; }
    att+="$(alert "$cc" "$cm2" "Coverage $covp %${d_cov:+ ($d_cov)}" "$((merged - reviewed)) merged PRs had no review")"
  fi
  if take 'Reactions on my comments' '^👍 ?([0-9]+)$'; then
    local up="${BASH_REMATCH[1]}" dn=0 note=""
    take 'Reactions on my comments' '^👎 ?([0-9]+)$' && dn="${BASH_REMATCH[1]}"
    take 'Reactions on my comments' '.' && note="${SEG_T[$J]}"
    if [ "$up$dn" = 00 ]; then att+="$(alert grey '?' 'No reactions on bot comments' "👍 0 · 👎 0${note:+ — $note}")"
    else att+="$(alert "$( [ "$dn" -gt 0 ] && printf amber || printf green)" '·' "Reactions: 👍 $up · 👎 $dn" "$note")"; fi
  fi

  # --- operations
  local o_mini="" o_rows=""
  if take Heartbeats '^([0-9]+) \(([0-9]+) idle\)$'; then
    o_mini+="$(mini "$(money "${BASH_REMATCH[1]}")" "heartbeats · $(pct "${BASH_REMATCH[2]}" "${BASH_REMATCH[1]}") % idle")"
  fi
  local wk=""
  if take Wake-ups '^([0-9]+)$'; then o_mini+="$(mini "${BASH_REMATCH[1]}" 'wake-up runs')"; fi
  take Wake-ups '[a-z]+ [0-9]+' && wk="${SEG_T[$J]}"
  if take Tokens '^([0-9]+) out / ([0-9]+) cache-read / ([0-9]+) cache-write across ([0-9]+) runs$'; then
    o_mini+="$(mini "$(human "${BASH_REMATCH[2]}")" 'cache-read tokens')"
    o_rows+="$(stat "Tokens out / cache-write (${BASH_REMATCH[4]} runs)" "$(human "${BASH_REMATCH[1]}") / $(human "${BASH_REMATCH[3]}")")"
  fi
  [ -n "$wk" ] && o_rows="$(stat 'Wake-ups by kind' "$wk")$o_rows"
  local rs_n="" rs=""
  take 'Review shape' '^([0-9]+) reviews$' && rs_n="${BASH_REMATCH[1]}"
  take 'Review shape' '^median ([0-9]+)s$' && rs="${BASH_REMATCH[1]} s"
  take 'Review shape' '^([0-9]+) msgs$' && rs="${rs:+$rs · }${BASH_REMATCH[1]} msgs"
  take 'Review shape' '^peak ctx ([0-9]+)$' && rs="${rs:+$rs · }ctx $(human "${BASH_REMATCH[1]}")"
  [ -n "$rs" ] && o_rows+="$(stat "Review shape (median${rs_n:+, $rs_n reviews})" "$rs")"
  if take Memory '^archived [0-9]+$'; then
    local mm="" t2
    SEG_U[$J]=0
    while take Memory '^([a-z]+) ([0-9]+)$'; do
      [ "${BASH_REMATCH[2]}" = 0 ] || { t2="${BASH_REMATCH[2]} ${BASH_REMATCH[1]}"; mm="${mm:+$mm · }$t2"; }
    done
    o_rows+="$(stat Memory "${mm:-no change}")"
  fi

  PAGE="$(cat <<EOF
<!doctype html>
<html><head><meta charset="utf-8"><title>$(esc "$name") weekly audit</title>
<style>
:root{--bg:#f6f7f9;--card:#fff;--ink:#14171c;--mute:#667085;--line:#e4e7ec;
--green:#12a150;--amber:#e3a008;--red:#d92d20;--blue:#2e6be6;--grey:#c5cad3}
*{box-sizing:border-box;margin:0;padding:0}
html,body{background:var(--bg)}
body{font:15px/1.35 -apple-system,"Segoe UI","Helvetica Neue",Arial,"Noto Sans",sans-serif;color:var(--ink);width:${W}px;padding:28px}
h1{font-size:26px;font-weight:700;letter-spacing:-.3px}
.sub{color:var(--mute);font-size:14px;margin-top:4px}
.head{display:flex;justify-content:space-between;align-items:flex-end;height:60px;margin-bottom:20px}
.pill{display:inline-block;padding:4px 10px;border-radius:999px;font-size:13px;font-weight:600;margin-left:6px}
.p-g{background:#e3f6ea;color:#0c7a3c}.p-a{background:#fdf3d6;color:#8a5a00}.p-r{background:#fde7e5;color:#a8170d}
.grid{display:grid;gap:14px;margin-bottom:14px}
.kpis{grid-template-columns:repeat(4,1fr)}
.card{background:var(--card);border:1px solid var(--line);border-radius:14px;padding:18px 20px;overflow:hidden}
.kpi{height:136px}.row3 .card{height:340px}.row2 .card{height:300px}
.k-label{color:var(--mute);font-size:13px;font-weight:600;text-transform:uppercase;letter-spacing:.5px}
.k-val{font-size:40px;font-weight:750;letter-spacing:-1px;margin:4px 0 2px;font-variant-numeric:tabular-nums}
.k-note{font-size:13px;color:var(--mute);white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.up{color:var(--green);font-weight:700}.down{color:var(--red);font-weight:700}.flat{color:var(--ink);font-weight:700}
.row3{grid-template-columns:1.15fr 1fr 1fr}
.row2{grid-template-columns:1fr 1fr}
h2{font-size:15px;font-weight:700;margin-bottom:12px;display:flex;justify-content:space-between;align-items:center}
h2 small{font-weight:500;color:var(--mute);font-size:12px}
.stack{display:flex;height:30px;border-radius:8px;overflow:hidden;margin:6px 0 10px}
.stack div{display:flex;align-items:center;justify-content:center;color:#fff;font-weight:700;font-size:13px}
.legend{display:flex;gap:14px;font-size:13px;color:var(--mute);flex-wrap:wrap}
.dot{display:inline-block;width:10px;height:10px;border-radius:3px;margin-right:5px;vertical-align:-1px}
.bar{margin:9px 0}.bar .lbl{display:flex;justify-content:space-between;font-size:13px;margin-bottom:4px;text-transform:capitalize}
.bar .lbl b{font-variant-numeric:tabular-nums}
.track{height:12px;background:#eef0f3;border-radius:6px;overflow:hidden}.fill{height:100%;border-radius:6px}
.stat{display:flex;justify-content:space-between;gap:12px;padding:7px 0;border-bottom:1px solid var(--line);font-size:14px}
.stat:last-child{border-bottom:0}
.stat span{color:var(--mute);white-space:nowrap}
.stat b{font-variant-numeric:tabular-nums;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.alert{display:flex;gap:10px;align-items:flex-start;padding:9px 0;border-bottom:1px solid var(--line);font-size:14px}
.alert:last-child{border-bottom:0}
.alert>div:last-child{min-width:0}
.alert .ic{flex:0 0 22px;height:22px;border-radius:6px;display:flex;align-items:center;justify-content:center;font-weight:800;font-size:13px;color:#fff}
.alert small{display:block;color:var(--mute);font-size:12.5px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.mini{display:grid;grid-template-columns:repeat(3,1fr);gap:10px;margin-bottom:12px}
.mini div{background:#f3f5f8;border-radius:10px;padding:10px 12px}
.mini b{display:block;font-size:22px;font-variant-numeric:tabular-nums}
.mini span{font-size:12px;color:var(--mute)}
.foot{color:var(--mute);font-size:12px}
</style></head><body>
<div class="head"><div><h1>🩺 $(esc "$name") — weekly audit</h1>
<div class="sub">$(esc "$date")$( [ -n "$SINCE" ] && printf ' · since %s' "$(esc "$SINCE")")</div></div>
<div><span class="pill p-g">$ok ok</span><span class="pill p-a">$warn warn</span><span class="pill p-r">$red fail</span></div></div>
<div class="grid kpis">
$(tile Reviews "$t_rev" "$n_rev")
$(tile 'Findings fixed' "$t_acc" "$n_acc")
$(tile Coverage "$t_cov" "$n_cov")
$(tile Spend "$t_sp" "$n_sp")
</div>
<div class="grid row3">
<div class="card">$verdicts$sev</div>
<div class="card"><h2>Review quality</h2><div class="mini">$q_mini</div>$q_rows</div>
<div class="card"><h2>Project</h2>$p_rows</div>
</div>
<div class="grid row2">
<div class="card"><h2>Needs attention</h2>$att</div>
<div class="card"><h2>Operations</h2><div class="mini">$o_mini</div>$o_rows</div>
</div>
<div class="foot">Weekly audit · the numbers this picture leaves out follow as text</div>
</body></html>
EOF
)"
}

CMD="${1:-}"; shift 2>/dev/null || true
case "$CMD" in
  (renderer)
    r="$(find_renderer)" || out '{"outcome":"no_renderer"}'
    out "$(jq -nc --arg r "$r" '{outcome:"ok", renderer:$r}')";;
  (html|rest)
    [ -f "${1:-}" ] || { printf 'usage: %s %s <report-file>\n' "$0" "$CMD" >&2; exit 2; }
    parse "$1"; build
    if [ "$CMD" = html ]; then printf '%s\n' "$PAGE"; else rest; fi
    exit 0;;
  (render) ;;
  (*) printf 'usage: %s renderer | html <report-file> | rest <report-file> | render <report-file> <out.png>\n' "$0" >&2; exit 2;;
esac

REPORT="${1:-}"; PNG="${2:-}"
[ -f "$REPORT" ] || fail "report file missing"
[ -n "$PNG" ] || fail "no output path"
parse "$REPORT"
[ "${#LABELS[@]}" -gt 0 ] || fail "no *Week in numbers* bullets in the report"
build; REST="$(rest)"
R="$(find_renderer)" || out "$(jq -nc --arg t "$REST" '{outcome:"no_renderer", rest:$t}')"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/cg-infographic.XXXXXX")" || fail "no temp dir"
trap 'rm -rf "$TMP"' EXIT
printf '%s\n' "$PAGE" > "$TMP/page.html"
rm -f "$PNG"
TO=""; command -v timeout >/dev/null 2>&1 && TO="timeout 90"
$TO "$R" --headless=new --no-sandbox --disable-gpu --hide-scrollbars --no-first-run \
  --user-data-dir="$TMP/profile" --force-device-scale-factor=2 \
  --window-size="$W,$H" --screenshot="$PNG" "file://$TMP/page.html" >"$TMP/log" 2>&1
[ -s "$PNG" ] || fail "the renderer wrote no image: $(tail -n 3 "$TMP/log" | tr '\n' ' ')"
[ "$(od -An -tx1 -N4 "$PNG" | tr -d ' \n')" = "89504e47" ] || { rm -f "$PNG"; fail "the renderer output is not a PNG"; }
out "$(jq -nc --arg r "$R" --arg p "$PNG" --arg t "$REST" '{outcome:"ok", renderer:$r, path:$p, rest:$t}')"
