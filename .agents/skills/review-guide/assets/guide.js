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
    ".zc{display:inline-flex;gap:2px;margin-left:auto;flex:none}.zc button{font:inherit;font-size:13px;line-height:1;width:24px;height:22px;border:1px solid var(--line);background:var(--card);color:var(--fg);border-radius:6px;cursor:pointer;padding:0}" +
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
    all(".zoombar button").forEach(function (b, j) { b.setAttribute("aria-pressed", String(j === cur)); });
  }
  var bar = doc.createElement("nav"); bar.className = "zoombar"; bar.setAttribute("aria-label", "Detail level");
  bar.innerHTML = "<span>Level</span>";
  levels.forEach(function (lv, i) {
    var b = doc.createElement("button"); b.type = "button"; b.textContent = names[lv];
    b.setAttribute("aria-pressed", "false");
    b.addEventListener("click", function () { setLevel(i); });
    bar.appendChild(b);
  });
  var anchor = doc.querySelector(".why") || doc.querySelector("main > *");
  if (anchor && anchor.parentNode) anchor.parentNode.insertBefore(bar, anchor);
  cur = 0;
  for (var k = levels.length - 1; k > 0; k--) {
    if (dets.every(function (d) { return d.open === wants(d, levels[k]); })) { cur = k; break; }
  }
  all(".zoombar button")[cur].setAttribute("aria-pressed", "true");

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
