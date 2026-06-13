package relay

const adminHTML = `<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>rctl relay</title>
  <link rel="stylesheet" href="/assets/admin.css">
</head>
<body>
  <main class="shell">
    <header class="topbar">
      <div>
        <h1>rctl relay</h1>
        <p id="status">Not signed in</p>
      </div>
      <button id="refresh" class="secondary" type="button">Refresh</button>
    </header>

    <section id="loginPanel" class="panel">
      <h2>Admin login</h2>
      <form id="loginForm" class="form">
        <input id="adminSecret" type="password" autocomplete="current-password" placeholder="Admin secret" required>
        <button type="submit">Sign in</button>
      </form>
    </section>

    <section id="appPanel" class="grid hidden">
      <div class="panel">
        <div class="panelHead">
          <h2>Devices</h2>
          <span id="deviceCount" class="muted">0 devices</span>
        </div>
        <div class="tableWrap">
          <table>
            <thead>
              <tr>
                <th>Name</th>
                <th>Status</th>
                <th>Online</th>
                <th>Updated</th>
                <th></th>
              </tr>
            </thead>
            <tbody id="devices"></tbody>
          </table>
        </div>
      </div>

      <aside class="panel">
        <h2>Enrollment</h2>
        <p class="muted">Create a short-lived token, paste it into relay.env, then run make package-relay.</p>
        <button id="createEnrollment" type="button">Create token</button>
        <textarea id="enrollment" readonly spellcheck="false"></textarea>
      </aside>
    </section>
  </main>
  <script src="/assets/admin.js"></script>
</body>
</html>
`

const adminCSS = `:root{
  color-scheme: light;
  --bg:#f7f8fa;
  --panel:#ffffff;
  --text:#171a1f;
  --muted:#667085;
  --line:#d9dee7;
  --strong:#0f766e;
  --danger:#b42318;
  --shadow:0 10px 30px rgba(18,25,38,.08);
}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--text);font:14px/1.45 -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif}
.shell{width:min(1180px,calc(100vw - 32px));margin:28px auto}
.topbar{display:flex;align-items:center;justify-content:space-between;margin-bottom:18px}
h1,h2,p{margin:0}
h1{font-size:24px;font-weight:700}
h2{font-size:15px;font-weight:700}
.topbar p,.muted{color:var(--muted)}
.grid{display:grid;grid-template-columns:minmax(0,1fr) 360px;gap:16px}
.panel{background:var(--panel);border:1px solid var(--line);border-radius:8px;box-shadow:var(--shadow);padding:16px}
.panelHead{display:flex;align-items:center;justify-content:space-between;margin-bottom:12px}
.form{display:flex;gap:10px;margin-top:12px}
input,textarea{width:100%;border:1px solid var(--line);border-radius:6px;background:white;color:var(--text);font:inherit;padding:10px 11px}
textarea{height:190px;margin-top:12px;resize:vertical;font-family:ui-monospace,SFMono-Regular,Menlo,monospace;font-size:12px}
button{border:0;border-radius:6px;background:var(--strong);color:white;font-weight:700;padding:10px 13px;cursor:pointer;white-space:nowrap}
button.secondary{background:#344054}
button.danger{background:var(--danger)}
button:disabled{opacity:.55;cursor:not-allowed}
.actions{display:flex;align-items:center;justify-content:flex-end;gap:8px}
.buttonLink{display:inline-flex;align-items:center;border-radius:6px;background:#344054;color:white;font-weight:700;padding:10px 13px;text-decoration:none;white-space:nowrap}
.tableWrap{overflow:auto;border:1px solid var(--line);border-radius:6px}
table{width:100%;border-collapse:collapse;background:white}
th,td{padding:10px 12px;border-bottom:1px solid var(--line);text-align:left;vertical-align:middle}
th{font-size:12px;color:var(--muted);font-weight:700;background:#fbfcfe}
tr:last-child td{border-bottom:0}
.pill{display:inline-flex;align-items:center;border-radius:999px;padding:3px 8px;font-size:12px;font-weight:700;background:#eef4ff;color:#3538cd}
.pill.approved{background:#ecfdf3;color:#027a48}
.pill.revoked{background:#fef3f2;color:#b42318}
.empty{color:var(--muted);text-align:center;padding:24px}
.hidden{display:none}
@media (max-width: 820px){
  .shell{width:min(100vw - 20px,1180px);margin:14px auto}
  .topbar,.form{align-items:stretch;flex-direction:column}
  .grid{grid-template-columns:1fr}
}
`

