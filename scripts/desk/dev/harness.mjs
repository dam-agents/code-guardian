#!/usr/bin/env node
// Development only: serves the Desk page with a stand-in for the platform bridge, so the page can be
// opened in a local browser against a local Desk server (docs/desk.md → Development).
//   node scripts/desk/dev/seed.mjs /tmp/cg-desk-work
//   WORK_DIR=/tmp/cg-desk-work node scripts/desk/dev/harness.mjs 5700 5699
//   open "http://localhost:5700/"                               (the operator)
//   open "http://localhost:5700/?as=pat@example.com&role=viewer" (a viewer)
// The harness starts the server itself on the second port (CG_DESK_PORT), unless one answers there
// already. The stand-in sets the caller headers the platform's relay would set; sendPrompt only logs.
// It is never part of a deployment. The page is read again on every load.
import { createServer } from 'node:http';
import { spawn } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const [port = '5700', apiPort = '5699'] = process.argv.slice(2);
const HERE = dirname(fileURLToPath(import.meta.url));
const page = join(HERE, '..', 'page.html');
const work = process.env.WORK_DIR ?? join(process.env.HOME ?? '/home/agent', 'work');
const health = () => fetch(`http://127.0.0.1:${apiPort}/health`).then((r) => r.ok, () => false);

if (!(await health())) {
  const child = spawn(process.execPath, [join(HERE, '..', 'server.mjs')], { env: { ...process.env, CG_DESK_PORT: apiPort, WORK_DIR: work }, stdio: ['ignore', 'inherit', 'inherit'] });
  process.on('exit', () => child.kill());
  for (const sig of ['SIGINT', 'SIGTERM']) process.on(sig, () => { child.kill(); process.exit(0); });
  for (let k = 0; k < 50 && !(await health()); k++) await new Promise((ok) => setTimeout(ok, 100));
}

const shim = `<script>
window.platform = (() => {
  const q = new URLSearchParams(location.search);
  const as = q.get("as") || "owner@example.com", role = q.get("role") || "owner";
  return Object.freeze({
    sendPrompt(p, o) { console.log("[sendPrompt]", p, o || ""); },
    async request({ method, path, body, contentType }) {
      const r = await fetch("/relay" + path, { method, body, headers: { "content-type": contentType || "text/plain", "x-as": as, "x-role": role } });
      return { status: r.status, contentType: r.headers.get("content-type"), body: await r.text() };
    },
    async whoami() { return { role, email: as, sub: "dev-" + as }; },
  });
})();
</script>`;

createServer(async (req, res) => {
  if (req.url.startsWith('/relay/')) {
    const chunks = [];
    for await (const c of req) chunks.push(c);
    const as = String(req.headers['x-as'] || ''); const role = String(req.headers['x-role'] || 'viewer');
    let r;
    try {
      r = await fetch(`http://127.0.0.1:${apiPort}${req.url.slice('/relay'.length)}`, {
        method: req.method, body: chunks.length ? Buffer.concat(chunks) : undefined,
        headers: { 'content-type': 'application/json', 'x-platform-caller-role': role, 'x-platform-caller-email': as, 'x-platform-caller-sub': `dev-${as}` },
      });
    } catch (e) {
      res.writeHead(502, { 'content-type': 'application/json' });
      return res.end(JSON.stringify({ error: `The Desk server on port ${apiPort} does not answer (${e.cause?.code || e.message}).` }));
    }
    res.writeHead(r.status, { 'content-type': r.headers.get('content-type') || 'application/json' });
    return res.end(Buffer.from(await r.arrayBuffer()));
  }
  const html = readFileSync(page, 'utf8').replace('<head>', `<head>${shim}`);
  res.writeHead(200, { 'content-type': 'text/html; charset=utf-8' });
  res.end(html);
}).listen(Number(port), '127.0.0.1', () => console.error(`harness on http://localhost:${port} → Desk server 127.0.0.1:${apiPort}`));
