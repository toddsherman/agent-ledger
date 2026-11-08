// Agent Ledger testbed: a ground-truth diagnostic page and a small mock CMS with sign-in,
// so recorder behavior can be checked repeatably before trying real sites.
//
//   node testbed/server.mjs        → http://localhost:4399
import http from 'node:http';
import { randomBytes } from 'node:crypto';

const PORT = Number(process.env.PORT || 4399);
const sessions = new Map(); // cookie -> username
const records = new Map([
  [1, { id: 1, title: 'Spring launch announcement', summary: 'We are launching the spring collection on March 3.', status: 'draft', tags: 'launch, spring', featured: false, body: 'Draft body text for the spring launch.' }],
  [2, { id: 2, title: 'Pricing page refresh', summary: 'New tiers and annual discount.', status: 'published', tags: 'pricing', featured: true, body: 'Pricing copy goes here.' }],
  [3, { id: 3, title: 'Holiday hours', summary: 'Store hours for the holidays.', status: 'draft', tags: 'ops', featured: false, body: 'We close at 4pm on Dec 24.' }],
]);
const log = [];

const esc = (s) => String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));

const STYLE = `
<style>
  :root { color-scheme: light dark; --bg:#fafafa; --fg:#1d1d1f; --muted:#6e6e73; --card:#fff; --line:#e3e3e8; --accent:#0b63ce; }
  @media (prefers-color-scheme: dark) { :root { --bg:#161617; --fg:#f5f5f7; --muted:#a1a1a6; --card:#1f1f21; --line:#333336; --accent:#4c9bff; } }
  body { font: 15px/1.45 -apple-system, system-ui, sans-serif; background: var(--bg); color: var(--fg); margin: 0; }
  header { display:flex; gap:16px; align-items:center; padding: 12px 24px; border-bottom: 1px solid var(--line); background: var(--card); }
  header a { color: var(--accent); text-decoration: none; }
  main { max-width: 860px; margin: 24px auto; padding: 0 16px; }
  .card { background: var(--card); border: 1px solid var(--line); border-radius: 10px; padding: 18px 20px; margin-bottom: 16px; }
  label { display:block; font-weight: 600; margin: 12px 0 4px; }
  input[type=text], input[type=email], input[type=password], textarea, select { width: 100%; box-sizing: border-box; padding: 8px 10px; border: 1px solid var(--line); border-radius: 6px; background: var(--bg); color: var(--fg); font: inherit; }
  textarea { min-height: 80px; }
  [contenteditable] { border: 1px dashed var(--line); border-radius: 6px; padding: 8px 10px; min-height: 60px; }
  button { font: inherit; padding: 8px 14px; border-radius: 6px; border: 1px solid var(--line); background: var(--accent); color: white; cursor: pointer; }
  button.secondary { background: transparent; color: var(--fg); }
  table { width: 100%; border-collapse: collapse; } td, th { text-align: left; padding: 8px; border-bottom: 1px solid var(--line); }
  .toast { position: fixed; bottom: 24px; right: 24px; padding: 12px 16px; border-radius: 8px; background: #1b7f3b; color: white; display: none; }
  .toast.error { background: #b3261e; }
  .muted { color: var(--muted); }
</style>`;

function page(title, body, user) {
  return `<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>${esc(title)}</title>${STYLE}</head>
<body><header><strong>Ledger Testbed</strong><a href="/diagnostic">Diagnostic page</a><a href="/cms">Mock CMS</a>
<span class="muted" style="margin-left:auto">${user ? 'Signed in as ' + esc(user) + ' · <form method="post" action="/cms/logout" style="display:inline"><button class="secondary" type="submit">Sign out</button></form>' : 'Not signed in'}</span></header>
<main>${body}</main><div id="toast" class="toast" role="status" aria-live="polite"></div></body></html>`;
}

function cookies(req) {
  const out = {};
  for (const part of (req.headers.cookie || '').split(';')) {
    const [k, ...v] = part.trim().split('=');
    if (k) out[k] = decodeURIComponent(v.join('='));
  }
  return out;
}

function readBody(req) {
  return new Promise((resolve) => {
    let data = '';
    req.on('data', (c) => { data += c; if (data.length > 1e6) req.destroy(); });
    req.on('end', () => resolve(data));
  });
}

function send(res, status, body, headers = {}) {
  res.writeHead(status, Object.assign({ 'content-type': 'text/html; charset=utf-8', 'cache-control': 'no-store' }, headers));
  res.end(body);
}

function json(res, status, obj) {
  send(res, status, JSON.stringify(obj), { 'content-type': 'application/json' });
}

