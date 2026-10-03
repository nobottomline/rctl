import { request } from './api'
import type { GuestPermission } from './guestPermissions.generated'

export interface GuestGrant {
  id: string
  device_id: string
  device_name: string
  label: string
  permissions: GuestPermission[]
  authorization_revision: number
  expires_at: number
  created_at: number
  claim_deadline: number
  status: 'invited' | 'active' | 'expired' | 'ended' | 'revoked'
  connections: number
  allow_direct: boolean
}
export interface GuestInvitation {
  id: string
  invitation_url: string
  expires_at: number
  claim_deadline: number
}
export interface GuestDisconnectResult { ok: boolean; disconnect_confirmed: boolean }
export const guestAPI = {
  list: () => request<{ grants: GuestGrant[] }>('/api/admin/guest-grants'),
  create: (body: { device_id: string; label: string; permissions: GuestPermission[]; ttl_seconds: number; allow_direct: boolean }) =>
    request<GuestInvitation>('/api/admin/guest-grants', { method: 'POST', body: JSON.stringify(body) }),
  permissions: (grant: GuestGrant, permissions: GuestPermission[]) =>
    request<GuestDisconnectResult & { changed: boolean }>('/api/admin/guest-grants/' + encodeURIComponent(grant.id) + '/permissions', {
      method: 'POST', body: JSON.stringify({ permissions, expected_revision: grant.authorization_revision }),
    }),
  revoke: (id?: string) => request<GuestDisconnectResult>(id ? '/api/admin/guest-grants/' + encodeURIComponent(id) + '/revoke' : '/api/admin/guest-grants/revoke-all', { method: 'POST', body: '{}' }),
  remove: (id: string) => request<{ ok: boolean }>('/api/admin/guest-grants/' + encodeURIComponent(id) + '/delete', { method: 'POST', body: '{}' }),
}
