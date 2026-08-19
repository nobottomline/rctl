// Connection + path layer for the control page. The page runs in two modes:
//  - device-local (LAN/USB): served by rctld itself, all paths hit rctld directly.
//  - relay: served by the relay, which injects window globals so requests are
//    proxied to the device through the relay.
// The vanilla page monkey-patched window.fetch to rewrite paths; here it's an
// explicit api()/wsURL() wrapper instead -- same behavior, no global patching.

const w = window as unknown as Record<string, unknown>

export const PROXY_BASE = String(w.RCTL_PROXY_BASE || '').replace(/\/$/, '')
export const STREAM_BASE = String(w.RCTL_STREAM_BASE || '').replace(/\/$/, '')
export const TERM_WS_BASE = String(w.RCTL_TERM_WS_BASE || '').replace(/\/$/, '')
export const DEVICE_ID = String(w.RCTL_RELAY_DEVICE_ID || '')
export const RELAY_MODE = !!(PROXY_BASE || STREAM_BASE)
export const WEBRTC_MODE = RELAY_MODE && !!w.RCTL_WEBRTC && 'RTCPeerConnection' in window

// Map an rctld path to the relay proxy when in relay mode (identity locally).
export function rctlPath(path: string): string {
  if (!RELAY_MODE || typeof path !== 'string' || path[0] !== '/') return path
  if (path === '/stream' || path.startsWith('/stream?')) {
    return STREAM_BASE ? STREAM_BASE + '/stream' + path.slice('/stream'.length) : path
  }
  if (/^\/(v1\/|input|key|config|orient)/.test(path)) return PROXY_BASE + path
  return path
}

export function fileDownloadURL(path: string): string {
  const endpoint = `/v1/pull_stream?path=${encodeURIComponent(path)}`
  return RELAY_MODE && STREAM_BASE ? STREAM_BASE + endpoint : endpoint
}

export function downloadFile(path: string, name: string): void {
  const anchor = document.createElement('a')
  anchor.href = fileDownloadURL(path)
  anchor.download = name
  document.body.appendChild(anchor)
  anchor.click()
  anchor.remove()
}

export function api(path: string, init?: RequestInit): Promise<Response> {
  return fetch(rctlPath(path), init)
}

// JSON GET helper (returns null on any failure -- callers stay simple).
export async function apiJSON<T = unknown>(path: string, init?: RequestInit): Promise<T | null> {
  try {
    const r = await api(path, init)
    if (!r.ok) return null
    return (await r.json()) as T
  } catch {
    return null
  }
}

// Fire-and-forget action (the page is full of these: buttons that POST/GET).
export function apiDo(path: string, init?: RequestInit): void {
  api(path, init).catch(() => {})
}

// WebSocket URL for the relay signaling / terminal channels (these are relay
// routes, not rctld paths, so they don't go through rctlPath).
export function signalWS(media: 'screen' | 'camera' = 'screen'): string {
  const proto = location.protocol === 'https:' ? 'wss' : 'ws'
  const suffix = media === 'camera' ? '?media=camera' : ''
  return `${proto}://${location.host}/signal/devices/${DEVICE_ID}${suffix}`
}

// WebSocket URL for the PTY bridge. RCTL_TERM_WS_BASE is a path: in relay mode
// the injected /term/devices/{id}; locally empty -> rctld's own /ws/term.
export function termWS(cols: number, rows: number): string {
  const proto = location.protocol === 'https:' ? 'wss' : 'ws'
  const path = TERM_WS_BASE || '/ws/term'
  return `${proto}://${location.host}${path}?cols=${cols}&rows=${rows}`
}
