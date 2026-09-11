import { describeClient, shortId } from './format'
import type { AuditActorKind, AuditEntry, Controller, Session } from '../types'

// Who performed an audit event, rendered from the snapshot the relay took when
// the event was written. Live objects (a still-open session, a still-listed
// controller) refine the label; their absence never degrades it to a raw id.
export interface ActorInfo {
  key: string
  kind: AuditActorKind | ''
  label: string
  sub: string // secondary text: IP for admins, platform for controllers
  live: boolean
}

export interface ActorContext {
  sessions: Map<string, Session>
  controllers: Map<string, Controller>
}

export function actorContext(sessions: Session[] = [], controllers: Controller[] = []): ActorContext {
  return {
    sessions: new Map(sessions.map((s) => [s.id, s])),
    controllers: new Map(controllers.map((c) => [c.id, c])),
  }
}

export function describeActor(e: AuditEntry, ctx: ActorContext): ActorInfo | null {
  const kind = e.actor_kind ?? (e.session_id ? 'admin' : '')
  const id = e.actor_id || e.session_id || ''
  if (kind === 'admin') {
    if (!id) return null
    const session = ctx.sessions.get(id)
    const ua = e.actor_ua || session?.user_agent
    // Rows older than the actor snapshot may have no browser fingerprint at all;
    // name them for what they are rather than "Unknown client".
    const label = ua ? describeClient(ua, e.actor_hints || session?.client_hints, e.actor_touch ?? session?.touch_points) : 'Admin session'
    return { key: id, kind, label, sub: session?.ip || e.ip || '', live: !!session }
  }
  if (kind === 'controller') {
    if (!id) return null
    const controller = ctx.controllers.get(id)
    const label = controller?.name || e.actor_label || `Deleted controller ${shortId(id, 8, 0)}`
    const sub = controller ? controller.platform.toUpperCase() : e.actor_label ? 'deleted' : ''
    return { key: id, kind, label, sub, live: !!controller }
  }
  if (kind === 'system') return { key: 'system', kind, label: 'Relay', sub: 'automatic', live: true }
  return null
}

// Events that concern a controller, whether it acted or was acted upon.
export function concernsController(e: AuditEntry, controllerID: string): boolean {
  if (e.actor_kind === 'controller' && e.actor_id === controllerID) return true
  if (!e.detail) return false
  try {
    const detail = JSON.parse(e.detail) as { controller_id?: unknown }
    return detail.controller_id === controllerID
  } catch {
    return false
  }
}