const DIAGNOSTIC = `
<h1>Diagnostic page</h1>
<p class="muted">Ground truth for the recorder: each control produces a known browser event.</p>
<div class="card">
  <h2>Navigation</h2>
  <p><a id="link-page2" href="/diagnostic?page=2">Go to page 2</a> · <a href="#section-forms">Jump to forms (fragment)</a> ·
     <a id="link-newtab" href="/diagnostic?page=new" target="_blank">Open in a new tab</a></p>
  <button id="push-state" type="button">Change route with pushState</button>
</div>
<div class="card" id="section-forms">
  <h2>Form controls</h2>
  <form id="diag-form" action="/api/echo" method="post">
    <label for="f-name">Display name</label><input id="f-name" name="displayName" type="text" placeholder="Ada Lovelace">
    <label for="f-email">Email</label><input id="f-email" name="email" type="email">
    <label for="f-password">Password (must never be captured)</label><input id="f-password" name="password" type="password" autocomplete="current-password">
    <label for="f-notes">Notes</label><textarea id="f-notes" name="notes"></textarea>
    <label for="f-plan">Plan</label><select id="f-plan" name="plan"><option value="free">Free</option><option value="pro">Pro</option><option value="team">Team</option></select>
    <label><input id="f-terms" name="terms" type="checkbox"> I accept the test terms</label>
    <label for="f-rich">Rich text</label><div id="f-rich" contenteditable="true" aria-label="Rich text editor">Edit me</div>
    <input type="hidden" name="csrf" value="csrf-secret-123">
    <p><button id="diag-submit" type="submit">Submit form</button>
       <button id="programmatic" class="secondary" type="button">Set name programmatically (no events)</button></p>
  </form>
</div>
<div class="card">
  <h2>Feedback</h2>
  <button id="delayed-toast" type="button">Show a delayed status message</button>
  <button id="show-error" class="secondary" type="button">Show an alert</button>
  <div id="alert-slot"></div>
</div>
<div class="card"><h2>Read-only content</h2><p id="readonly">This paragraph exists so agents can read it without changing anything. Order #20261107 shipped on November 7.</p></div>
<script>
  const toast = (msg, error) => { const t = document.getElementById('toast'); t.textContent = msg; t.className = 'toast' + (error ? ' error' : ''); t.style.display = 'block'; setTimeout(() => t.style.display = 'none', 4000); };
  document.getElementById('push-state').onclick = () => history.pushState({}, '', '/diagnostic/route-' + Date.now().toString(36));
  document.getElementById('programmatic').onclick = () => { document.getElementById('f-name').value = 'Set by script'; };
  document.getElementById('delayed-toast').onclick = () => setTimeout(() => toast('Delayed status: all good'), 1000);
  document.getElementById('show-error').onclick = () => { const d = document.createElement('div'); d.setAttribute('role', 'alert'); d.textContent = 'Something needs attention'; document.getElementById('alert-slot').appendChild(d); };
  document.getElementById('diag-form').addEventListener('submit', async (e) => {
    e.preventDefault();
    const data = Object.fromEntries(new FormData(e.target));
    data.rich = document.getElementById('f-rich').innerText;
    const r = await fetch('/api/echo', { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify(data) });
    toast(r.ok ? 'Form received' : 'Form failed', !r.ok);
  });
</script>`;

function loginPage(error) {
  return `<h1>Sign in to Mock CMS</h1><div class="card"><form method="post" action="/cms/login">
  ${error ? `<p role="alert" style="color:#b3261e">${esc(error)}</p>` : ''}
  <label for="username">Username</label><input id="username" name="username" type="text" autocomplete="username">
  <label for="password">Password</label><input id="password" name="password" type="password" autocomplete="current-password">
  <p><button type="submit">Sign in</button></p><p class="muted">Any username works; the password is not checked.</p></form></div>`;
}

function listPage() {
  const rows = [...records.values()].map((r) => `<tr><td><a href="/cms/record/${r.id}">${esc(r.title)}</a></td><td>${esc(r.status)}</td><td>${esc(r.tags)}</td></tr>`).join('');
  return `<h1>Records</h1><div class="card"><table><thead><tr><th>Title</th><th>Status</th><th>Tags</th></tr></thead><tbody>${rows}</tbody></table></div>`;
}