const adminJS = `const state = { signedIn: false };
const $ = (id) => document.getElementById(id);

function setStatus(text) { $("status").textContent = text; }
function showApp(show) {
  $("loginPanel").classList.toggle("hidden", show);
  $("appPanel").classList.toggle("hidden", !show);
  state.signedIn = show;
}
async function api(path, options = {}) {
  const res = await fetch(path, {
    ...options,
    headers: { "Content-Type": "application/json", ...(options.headers || {}) }
  });
  const body = await res.json().catch(() => ({}));
  if (!res.ok) throw new Error(body.error || res.statusText);
  return body;
}
function fmtTime(sec) {
  if (!sec) return "";
  return new Date(sec * 1000).toLocaleString();
}
function rowActions(device) {
  if (device.status === "pending") {
    return '<div class="actions"><button data-action="approve" data-id="' + escapeHTML(device.id) + '">Approve</button></div>';
  }
  if (device.status !== "revoked") {
    const controlURL = "/control/devices/" + encodeURIComponent(device.id);
    return '<div class="actions"><a class="buttonLink" href="' + controlURL + '">Open</a><button class="danger" data-action="revoke" data-id="' + escapeHTML(device.id) + '">Revoke</button></div>';
  }
  return "";
}
async function refreshDevices() {
  const data = await api("/api/admin/devices");
  const devices = data.devices || [];
  $("deviceCount").textContent = devices.length + (devices.length === 1 ? " device" : " devices");
  $("devices").innerHTML = devices.length ? devices.map((d) =>
    '<tr>' +
      '<td><strong>' + escapeHTML(d.name) + '</strong><br><span class="muted">' + escapeHTML(d.id) + '</span></td>' +
      '<td><span class="pill ' + escapeHTML(d.status) + '">' + escapeHTML(d.status) + '</span></td>' +
      '<td>' + (d.online ? "online" : "offline") + '</td>' +
      '<td>' + fmtTime(d.updated_at) + '</td>' +
      '<td>' + rowActions(d) + '</td>' +
    '</tr>'
  ).join("") : '<tr><td colspan="5" class="empty">No devices yet</td></tr>';
  setStatus("Signed in");
}
function escapeHTML(value) {
  return String(value).replace(/[&<>"']/g, (c) => ({ "&":"&amp;", "<":"&lt;", ">":"&gt;", '"':"&quot;", "'":"&#39;" }[c]));
}
$("loginForm").addEventListener("submit", async (event) => {
  event.preventDefault();
  try {
    await api("/api/admin/login", { method: "POST", body: JSON.stringify({ secret: $("adminSecret").value }) });
    $("adminSecret").value = "";
    showApp(true);
    await refreshDevices();
  } catch (err) {
    setStatus("Login failed: " + err.message);
  }
});
$("refresh").addEventListener("click", async () => {
  if (!state.signedIn) return;
  try { await refreshDevices(); } catch (err) { setStatus("Refresh failed: " + err.message); }
});
$("createEnrollment").addEventListener("click", async () => {
  try {
    const data = await api("/api/admin/enrollments", { method: "POST" });
    $("enrollment").value = "RELAY_URL=" + data.relay_url + "\nENROLL_TOKEN=" + data.token + "\n";
  } catch (err) {
    setStatus("Enrollment failed: " + err.message);
  }
});
$("devices").addEventListener("click", async (event) => {
  const button = event.target.closest("button[data-action]");
  if (!button) return;
  button.disabled = true;
  try {
    await api("/api/admin/devices/" + encodeURIComponent(button.dataset.id) + "/" + button.dataset.action, { method: "POST" });
    await refreshDevices();
  } catch (err) {
    setStatus(button.dataset.action + " failed: " + err.message);
  } finally {
    button.disabled = false;
  }
});
`
