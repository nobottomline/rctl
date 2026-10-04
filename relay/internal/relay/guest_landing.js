// The fragment is memory-only. Plain GET/prefetch requests never claim a grant.
const secret = location.hash.slice(1);
const invitation = location.pathname.split('/').pop();
history.replaceState(null, '', location.pathname);
const button = document.getElementById('join');
const error = document.getElementById('error');
const heading = document.getElementById('heading');
const status = document.getElementById('status');
const resume = document.getElementById('resume');
let prepared = false, claimed = false, running = false, attempted = false;

async function request(path, body) {
  const abort = new AbortController();
  const timeout = setTimeout(() => abort.abort(), 8000);
  try {
    const options = body === undefined ? { cache: 'no-store', signal: abort.signal } : {
      method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body), signal: abort.signal,
    };
    const response = await fetch(path, options);
    if (body === undefined && response.status === 401) return null;
    const value = await response.json();
    if (!response.ok) throw new Error(value.error || 'connection_failed');
    return value;
  } catch (failure) {
    if (abort.signal.aborted) throw new Error('connection_timeout');
    throw failure;
  } finally { clearTimeout(timeout); }
}

async function join() {
  if (running) return;
  running = true; button.hidden = true; error.textContent = ''; resume.hidden = true;
  heading.textContent = 'Connecting to your device';
  status.textContent = 'Confirming temporary access…';
  try {
    if (!claimed) {
      const current = await request('/api/guest/session');
      if (current && (current.grant_id === invitation || !secret)) claimed = true;
      else {
        if (!/^[A-Za-z0-9_-]{43}$/.test(secret)) throw new Error('missing_invitation');
        if (current) throw new Error('end_current_session_first');
        if (!prepared) { await request('/api/guest/prepare', {}); prepared = true; }
        await request('/api/guest/claim', { invitation_id: invitation, secret });
        claimed = true;
      }
    }
    await request('/api/guest/claim/ack', {});
    location.replace('/guest/control');
  } catch (failure) {
    const labels = {
      missing_invitation: 'Open the complete invitation from the owner, or return to your current session.',
      invitation_unavailable: 'This invitation has expired, was already used, or was revoked. Ask the owner for a new link.',
      device_offline: 'The device is offline. You can retry while the invitation is valid.',
      device_guest_access_not_supported: 'The device needs an update before it can accept guests.',
      turn_unavailable: 'The relay connection is unavailable. Contact the owner.',
      end_current_session_first: 'You already have access to another session. Return to it and end access before opening this invitation.',
      claim_binding_required: 'The connection confirmation expired. Retry to prepare a new confirmation.',
      guest_access_ended: 'Your access has ended. Ask the owner for a new invitation.',
      connection_timeout: 'The connection took too long. Retry when your connection is available.',
    };
    if (failure.message === 'claim_binding_required') prepared = false;
    heading.textContent = 'Could not connect'; status.textContent = 'Temporary device access';
    error.textContent = labels[failure.message] || 'Could not confirm the connection. Retry or contact the owner.';
    const terminal = ['missing_invitation', 'invitation_unavailable', 'guest_access_ended'].includes(failure.message);
    button.hidden = terminal; button.disabled = false;
    resume.hidden = !['missing_invitation', 'end_current_session_first'].includes(failure.message);
  } finally { running = false; }
}

button.onclick = () => { void join(); };
function activate() {
  // Wait for real page activation rather than consuming a prerendered/hidden link.
  // A preview that executes JS in a visible browser can still claim the link.
  if (attempted || document.prerendering || document.visibilityState !== 'visible') return;
  attempted = true;
  document.removeEventListener('visibilitychange', activate);
  document.removeEventListener('prerenderingchange', activate);
  void join();
}
document.addEventListener('visibilitychange', activate);
document.addEventListener('prerenderingchange', activate);
activate();