function editPage(r) {
  return `<p><a href="/cms">← All records</a></p><h1>Edit record #${r.id}</h1>
<div class="card"><form id="record-form" action="/cms/api/record/${r.id}" method="post">
  <label for="title">Title</label><input id="title" name="title" type="text" value="${esc(r.title)}">
  <label for="summary">Summary</label><textarea id="summary" name="summary">${esc(r.summary)}</textarea>
  <label for="status">Status</label><select id="status" name="status">
    ${['draft', 'review', 'published'].map((s) => `<option value="${s}"${s === r.status ? ' selected' : ''}>${s[0].toUpperCase() + s.slice(1)}</option>`).join('')}</select>
  <label for="tags">Tags</label><input id="tags" name="tags" type="text" value="${esc(r.tags)}">
  <label><input id="featured" name="featured" type="checkbox"${r.featured ? ' checked' : ''}> Featured on home page</label>
  <label for="body">Body</label><div id="body" contenteditable="true" role="textbox" aria-label="Body">${esc(r.body)}</div>
  <p><button id="save" type="submit">Save changes</button></p>
</form></div>
<script>
  const toast = (msg, error) => { const t = document.getElementById('toast'); t.textContent = msg; t.className = 'toast' + (error ? ' error' : ''); t.style.display = 'block'; setTimeout(() => t.style.display = 'none', 5000); };
  document.getElementById('record-form').addEventListener('submit', async (e) => {
    e.preventDefault();
    const f = e.target;
    const payload = { title: f.title.value, summary: f.summary.value, status: f.status.value, tags: f.tags.value, featured: f.featured.checked, body: document.getElementById('body').innerText };
    const r = await fetch(f.action, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify(payload) });
    const out = await r.json();
    if (r.ok) toast('Saved “' + out.record.title + '”'); else toast('Not saved: ' + out.error, true);
  });
</script>`;
}

const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, `http://${req.headers.host}`);
  const user = sessions.get(cookies(req).cms_session);
  const path = url.pathname;
  try {
    if (req.method === 'GET' && path === '/') return send(res, 200, page('Ledger Testbed', '<h1>Ledger Testbed</h1><div class="card"><p><a href="/diagnostic">Diagnostic page</a></p><p><a href="/cms">Mock CMS (sign-in required)</a></p></div>', user));
    if (req.method === 'GET' && path.startsWith('/diagnostic')) return send(res, 200, page('Diagnostic page', DIAGNOSTIC, user));
    if (req.method === 'POST' && path === '/api/echo') { const b = await readBody(req); log.push({ t: Date.now(), path, bytes: b.length }); return json(res, 200, { ok: true, bytes: b.length }); }
    if (path === '/cms/login') {
      if (req.method === 'GET') return send(res, 200, page('Sign in', loginPage(), user));
      const form = new URLSearchParams(await readBody(req));
      const name = (form.get('username') || '').trim();
      if (!name) return send(res, 400, page('Sign in', loginPage('Enter a username.'), null));
      const sid = randomBytes(16).toString('hex');
      sessions.set(sid, name);
      return send(res, 303, '', { location: '/cms', 'set-cookie': `cms_session=${sid}; HttpOnly; SameSite=Lax; Path=/` });
    }
    if (path === '/cms/logout' && req.method === 'POST') {
      sessions.delete(cookies(req).cms_session);
      return send(res, 303, '', { location: '/cms/login', 'set-cookie': 'cms_session=; Max-Age=0; Path=/' });
    }
    if (path.startsWith('/cms') && !user) {
      if (path.startsWith('/cms/api/')) return json(res, 401, { error: 'not signed in' });
      return send(res, 303, '', { location: '/cms/login' });
    }
    if (req.method === 'GET' && path === '/cms') return send(res, 200, page('Records', listPage(), user));
    let m = path.match(/^\/cms\/record\/(\d+)$/);
    if (req.method === 'GET' && m && records.has(Number(m[1]))) return send(res, 200, page('Edit record', editPage(records.get(Number(m[1]))), user));
    m = path.match(/^\/cms\/api\/record\/(\d+)$/);
    if (m && records.has(Number(m[1]))) {
      const rec = records.get(Number(m[1]));
      if (req.method === 'GET') return json(res, 200, { record: rec });
      if (req.method === 'POST') {
        const body = JSON.parse((await readBody(req)) || '{}');
        if (!String(body.title || '').trim()) return json(res, 422, { error: 'Title is required' });
        Object.assign(rec, { title: String(body.title), summary: String(body.summary ?? rec.summary), status: String(body.status ?? rec.status),
          tags: String(body.tags ?? rec.tags), featured: !!body.featured, body: String(body.body ?? rec.body) });
        log.push({ t: Date.now(), path, user, record: { ...rec } });
        return json(res, 200, { ok: true, record: rec });
      }
    }
    if (req.method === 'GET' && path === '/__log') return json(res, 200, { log, records: [...records.values()] });
    return send(res, 404, page('Not found', '<h1>Not found</h1>', user));
  } catch (err) {
    return json(res, 500, { error: String(err) });
  }
});

server.listen(PORT, '127.0.0.1', () => console.log(`Ledger testbed on http://localhost:${PORT}`));
