// Connection + path layer for the control page. The page runs in two modes:
//  - device-local (LAN/USB): served by rctld itself, all paths hit rctld directly.
//  - relay: served by the relay, which injects window globals so requests are
//    proxied to the device through the relay.
// The vanilla page monkey-patched window.fetch to rewrite paths; here it's an
// explicit api()/wsURL() wrapper instead -- same behavior, no global patching.

import type { GuestPermission } from './guestPermissions.generated'

export interface GuestAccess {
  session_id: string
  grant_id: string
  label: string
  permissions: GuestPermission[]
  authorization_revision: number
  expires_at: number
  allow_direct: boolean
}

const w = window as unknown as Record<string, unknown>

export const PROXY_BASE = String(w.RCTL_PROXY_BASE || '').replace(/\/$/, '')
export const STREAM_BASE = String(w.RCTL_STREAM_BASE || '').replace(/\/$/, '')
export const TERM_WS_BASE = String(w.RCTL_TERM_WS_BASE || '').replace(/\/$/, '')
export const DEVICE_ID = String(w.RCTL_RELAY_DEVICE_ID || '')
export const GUEST_ACCESS = (w.RCTL_GUEST_BOOTSTRAP as GuestAccess | undefined) ?? null
export const guestHas = (permission: GuestPermission) => !!GUEST_ACCESS?.permissions.includes(permission)
export function guestButtonHas(name: string): boolean {
  if (name === 'home') return guestHas('input.button.home')
  if (name === 'lock') return guestHas('input.button.lock')
  if (name === 'volup' || name === 'voldn') return guestHas('input.button.volume')
  return false
}
export const RELAY_MODE = !!(GUEST_ACCESS || PROXY_BASE || STREAM_BASE)
// The relay's configured tunnel body cap (bytes), when the page is relay-served.
// Device-local HTTP has no such cap; 0 means "unknown/not relayed".
export const RELAY_TUNNEL_MAX_BODY = Number(w.RCTL_RELAY_TUNNEL_MAX_BODY || 0)
export const WEBRTC_MODE = RELAY_MODE && !!w.RCTL_WEBRTC && 'RTCPeerConnection' in window

// Map an rctld path to the relay proxy when in relay mode (identity locally).
export function rctlPath(path: string): string {
  if (GUEST_ACCESS) throw new Error('This operation is unavailable in guest access')
  if (!RELAY_MODE || typeof path !== 'string' || path[0] !== '/') return path
  if (path === '/stream' || path.startsWith('/stream?')) {
    return STREAM_BASE ? STREAM_BASE + '/stream' + path.slice('/stream'.length) : path
  }
  if (/^\/(v1\/|input|key|config|orient)/.test(path)) return PROXY_BASE + path
  return path
}

export function fileDownloadURL(path: string): string {
  if (GUEST_ACCESS) throw new Error('This operation is unavailable in guest access')
  const endpoint = `/v1/pull_stream?path=${encodeURIComponent(path)}`
  return RELAY_MODE && STREAM_BASE ? STREAM_BASE + endpoint : endpoint
}

// Device-local mode is token-gated: the page fetches the LAN token once from
// the header-gated bootstrap endpoint and presents it on every request. Relay
// mode needs no token — the relay's authenticated tunnel presents its own
// device-side credential, and guests keep the relay's guest authorization.
let lanToken = ''
let bootstrapInFlight: Promise<boolean> | null = null

async function runBootstrap(): Promise<boolean> {
  try {
    const response = await fetch('/v1/bootstrap', {
      headers: { 'X-Rctl-Bootstrap': '1' },
      cache: 'no-store',
    })
    if (response.ok) {
      const json = (await response.json().catch(() => null)) as { token?: string } | null
      lanToken = typeof json?.token === 'string' ? json.token : ''
    }
  } catch {
    /* unreachable device: the UI explains the failure through its own status */
  }
  return lanToken !== ''
}

// Single flight: concurrent 403s share one refresh instead of racing.
export async function bootstrapLAN(): Promise<boolean> {
  if (RELAY_MODE) return true
  if (!bootstrapInFlight) {
    bootstrapInFlight = runBootstrap().finally(() => { bootstrapInFlight = null })
  }
  return bootstrapInFlight
}

export function lanAuthorized(): boolean {
  return RELAY_MODE || lanToken !== ''
}

async function fetchDownloadURL(path: string): Promise<string> {
  if (RELAY_MODE) return fileDownloadURL(path)   // the stream tunnel is hop-authenticated
  // The browser's download manager cannot attach the token header: exchange
  // the path for a short-lived single-use ticket first. The body is the same
  // URL-encoded form the device's bounded gate parser reads.
  const response = await api('/v1/download_ticket', {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: `path=${encodeURIComponent(path)}`,
  })
  const json = (await response.json().catch(() => null)) as { ticket?: string } | null
  if (!response.ok || !json?.ticket) throw new Error(json && 'error' in json ? String((json as { error?: string }).error) : 'download_unauthorized')
  return `/v1/pull_stream?path=${encodeURIComponent(path)}&ticket=${encodeURIComponent(json.ticket)}`
}

