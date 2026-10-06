#!/usr/bin/env bash
# report-tip.sh — the column-help bubble both report artifacts share
# (scripts/audit-trend.sh, scripts/benchmark-report.sh): a header's or cell's
# title, or an SVG band's <title>, shows as one styled bubble on hover and
# focus. Each report expands REPORT_TIP_CSS inside its <style> and
# REPORT_TIP_JS inside its <script>; the page tokens (--ink, --surface,
# --rule-strong, --seq) are the report's own.

IFS= read -r -d '' REPORT_TIP_CSS <<'CSS'
/* a column with help text is marked by a dotted underline; the text itself
   ships as the header title (readable with no JS) and the script below moves it
   into the bubble, because a native title is clipped by the scroller */
th[title],th[data-tip],td[title],td[data-tip]{
  text-decoration:underline dotted var(--rule-strong);text-underline-offset:3px}
td[data-tip]{cursor:help}
th[data-tip]:focus-visible,td[data-tip]:focus-visible{color:var(--ink);outline:2px solid var(--seq);
  outline-offset:-2px}
.tip{position:fixed;display:none;z-index:9;max-width:26rem;
  padding:.5rem .65rem;font-size:.78rem;font-weight:400;line-height:1.45;
  white-space:pre-line;color:var(--ink);background:var(--surface);
  border:1px solid var(--rule-strong);border-radius:6px;
  box-shadow:0 4px 14px color-mix(in srgb,var(--ink) 22%,transparent)}
.tip b{display:block;margin-bottom:.15rem}
CSS

IFS= read -r -d '' REPORT_TIP_JS <<'JS'
// Column help: the header title becomes a styled bubble on hover and focus —
// a native title inside the horizontal scroller is slow, truncated and
// untouched by the light/dark tokens. Headers and chart bands also become
// focusable, so the help and the sort both work from the keyboard.
(function(){
  var tip=document.createElement('div');
  tip.className='tip'; tip.id='col-tip'; tip.setAttribute('role','tooltip');
  document.body.appendChild(tip);
  var open=null;
  function hide(){
    if(open)open.removeAttribute('aria-describedby');
    open=null; tip.style.display='none';
  }
  function show(th){
    var txt=th.getAttribute('data-tip'); if(!txt)return;
    var label=document.createElement('b');
    label.textContent=th.getAttribute('data-label')||th.textContent.trim();
    tip.textContent=''; tip.appendChild(label);
    tip.appendChild(document.createTextNode(txt));
    tip.style.display='block'; tip.style.left='0px'; tip.style.top='0px';
    var r=th.getBoundingClientRect(), b=tip.getBoundingClientRect();
    var x=Math.min(Math.max(4,r.left),Math.max(4,window.innerWidth-b.width-4));
    var y=r.bottom+6;
    if(y+b.height>window.innerHeight-4)y=Math.max(4,r.top-b.height-6);
    tip.style.left=x+'px'; tip.style.top=y+'px';
    th.setAttribute('aria-describedby','col-tip'); open=th;
  }
  function bind(el){
    el.setAttribute('tabindex','0');
    el.addEventListener('mouseenter',function(){show(el)});
    el.addEventListener('mouseleave',hide);
    el.addEventListener('focus',function(){show(el)});
    el.addEventListener('blur',hide);
    el.addEventListener('keydown',function(e){
      if(e.key==='Escape')hide();
      else if(el.tagName==='TH'&&(e.key==='Enter'||e.key===' ')){e.preventDefault(); el.click();}
    });
  }
  // a chart band carries its values as an SVG <title> child, the week as data-label
  document.querySelectorAll('svg .hit').forEach(function(r){
    var t=r.querySelector('title'); if(!t)return;
    r.setAttribute('data-tip',t.textContent.replace(/^[^\n]*\n/,''));
    r.removeChild(t);
    bind(r);
  });
  document.querySelectorAll('th[title],td[title]').forEach(function(th){
    th.setAttribute('data-tip',th.getAttribute('title'));
    th.removeAttribute('title');
    bind(th);
  });
  // a scroll moves the element under a bubble anchored to the viewport: the
  // bubble follows the focused element (focus itself scrolls it into view) and
  // closes otherwise
  window.addEventListener('scroll',function(){
    if(open&&open===document.activeElement)show(open); else hide();
  },true);
})();
JS
