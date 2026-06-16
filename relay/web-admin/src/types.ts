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
}

export interface Enrollment {
  token: string
  expires_at: string // RFC3339
  relay_url: string
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