// The browser's download manager cannot attach the token header: exchange
// the path for a short-lived single-use ticket first. The body is the same
// URL-encoded form the device's bounded gate parser reads (encodeURIComponent
// so spaces stay %-encoded, not '+' — the device decoder handles %xx only).
export async function downloadFile(path: string, name: string): Promise<void> {
  const anchor = document.createElement('a')
  anchor.href = await fetchDownloadURL(path)
  anchor.download = name
  document.body.appendChild(anchor)
  anchor.click()
  anchor.remove()
}

export function api(path: string, init?: RequestInit): Promise<Response> {
  return authorizedFetch(path, init, false)
}

// Adds the LAN token in device-local mode and refreshes it exactly once when
// the gateway reports the token was regenerated (e.g. after a reinstall). A
// missing token (page mounted before bootstrap succeeded) also gets one
// refresh attempt so a slow first bootstrap cannot wedge the session.
async function authorizedFetch(path: string, init: RequestInit | undefined, retried: boolean): Promise<Response> {
  let headers = init?.headers
  if (lanToken) {
    headers = new Headers(headers)
    headers.set('X-Rctl-Token', lanToken)
  }
  const response = await fetch(rctlPath(path), { ...init, headers })
  if (response.status === 403 && !retried && !RELAY_MODE) {
    const body = (await response.clone().json().catch(() => null)) as { error?: string } | null
    if (body?.error === 'lan_token_invalid' || body?.error === 'lan_token_required') {
      lanToken = ''
      if (await bootstrapLAN()) return authorizedFetch(path, init, true)
    }
  }
  return response
}

export type DestructiveAction = 'file_delete' | 'package_remove' | 'tweak_toggle' | 'respring'

export async function destructiveToken(action: DestructiveAction, target: string): Promise<string> {
  const response = await api('/v1/confirmation', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ action, target }),
  })
  const json = (await response.json().catch(() => null)) as { token?: string; error?: string } | null
  if (!response.ok || !json?.token) throw new Error(json?.error || 'confirmation_rejected')
  return json.token
}

export async function destructivePost<T>(
  path: string,
  action: DestructiveAction,
  target: string,
  body: Record<string, unknown> = {},
): Promise<T> {
  const token = await destructiveToken(action, target)
  const response = await api(path, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ ...body, token }),
  })
  const json = (await response.json().catch(() => null)) as (T & { error?: string }) | null
  if (!response.ok || !json) throw new Error(json?.error || 'destructive_action_failed')
  return json
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
export function signalWS(media: 'screen' | 'camera' | 'operations' = 'screen'): string {
  const proto = location.protocol === 'https:' ? 'wss' : 'ws'
  if (GUEST_ACCESS) return `${proto}://${location.host}/api/guest/signal${media === 'screen' ? '' : `?media=${media}`}`
  const suffix = media === 'camera' ? '?media=camera' : ''
  return `${proto}://${location.host}/signal/devices/${DEVICE_ID}${suffix}`
}

// WebSocket URL for the PTY bridge. RCTL_TERM_WS_BASE is a path: in relay mode
// the injected /term/devices/{id}; locally empty -> rctld's own /ws/term.
export function termWS(cols: number, rows: number): string {
  const proto = location.protocol === 'https:' ? 'wss' : 'ws'
  if (GUEST_ACCESS) throw new Error('This operation is unavailable in guest access')
  const path = TERM_WS_BASE || '/ws/term'
  return `${proto}://${location.host}${path}?cols=${cols}&rows=${rows}`
}

// Browser WebSocket clients cannot set custom headers, so the LAN token
// travels as the subprotocol the device gateway validates (and echoes) before
// accepting the upgrade. Relay WS routes authenticate at the relay instead.
export function wsProtocols(): string[] | undefined {
  return lanToken && !RELAY_MODE ? [`rctl.auth.${lanToken}`] : undefined
}

// Element-src endpoints (thumbnails, previews) cannot carry the token header:
// fetch them through the authorized wrapper and hand back a blob URL. A small
// shared concurrency limit keeps a full media grid from monopolizing the
// device's bounded connection pool.
// Slot handoff: the queue is a chain of resolvers — a finishing fetch passes
// its slot straight to the next waiter without touching the counter.
const BLOB_FETCH_LIMIT = 6
let blobFetchActive = 0
const blobFetchQueue: (() => void)[] = []

function acquireBlobSlot(): Promise<void> {
  return new Promise((resolve) => {
    if (blobFetchActive < BLOB_FETCH_LIMIT) {
      blobFetchActive++
      resolve()
    } else {
      blobFetchQueue.push(resolve)
    }
  })
}

function releaseBlobSlot(): void {
  const next = blobFetchQueue.shift()
  if (next) next()
  else blobFetchActive--
}

export async function fetchBlob(path: string, init?: RequestInit): Promise<Blob | null> {
  await acquireBlobSlot()
  try {
    const response = await api(path, init)
    if (!response.ok) return null
    return await response.blob()
  } catch {
    return null
  } finally {
    releaseBlobSlot()
  }
}
