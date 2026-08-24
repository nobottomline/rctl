// Thin client over the relay admin API. Cookies carry the session, so every
// request is credentialed same-origin. A 401 means "not signed in".

import type {
  AuditResponse,
  CreateEnrollmentOptions,
  CreateDevicePackageOptions,
  ControllerPairing,
  ControllerScope,
  ControllersResponse,
  DeviceInfo,
  DevicesResponse,
  DiagnosticsResponse,
  Enrollment,
  EnrollmentSummary,
  LocalAccessStatus,
  RelayStatus,
  RevokeResult,
  SessionsResponse,
  UpdateStatus,
} from '../types'

interface EnrollmentsResponse {
  enrollments: EnrollmentSummary[]
}

export class ApiError extends Error {
  status: number
  constructor(message: string, status: number) {
    super(message)
    this.name = 'ApiError'
    this.status = status
  }
}

async function request<T>(path: string, options: RequestInit = {}): Promise<T> {
  const res = await fetch(path, {
    credentials: 'same-origin',
    ...options,
    headers: {
      'Content-Type': 'application/json',
      // iPadOS Safari masquerades as macOS in its User-Agent; send the touch-point
      // count so the relay can tell an iPad from a Mac in the sessions list.
      'X-RCTL-Touch': String((typeof navigator !== 'undefined' && navigator.maxTouchPoints) || 0),
      ...(options.headers || {}),
    },
  })
  let body: unknown = {}
  try {
    body = await res.json()
  } catch {
    /* empty body is fine */
  }
  if (!res.ok) {
    const message = (body as { error?: string }).error || res.statusText
    throw new ApiError(message, res.status)
  }
  return body as T
}

async function requestDownload(path: string, body: unknown): Promise<{ blob: Blob; filename: string }> {
  const res = await fetch(path, {
    method: 'POST',
    credentials: 'same-origin',
    headers: {
      'Content-Type': 'application/json',
      'X-RCTL-Touch': String((typeof navigator !== 'undefined' && navigator.maxTouchPoints) || 0),
    },
    body: JSON.stringify(body),
  })
  if (!res.ok) {
    let message = res.statusText
    try {
      message = ((await res.json()) as { error?: string }).error || message
    } catch {
      /* non-JSON proxy errors retain their HTTP status text */
    }
    throw new ApiError(message, res.status)
  }
  const disposition = res.headers.get('Content-Disposition') || ''
  const match = disposition.match(/filename=(?:"([^"]+)"|([^;\s]+))/)
  return { blob: await res.blob(), filename: match?.[1] || match?.[2] || 'rctl-relay-device.deb' }
}

function saveDownload(blob: Blob, filename: string) {
  const url = URL.createObjectURL(blob)
  const anchor = document.createElement('a')
  anchor.href = url
  anchor.download = filename
  anchor.style.display = 'none'
  document.body.appendChild(anchor)
  anchor.click()
  anchor.remove()
  window.setTimeout(() => URL.revokeObjectURL(url), 30_000)
}

interface Ok {
  ok: boolean
}

async function respringDevice(id: string): Promise<unknown> {
  const base = `/proxy/devices/${encodeURIComponent(id)}`
  const confirmation = await request<{ token: string }>(`${base}/v1/confirmation`, {
    method: 'POST',
    body: JSON.stringify({ action: 'respring', target: 'SpringBoard' }),
  })
  return request<unknown>(`${base}/v1/respring`, {
    method: 'POST',
    body: JSON.stringify({ token: confirmation.token }),
  })
}

async function setLocalAccess(id: string, enabled: boolean): Promise<LocalAccessStatus> {
  const base = `/proxy/devices/${encodeURIComponent(id)}`
  const target = enabled ? 'lan' : 'relay-only'
  const confirmation = await request<{ token: string }>(`${base}/v1/confirmation`, {
    method: 'POST',
    body: JSON.stringify({ action: 'local_access', target }),
  })
  return request<LocalAccessStatus>(`${base}/v1/local_access`, {
    method: 'POST',
    body: JSON.stringify({ enabled, token: confirmation.token }),
  })
}

