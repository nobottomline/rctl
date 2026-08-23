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
  daemon_version?: string
  browser_version?: string
  protocol_major?: number
  protocol_minor?: number
  features: string[]
  compatible: boolean
  compatibility_error?: string
  legacy_protocol?: boolean
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
  touch_points?: number // navigator.maxTouchPoints; >1 means an iPad (which sends a macOS UA)
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

export interface CreateDevicePackageOptions extends CreateEnrollmentOptions {
  device_name: string
}

export interface LocalAccessStatus {
  enabled: boolean
  mode: 'lan' | 'relay-only'
  listen: string
  restarting: boolean
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

// Generic grouped diagnostics from the device's /v1/diagnostics (daemon-gathered).
// The UI renders whatever categories/fields the device reports, so new data needs
// no frontend change.
export interface DiagField {
  label: string
  value: string
}
export interface DiagCategory {
  title: string
  fields: DiagField[]
}
export interface DiagnosticsResponse {
  categories: DiagCategory[]
}

export interface AuditEntry {
  id: number
  ts: number
  event: string
  ip: string
  session_id?: string
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
  protocol_major: number
  protocol_minor: number
  features: string[]
  update_configured: boolean
  update_target_version?: string
  device_package_available: boolean
  device_package_version?: string
}

export interface UpdateStatus {
  job_id?: string
  phase: string
  message?: string
  from_version?: string
  to_version?: string
  terminal: boolean
  updated_at?: number
}
