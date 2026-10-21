/* review-guide interactions — the one vetted script of a guide page.
   The page itself carries no script: code-guardian inserts this file before
   </body> after the page passed its checks. Everything here is driven by
   declarative attributes the page writes:
     data-zoom="<id>"   on a map node or a card: a click opens <details id> and scrolls to it
     data-ref="<key>"   on anything: hovering one highlights every element with the same key
     data-tip="<text>"  on anything: a tooltip on hover or tap
     data-kind="<kind>" on a churn tile or treemap box: the legend filters by kind
   Without this script the page still works: every level is a <details>. */
(function () {
  "use strict";
  var doc = document;
  function all(sel, root) { return Array.prototype.slice.call((root || doc).querySelectorAll(sel)); }
  function depth(d) { var n = 0, p = d.parentElement; while (p) { if (p.tagName === "DETAILS") n++; p = p.parentElement; } return n; }
  function openTo(el) { var p = el; while (p) { if (p.tagName === "DETAILS") p.open = true; p = p.parentElement; } }
  function reveal(id) {
    var t = doc.getElementById(id); if (!t) return;
    openTo(t); t.scrollIntoView({ behavior: "smooth", block: "start" });
    t.classList.add("x-flash"); setTimeout(function () { t.classList.remove("x-flash"); }, 1200);
  }

  var css = doc.createElement("style");
  css.textContent =
    ".zoombar{position:sticky;top:0;z-index:5;display:flex;flex-wrap:wrap;gap:6px;align-items:center;padding:8px 0;margin:0 0 10px;background:var(--bg);border-bottom:1px solid var(--line)}" +
    ".zoombar span{font-size:12px;color:var(--muted);margin-right:4px}" +
    ".zoombar button{font:inherit;font-size:13px;border:1px solid var(--line);background:var(--card);color:var(--fg);border-radius:999px;padding:2px 10px;cursor:pointer}" +
    ".zoombar button[aria-pressed=true]{background:var(--accent);border-color:var(--accent);color:#fff}" +
    "[data-zoom]{cursor:pointer}[data-zoom]:focus{outline:2px solid var(--link);outline-offset:2px}" +
    "g.x-hl rect,rect.x-hl{stroke:var(--link)!important;stroke-width:3px!important}" +
    ".x-hl:not(g):not(rect){outline:2px solid var(--link);outline-offset:1px}" +
    ".x-flash{animation:xf 1.2s ease-out}@keyframes xf{0%{box-shadow:0 0 0 4px var(--link)}100%{box-shadow:0 0 0 0 transparent}}" +
    ".x-tip{position:fixed;z-index:9;max-width:280px;padding:6px 8px;border-radius:6px;background:var(--fg);color:var(--bg);font-size:12px;line-height:1.35;pointer-events:none;opacity:0;transition:opacity .12s}" +
    ".x-tip.on{opacity:1}.x-off{opacity:.15}" +
    ".legend [data-kind]{cursor:pointer;user-select:none}.legend [data-kind].x-mute{text-decoration:line-through;opacity:.6}" +
    "details.sec>summary>.zc,h2>.zc{display:inline-flex;gap:2px;margin-left:auto;flex:none;flex-basis:auto;order:0;padding:0}.zc button{font:inherit;font-size:13px;line-height:1;width:24px;height:22px;border:1px solid var(--line);background:var(--card);color:var(--fg);border-radius:6px;cursor:pointer;padding:0}" +
    ".zc button:hover{border-color:var(--link)}h2 .zc{float:right;margin-top:-2px}";
  doc.head.appendChild(css);

  /* SVG labels (the project map): a text wider than the box it starts in
     shrinks, down to 9px, then is cut with "…"; the full text stays as its
     tooltip. Nothing runs over a box edge. */
  all("svg text").forEach(function (t) {
    try {
      var tb = t.getBBox(), cx = tb.x + 1, cy = tb.y + tb.height / 2, box = null;
      Array.prototype.forEach.call(t.parentNode.children, function (r) {
        if (r.tagName.toLowerCase() !== "rect" || box) return;
        var b = r.getBBox();
        if (cx >= b.x && cx <= b.x + b.width && cy >= b.y && cy <= b.y + b.height) box = b;
      });
      if (!box) return;
      var room = box.x + box.width - tb.x - Math.max(4, tb.x - box.x), full = t.textContent;
      if (tb.width <= room) return;
      var size = parseFloat(getComputedStyle(t).fontSize) || 12;
      while (t.getBBox().width > room && size > 9) { size -= 0.5; t.style.fontSize = size + "px"; }
      if (t.getBBox().width > room) {
        var txt = full;
        while (txt.length > 1 && t.getBBox().width > room) { txt = txt.slice(0, -1); t.textContent = txt + "…"; }
      }
      if (t.textContent !== full) {
        var ti = doc.createElementNS("http://www.w3.org/2000/svg", "title"); ti.textContent = full; t.appendChild(ti);
        if (!t.hasAttribute("data-tip")) t.setAttribute("data-tip", full);
      }
    } catch (e) {}
  });

  /* light / dark: the page follows the system until the reader picks one;
     the pick is kept in this browser. The palettes are set here too, so a
     page built from an older template switches as well. The project map's
     own colors give way to the page's. */
  var themeCss = doc.createElement("style");
  themeCss.textContent =
    ":root[data-theme=light]{--bg:#fbfaf8;--fg:#1d1d1f;--muted:#5f6368;--line:#e3e1dc;--card:#fff;--accent:#c2410c;--accent-bg:#fff1e8;--ok:#15803d;--ok-bg:#ecfdf3;--warn:#b45309;--warn-bg:#fff7e6;--link:#1d4ed8;--before:#8a8f98;--k-logic:#c2410c;--k-test:#15803d;--k-docs:#2563eb;--k-mech:#a1a1aa}" +
    ":root[data-theme=dark]{--bg:#141416;--fg:#ececee;--muted:#a1a1aa;--line:#2e2e33;--card:#1c1c20;--accent:#fb923c;--accent-bg:#2a1a10;--ok:#4ade80;--ok-bg:#0f2417;--warn:#fbbf24;--warn-bg:#2a2110;--link:#93c5fd;--before:#71717a;--k-logic:#fb923c;--k-test:#4ade80;--k-docs:#60a5fa;--k-mech:#52525b}" +
    ":root[data-theme]{color-scheme:light dark}:root[data-theme=light]{color-scheme:light}:root[data-theme=dark]{color-scheme:dark}" +
    "main svg .node text{fill:var(--fg)}main svg .node text.sub{fill:var(--muted)}" +
    "main svg .node rect{fill:var(--card);stroke:var(--before)}main svg .node.hl rect{fill:var(--accent-bg);stroke:var(--accent)}" +
    "main svg .grp{stroke:var(--line)}main svg .grpl{fill:var(--muted)}main svg text{fill:var(--fg)}" +
    ".zoombar .theme{margin-left:auto;width:30px;padding:2px 0}" +
    ".term{border-bottom:1px dotted var(--muted);cursor:help}[data-tip]:not(button):not(a):not(details):not(summary):not([data-zoom]){cursor:help}" +
    "main code{font-size:.88em}summary code,.why code,.rk b code{font:inherit;background:none;padding:0}";
  doc.head.appendChild(themeCss);
  var root = doc.documentElement, THEME_KEY = "cg-review-guide-theme";
  function systemDark() { try { return matchMedia("(prefers-color-scheme: dark)").matches; } catch (e) { return false; } }
  function isDark() { var t = root.getAttribute("data-theme"); return t ? t === "dark" : systemDark(); }
  try { var saved = localStorage.getItem(THEME_KEY); if (saved === "dark" || saved === "light") root.setAttribute("data-theme", saved); } catch (e) {}

  /* zoom levels by meaning: 0 overview (all closed) · 1 sections (the seven
     section lines) · 2 details (every zoom without code) · 3 code (all).
     A level that would open nothing more than the one before it is hidden. */
  var names = ["Overview", "Sections", "Details", "Code"], cur = 0;
  var dets = all("details");
  function isCode(d) { return all("pre.diff", d).some(function (p) { return p.closest("details") === d; }); }
  function wants(d, n) {
    if (n === 0) return false;
    if (n === 1) return d.classList.contains("sec");
    if (n === 2) return !isCode(d);
    return true;
  }
  function sig(n) { return dets.map(function (d) { return wants(d, n) ? "1" : "0"; }).join(""); }
  var levels = [0];
  for (var n = 1; n < 4; n++) if (sig(n) !== sig(levels[levels.length - 1])) levels.push(n);
  function setLevel(i) {
    cur = Math.max(0, Math.min(levels.length - 1, i));
    dets.forEach(function (d) { d.open = wants(d, levels[cur]); });
    all(".zoombar button:not(.theme)").forEach(function (b, j) { b.setAttribute("aria-pressed", String(j === cur)); });
  }
  var bar = doc.createElement("nav"); bar.className = "zoombar"; bar.setAttribute("aria-label", "Detail level");
  bar.innerHTML = "<span>Level</span>";
  levels.forEach(function (lv, i) {
    var b = doc.createElement("button"); b.type = "button"; b.textContent = names[lv];
    b.setAttribute("aria-pressed", "false");
    b.addEventListener("click", function () { setLevel(i); });
    bar.appendChild(b);
  });
  var tb = doc.createElement("button"); tb.type = "button"; tb.className = "theme";
  function themeLabel() { var d = isDark(); tb.textContent = d ? "☀" : "☾"; tb.title = d ? "Light mode" : "Dark mode"; tb.setAttribute("aria-label", tb.title); }
  tb.addEventListener("click", function () {
    var next = isDark() ? "light" : "dark"; root.setAttribute("data-theme", next);
    try { localStorage.setItem(THEME_KEY, next); } catch (e) {}
    themeLabel();
  });
  themeLabel(); bar.appendChild(tb);
  var anchor = doc.querySelector(".why") || doc.querySelector("main > *");
  if (anchor && anchor.parentNode) anchor.parentNode.insertBefore(bar, anchor);
  cur = 0;
  for (var k = levels.length - 1; k > 0; k--) {
    if (dets.every(function (d) { return d.open === wants(d, levels[k]); })) { cur = k; break; }
  }
  all(".zoombar button:not(.theme)")[cur].setAttribute("aria-pressed", "true");

  /* per-section zoom: − / + beside each section's title moves only that
     section through its own levels (closed · open · details · code). The map
     section is a plain <section>: its levels are its zooms only. */
  function scoped(root, isSec) {
    var inner = all("details", root).filter(function (d) { return d !== root; });
    if (!inner.length) return null;
    function want(d, n) { return n >= 3 || (n === 2 && !isCode(d)); }
    function state(n) { return (isSec ? (n >= 1 ? "1" : "0") : "") + inner.map(function (d) { return want(d, n) ? "1" : "0"; }).join(""); }
    var lv = [0];
    (isSec ? [1, 2, 3] : [2, 3]).forEach(function (n) { if (state(n) !== state(lv[lv.length - 1])) lv.push(n); });
    function actual() { return (isSec ? (root.open ? "1" : "0") : "") + inner.map(function (d) { return d.open ? "1" : "0"; }).join(""); }
    function where() { /* the level the section shows now, read from the page */
      var a = actual();
      for (var i = lv.length - 1; i >= 0; i--) if (state(lv[i]) === a) return i;
      return isSec && !root.open ? 0 : 1;
    }
    function step(dir) {
      var at = Math.max(0, Math.min(lv.length - 1, where() + dir)), n = lv[at];
      if (isSec) root.open = n >= 1;
      inner.forEach(function (d) { d.open = want(d, n); });
    }
    return { step: step, max: lv.length - 1 };
  }
  function addControl(host, sc) {
    if (!sc || sc.max < 1) return;
    var box = doc.createElement("span"); box.className = "zc";
    [["−", -1, "Zoom out this section"], ["+", 1, "Zoom in this section"]].forEach(function (b) {
      var btn = doc.createElement("button"); btn.type = "button"; btn.textContent = b[0];
      btn.setAttribute("aria-label", b[2]); btn.title = b[2];
      btn.addEventListener("click", function (e) { e.preventDefault(); e.stopPropagation(); sc.step(b[1]); });
      box.appendChild(btn);
    });
    host.appendChild(box);
  }
  all("details.sec").forEach(function (d) { var sm = d.querySelector("summary"); if (sm) addControl(sm, scoped(d, true)); });
  all("section").forEach(function (sec) {
    var h = sec.querySelector("h2"); if (h && sec.querySelector("details.zoom")) addControl(h, scoped(sec, false));
  });
  doc.addEventListener("keydown", function (e) {
    if (e.target && /input|textarea|select/i.test(e.target.tagName)) return;
    if (e.key === "+" || e.key === "=") setLevel(cur + 1);
    else if (e.key === "-" || e.key === "_") setLevel(cur - 1);
  });

  /* file and symbol names break only after _ . / - , never mid-word */
  all(".tiles code, .cards code, .box, .chip").forEach(function (el) {
    Array.prototype.slice.call(el.childNodes).forEach(function (n) {
      if (n.nodeType !== 3 || !/[_.\/-]\w/.test(n.nodeValue)) return;
      var frag = doc.createDocumentFragment();
      n.nodeValue.split(/(?<=[_.\/-])/).forEach(function (part, i) { if (i) frag.appendChild(doc.createElement("wbr")); frag.appendChild(doc.createTextNode(part)); });
      el.replaceChild(frag, n);
    });
  });

  /* data-zoom: a click or Enter on a node opens its zoom */
  all("[data-zoom]").forEach(function (el) {
    if (!el.hasAttribute("tabindex")) el.setAttribute("tabindex", "0");
    el.setAttribute("role", "button");
    var go = function (e) { e.preventDefault(); reveal(el.getAttribute("data-zoom")); };
    el.addEventListener("click", go);
    el.addEventListener("keydown", function (e) { if (e.key === "Enter" || e.key === " ") go(e); });
  });

  /* #anchors open the closed details they point into */
  all('a[href^="#"]').forEach(function (a) {
    a.addEventListener("click", function (e) { var id = a.getAttribute("href").slice(1); if (doc.getElementById(id)) { e.preventDefault(); reveal(id); } });
  });

  /* data-ref: linked highlight across the map, tiles, cards and tables */
  function mark(key, on) { try { all('[data-ref="' + key.replace(/["\\]/g, "") + '"]').forEach(function (x) { x.classList.toggle("x-hl", on); }); } catch (e) {} }
  all("[data-ref]").forEach(function (el) {
    var k = el.getAttribute("data-ref");
    el.addEventListener("mouseenter", function () { mark(k, true); });
    el.addEventListener("mouseleave", function () { mark(k, false); });
    el.addEventListener("focus", function () { mark(k, true); });
    el.addEventListener("blur", function () { mark(k, false); });
  });

  /* explanations for the fixed parts of the page, in plain words: set only
     where the page gave no tooltip of its own. A title becomes a tooltip
     too, so one style shows every explanation. */
  var KINDS = {
    "irreversible": "After this runs, it cannot be undone, for example a migration, a delete or a send.",
    "contract": "Other code or people use this interface or format, so a change can break them.",
    "untested": "No test checks this changed logic.",
    "sensitive path": "The change touches an area that the repository marks as sensitive.",
    "concurrency": "The order or timing of events can change the result.",
    "security": "Access rights, secrets or input from outside are involved.",
    "data": "The change writes stored data or changes its format.",
    "rollout": "No flag or fallback limits the effect if the change is wrong.",
    "open point": "The PR itself says that this point is not settled."
  };
  var LEVEL_TIPS = { Overview: "Close all sections. You see the whole PR on one screen.",
    Sections: "Open the sections. Each one shows its main picture.",
    Details: "Open the zooms that hold no code: cards, tiles and steps.",
    Code: "Open everything, the code changes too." };
  function tipOn(sel, text) {
    all(sel).forEach(function (el) {
      var t = typeof text === "function" ? text(el) : text;
      if (t && !el.hasAttribute("data-tip")) el.setAttribute("data-tip", t);
    });
  }
  all("main [title]").forEach(function (el) {
    if (el.tagName === "BUTTON" || el.hasAttribute("data-tip")) return;
    el.setAttribute("data-tip", el.getAttribute("title")); el.removeAttribute("title");
  });
  tipOn(".zoombar button:not(.theme)", function (b) { return LEVEL_TIPS[b.textContent]; });
  tipOn(".org.open", "The agent made this choice alone. A person must judge it.");
  tipOn(".org.author", "The author made or confirmed this choice. Check that it is still correct.");
  tipOn(".org.inferred", "No text names this choice. The guide found it in the code.");
  tipOn(".rk .tg", function (el) { return KINDS[el.textContent.trim().toLowerCase()]; });
  tipOn(".dot.hi", "High: hard to undo, a security matter, or other code depends on it.");
  tipOn(".dot.md", "Medium: changed logic with no test, timing, or a sensitive area.");
  tipOn(".dot.lo", "Low: worth a look, but the effect stays small.");
  tipOn("[data-tag=NEW]", "This part is new in this PR.");
  tipOn("[data-tag=CHANGED]", "This PR changes this part.");
  tipOn(".box.chg, .chip.chg, .tiles .chg, .cards .chg", "This PR changes this part. A dashed border marks every change.");
  tipOn("summary em.alert", "Something in this section needs your attention. Open the section to see it.");
  tipOn(".found li b", function (b) { return /Critical/.test(b.textContent)
    ? "Critical: the review found a defect that must be fixed before the merge."
    : "Warning: the review found a defect that should be fixed before the merge."; });
  tipOn(".legend [data-kind]", "Click to hide or show this kind of change.");
  tipOn("main svg .node", function (g) {
    var p = (g.getAttribute("data-paths") || "").split(",").join(", ");
    return (/\bhl\b/.test(g.getAttribute("class") || "") ? "This PR changes files here. Click to zoom in. " : "No change here in this PR. ")
      + (p ? "Files: " + p : "");
  });
  tipOn(".zc button", function (b) { return b.getAttribute("aria-label"); });
  var ROW = { ok: "Done, and the evidence is linked.", part: "Done in part. The row says what is missing.",
    miss: "Not done. Check whether this is on purpose.", extra: "Done, but nobody asked for it. Check that it belongs in this PR." };
  tipOn(".req .st, .prf .st", function (td) { var r = td.parentNode.className.split(" ")[0];
    return td.closest(".prf") ? ({ ok: "A test proves this.", part: "Only a manual check, reported in the PR, proves this.",
      miss: "Nothing proves this. A person must check it." })[r] : ROW[r]; });
  tipOn(".fitl .aligned .st", "The change follows this recorded decision.");
  tipOn(".fitl .updates .st", "The PR changes this record too, so the record and the code agree.");
  tipOn(".fitl .contradicts .st", "The code goes against this record, and the record stays as it is. A person must decide which is right.");
  tipOn(".asm .st.ok", "Something in the code or a test checks this assumption.");
  tipOn(".asm .st.miss", "Nothing checks this assumption. If it is false, the choice is wrong.");
  tipOn("[data-tag=ONE-WAY]", "After this step, you cannot go back by a revert alone.");
  tipOn(".scn tr.chg", "The result changes in this situation.");

  /* data-tip: one floating tooltip; a tap toggles it on touch screens */
  var tip = doc.createElement("div"); tip.className = "x-tip"; tip.setAttribute("role", "tooltip"); doc.body.appendChild(tip);
  function place(e) { var x = e.clientX + 12, y = e.clientY + 14, w = tip.offsetWidth, h = tip.offsetHeight;
    if (x + w > innerWidth - 8) x = innerWidth - w - 8; if (y + h > innerHeight - 8) y = e.clientY - h - 10;
    tip.style.left = x + "px"; tip.style.top = y + "px"; }
  all("[data-tip]").forEach(function (el) {
    el.addEventListener("mouseenter", function (e) { tip.textContent = el.getAttribute("data-tip"); tip.classList.add("on"); place(e); });
    el.addEventListener("mousemove", place);
    el.addEventListener("mouseleave", function () { tip.classList.remove("on"); });
    el.addEventListener("touchstart", function (e) { tip.textContent = el.getAttribute("data-tip"); tip.classList.toggle("on");
      var t = e.touches[0]; place({ clientX: t.clientX, clientY: t.clientY }); }, { passive: true });
    el.addEventListener("focus", function () { var r = el.getBoundingClientRect(); tip.textContent = el.getAttribute("data-tip");
      tip.classList.add("on"); place({ clientX: r.left, clientY: r.bottom }); });
    el.addEventListener("blur", function () { tip.classList.remove("on"); });
    if (el.tagName === "BUTTON") el.removeAttribute("title");
  });

  /* legend: a click on a kind dims the tiles and boxes of that kind */
  all(".legend [data-kind]").forEach(function (item) {
    item.setAttribute("role", "button"); item.setAttribute("tabindex", "0");
    var toggle = function () { var k = (item.getAttribute("data-kind") || "").replace(/["\\]/g, ""), off = !item.classList.contains("x-mute");
      item.classList.toggle("x-mute", off);
      try { all('.tm [data-kind="' + k + '"], .tiles [data-kind="' + k + '"]').forEach(function (x) { x.classList.toggle("x-off", off); }); } catch (e) {} };
    item.addEventListener("click", toggle);
    item.addEventListener("keydown", function (e) { if (e.key === "Enter" || e.key === " ") { e.preventDefault(); toggle(); } });
  });
})();
