// Shapes returned by the relay admin API.

export type DeviceStatus = 'pending' | 'approved' | 'revoked'

export interface Device {
  id: string
  name: string
  status: DeviceStatus
  online: boolean
  created_at: number
  updated_at: number
  last_seen_at?: number
  approved_at?: number
  revoked_at?: number
}

export interface Session {
  id: string
  current: boolean
  expires_at: number
  created_at: number
  last_seen_at: number
  ip: string
  user_agent: string
  client_hints?: string
}

export interface Enrollment {
  token: string
  expires_at: string // RFC3339
  relay_url: string
}

export type EnrollmentStatus = 'active' | 'used' | 'expired' | 'revoked'

export interface EnrollmentSummary {
  id: string
  label: string
  status: EnrollmentStatus
  created_at: number
  expires_at: number
  used_at?: number
  revoked_at?: number
}

export interface CreateEnrollmentOptions {
  label?: string
  ttl_seconds?: number
}

export interface DevicesResponse {
  devices: Device[]
}

export interface SessionsResponse {
  sessions: Session[]
}

export interface RevokeResult {
  ok: boolean
  revoked?: number
  current_revoked?: boolean
}

// Live device info, proxied from the device's own /v1/deviceinfo endpoint.
export interface DeviceInfo {
  name?: string
  model?: string
  model_id?: string
  ios?: string
  build?: string
  battery?: string
  battery_state?: string
  brightness?: number
  cpu?: string
  memory?: string
  storage?: string
  uptime?: string
  udid?: string
  serial?: string
  imei?: string
}

export interface AuditEntry {
  id: number
  ts: number
  event: string
  ip: string
  method: string
  path: string
  detail?: string
}

export interface AuditResponse {
  audit: AuditEntry[]
}

export interface RelayStatus {
  version: string
  go_version: string
  started_at: number
  uptime_seconds: number
  devices_total: number
  devices_online: number
  devices_pending: number
  sessions: number
  goroutines: number
  mem_alloc_bytes: number
  mem_sys_bytes: number
}