export const api = {
  login: (secret: string) =>
    request<Ok>('/api/admin/login', { method: 'POST', body: JSON.stringify({ secret }) }),
  logout: () => request<Ok>('/api/admin/logout', { method: 'POST' }),

  devices: () => request<DevicesResponse>('/api/admin/devices'),
  deviceInfo: (id: string) =>
    request<DeviceInfo>(`/proxy/devices/${encodeURIComponent(id)}/v1/deviceinfo`),
  diagnostics: (id: string) =>
    request<DiagnosticsResponse>(`/proxy/devices/${encodeURIComponent(id)}/v1/diagnostics`),
  localAccess: (id: string) =>
    request<LocalAccessStatus>(`/proxy/devices/${encodeURIComponent(id)}/v1/local_access`),
  setLocalAccess,
  respringDevice,
  updateDevice: (id: string) =>
    request<{ accepted: boolean; job_id: string }>(`/api/admin/devices/${encodeURIComponent(id)}/update`, {
      method: 'POST',
    }),
  updateStatus: (id: string) =>
    request<UpdateStatus>(`/proxy/devices/${encodeURIComponent(id)}/v1/update_status`),

  status: () => request<RelayStatus>('/api/admin/status'),
  audit: (limit = 100) => request<AuditResponse>(`/api/admin/audit?limit=${limit}`),

  enrollments: () => request<EnrollmentsResponse>('/api/admin/enrollments'),
  createEnrollment: (opts: CreateEnrollmentOptions = {}) =>
    request<Enrollment>('/api/admin/enrollments', {
      method: 'POST',
      body: JSON.stringify(opts),
    }),
  createDevicePackage: async (opts: CreateDevicePackageOptions) => {
    const download = await requestDownload('/api/admin/device-package', opts)
    saveDownload(download.blob, download.filename)
    return download.filename
  },
  revokeEnrollment: (id: string) =>
    request<{ ok: boolean }>(`/api/admin/enrollments/${encodeURIComponent(id)}/revoke`, {
      method: 'POST',
    }),
  deleteEnrollment: (id: string) =>
    request<{ ok: boolean }>(`/api/admin/enrollments/${encodeURIComponent(id)}/delete`, {
      method: 'POST',
    }),
  approveDevice: (id: string) =>
    request<Ok>(`/api/admin/devices/${encodeURIComponent(id)}/approve`, { method: 'POST' }),
  revokeDevice: (id: string) =>
    request<Ok>(`/api/admin/devices/${encodeURIComponent(id)}/revoke`, { method: 'POST' }),
  deleteDevice: (id: string) =>
    request<Ok>(`/api/admin/devices/${encodeURIComponent(id)}/delete`, { method: 'POST' }),

  sessions: () => request<SessionsResponse>('/api/admin/sessions'),
  revokeSession: (id: string) =>
    request<RevokeResult>(`/api/admin/sessions/${encodeURIComponent(id)}/revoke`, {
      method: 'POST',
    }),
  revokeOtherSessions: () =>
    request<RevokeResult>('/api/admin/sessions/revoke-others', { method: 'POST' }),
  revokeAllSessions: () =>
    request<RevokeResult>('/api/admin/sessions/revoke-all', { method: 'POST' }),

  controllers: () => request<ControllersResponse>('/api/admin/controllers'),
  createControllerPairing: (options: { name: string; scopes: ControllerScope[]; ttl_seconds: number }) =>
    request<{ pairing: ControllerPairing }>('/api/admin/controller-pairings', {
      method: 'POST',
      body: JSON.stringify(options),
    }),
  revokeControllerPairing: (id: string) =>
    request<Ok>(`/api/admin/controller-pairings/${encodeURIComponent(id)}/revoke`, {
      method: 'POST',
    }),
  renameController: (id: string, name: string) =>
    request<Ok & { name: string }>(`/api/admin/controllers/${encodeURIComponent(id)}/rename`, {
      method: 'POST',
      body: JSON.stringify({ name }),
    }),
  revokeController: (id: string) =>
    request<Ok>(`/api/admin/controllers/${encodeURIComponent(id)}/revoke`, {
      method: 'POST',
    }),
}

export const controlURL = (id: string): string =>
  `/control/devices/${encodeURIComponent(id)}`
