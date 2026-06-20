// Thin client over the relay admin API. Cookies carry the session, so every
// request is credentialed same-origin. A 401 means "not signed in".

import type {
  AuditResponse,
  CreateEnrollmentOptions,
  DeviceInfo,
  DevicesResponse,
  DiagnosticsResponse,
  Enrollment,
  EnrollmentSummary,
  RelayStatus,
  RevokeResult,
  SessionsResponse,
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
    headers: { 'Content-Type': 'application/json', ...(options.headers || {}) },
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

interface Ok {
  ok: boolean
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
  respringDevice: (id: string) =>
    request<unknown>(`/proxy/devices/${encodeURIComponent(id)}/v1/respring`, { method: 'POST' }),

  status: () => request<RelayStatus>('/api/admin/status'),
  audit: (limit = 100) => request<AuditResponse>(`/api/admin/audit?limit=${limit}`),

  enrollments: () => request<EnrollmentsResponse>('/api/admin/enrollments'),
  createEnrollment: (opts: CreateEnrollmentOptions = {}) =>
    request<Enrollment>('/api/admin/enrollments', {
      method: 'POST',
      body: JSON.stringify(opts),
    }),
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
}

export const controlURL = (id: string): string =>
  `/control/devices/${encodeURIComponent(id)}`
