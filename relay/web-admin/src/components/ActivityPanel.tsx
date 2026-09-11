import { useMemo, useRef, useState, type ComponentType } from 'react'
import { useVirtualizer } from '@tanstack/react-virtual'
import {
  AlertTriangle,
  Ban,
  Check,
  ChevronDown,
  Clock,
  Download,
  History,
  KeyRound,
  LogIn,
  LogOut,
  Package,
  Pencil,
  Plus,
  Power,
  PlugZap,
  QrCode,
  Radio,
  RefreshCw,
  Search,
  ShieldCheck,
  Smartphone,
  Trash2,
  User,
  X,
  Zap,
  type LucideProps,
} from 'lucide-react'
import { Menu, MenuItem, MenuLabel, MenuSeparator } from './ui/Menu'
import { Panel } from './Shell'
import { fmtRel, humanizeEvent, shortId } from '../lib/format'
import { actorContext, describeActor } from '../lib/actors'
import { cn } from '../lib/cn'
import type { AuditEntry, Controller, Session } from '../types'

type Tone = 'online' | 'danger' | 'signal' | 'muted'

// Curated labels for every event the relay emits. Anything new falls back to
// humanizeEvent so the feed never shows a raw snake_case identifier.
const META: Record<string, { label: string; tone: Tone; icon: ComponentType<LucideProps> }> = {
  admin_login_succeeded: { label: 'Admin signed in', tone: 'online', icon: LogIn },
  admin_login_failed: { label: 'Failed sign-in attempt', tone: 'danger', icon: AlertTriangle },
  admin_logout: { label: 'Admin signed out', tone: 'muted', icon: LogOut },
  admin_device_approved: { label: 'Device approved', tone: 'online', icon: ShieldCheck },
  admin_device_revoked: { label: 'Device access revoked', tone: 'danger', icon: Ban },
  admin_device_deleted: { label: 'Device deleted', tone: 'danger', icon: Trash2 },
  admin_device_update_started: { label: 'Device update started', tone: 'signal', icon: Download },
  admin_device_package_created: { label: 'Device package created', tone: 'signal', icon: Package },
  admin_device_package_failed: { label: 'Device package failed', tone: 'danger', icon: AlertTriangle },
  admin_device_package_download_interrupted: { label: 'Package download interrupted', tone: 'muted', icon: AlertTriangle },
  admin_enrollment_created: { label: 'Enrollment token created', tone: 'signal', icon: Plus },
  admin_enrollment_revoked: { label: 'Enrollment token revoked', tone: 'danger', icon: Ban },
  admin_enrollment_deleted: { label: 'Enrollment token deleted', tone: 'danger', icon: Trash2 },
  admin_enrollment_history_cleared: { label: 'Enrollment history cleared', tone: 'danger', icon: Trash2 },
  admin_session_revoked: { label: 'Session revoked', tone: 'danger', icon: LogOut },
  admin_other_sessions_revoked: { label: 'Other sessions revoked', tone: 'danger', icon: LogOut },
  admin_all_sessions_revoked: { label: 'All sessions revoked', tone: 'danger', icon: LogOut },
  controller_pairing_created: { label: 'Controller pairing code created', tone: 'signal', icon: QrCode },
  controller_pairing_revoked: { label: 'Controller pairing code closed', tone: 'muted', icon: Ban },
  controller_paired: { label: 'Controller paired', tone: 'online', icon: Smartphone },
  controller_access_refreshed: { label: 'Controller renewed access', tone: 'muted', icon: RefreshCw },
  controller_client_updated: { label: 'Controller profile updated', tone: 'muted', icon: Smartphone },
  controller_renamed: { label: 'Controller renamed', tone: 'muted', icon: Pencil },
  controller_permissions_changed: { label: 'Controller permissions changed', tone: 'signal', icon: ShieldCheck },
  controller_revoked: { label: 'Controller access revoked', tone: 'danger', icon: Ban },
  controller_self_revoked: { label: 'Controller revoked its access', tone: 'danger', icon: Ban },
  controller_deleted: { label: 'Controller deleted from history', tone: 'danger', icon: Trash2 },
  controller_history_cleared: { label: 'Controller history cleared', tone: 'danger', icon: Trash2 },
  device_connected: { label: 'Device connected', tone: 'online', icon: PlugZap },
  device_disconnected: { label: 'Device disconnected', tone: 'muted', icon: Power },
  device_enrollment_claimed: { label: 'Enrollment claimed', tone: 'signal', icon: KeyRound },
  device_secret_authenticated: { label: 'Device authenticated', tone: 'online', icon: ShieldCheck },
  device_auth_failed: { label: 'Device auth failed', tone: 'danger', icon: AlertTriangle },
  device_protocol_rejected: { label: 'Device rejected: protocol mismatch', tone: 'danger', icon: AlertTriangle },
  webrtc_signal_open: { label: 'Live control session', tone: 'signal', icon: Radio },
  history_retention_applied: { label: 'Old history auto-cleared', tone: 'muted', icon: History },
}

// Human label for an audit event, reused by the session/controller detail lists.
export function auditLabel(event: string): string {
  return META[event]?.label ?? humanizeEvent(event)
}

const toneText: Record<Tone, string> = {
  online: 'text-online',
  danger: 'text-danger',
  signal: 'text-signal',
  muted: 'text-muted',
}

const RANGES: Record<string, number> = { '1h': 3600, '24h': 86400, '7d': 604800, '30d': 2592000 }
const TIME_OPTS = [
  { key: 'all', label: 'All time' },
  { key: '1h', label: 'Last hour' },
  { key: '24h', label: 'Last 24 hours' },
  { key: '7d', label: 'Last 7 days' },
  { key: '30d', label: 'Last 30 days' },
]

// Keys that only restate the actor (already shown as a tag) or are internal.
const HIDDEN_DETAIL_KEYS = new Set(['controller_name', 'session_id', 'current_session_id', 'retention_seconds'])

function plural(n: unknown, word: string): string {
  return `${String(n)} ${word}${Number(n) === 1 ? '' : 's'}`
}

function summarizeDetail(event: string, detail?: string): string {
  if (!detail) return ''
  try {
    const obj = JSON.parse(detail) as Record<string, unknown>
    if (event === 'history_retention_applied')
      return `${plural(obj.controllers ?? 0, 'controller')} · ${plural(obj.enrollments ?? 0, 'token')}`
    if (event === 'controller_history_cleared') return plural(obj.deleted ?? 0, 'controller')
    if (event === 'admin_enrollment_history_cleared') return plural(obj.deleted ?? 0, 'token')
    return Object.entries(obj)
      .filter(([k]) => !HIDDEN_DETAIL_KEYS.has(k))
      .map(([, v]) => {
        const s = String(v)
        return s.length > 20 ? shortId(s, 10, 4) : s
      })
      .join(' · ')
  } catch {
    return ''
  }
}

type Opt = { key: string; label: string; group?: string; hint?: string }

// A compact filter dropdown built on the shared Radix Menu. Options may carry a
// group name; a label row is rendered whenever the group changes.
function FilterMenu({
  icon: Icon,
  value,
  options,
  onChange,
}: {
  icon: ComponentType<LucideProps>
  value: string
  options: Opt[]
  onChange: (key: string) => void
}) {
  const current = options.find((o) => o.key === value) ?? options[0]
  const active = value !== options[0]?.key
  return (
    <Menu
      align="start"
      trigger={
        <button
          className={cn(
            'inline-flex max-w-[14rem] items-center gap-1.5 rounded-lg px-2.5 py-1.5 text-[12px] ring-1 transition-colors',
            active
              ? 'bg-signal/12 text-signal ring-signal/30'
              : 'bg-surface-2/60 text-fg-dim ring-line/70 hover:text-fg',
          )}
        >
          <Icon className="size-3.5 shrink-0 opacity-80" />
          <span className="truncate">{current?.label}</span>
          <ChevronDown className="size-3.5 shrink-0 opacity-60" />
        </button>
      }
    >
      <div className="max-h-72 overflow-y-auto">
        {options.map((o, i) => {
          const newGroup = o.group && o.group !== options[i - 1]?.group
          return (
            <div key={o.key}>
              {newGroup && (
                <>
                  {i > 0 && <MenuSeparator />}
                  <MenuLabel>{o.group}</MenuLabel>
                </>
              )}
              <MenuItem className="justify-between gap-6" onSelect={() => onChange(o.key)}>
                <span className="min-w-0">
                  <span className="block truncate">{o.label}</span>
                  {o.hint && <span className="block truncate font-mono text-[10.5px] text-faint">{o.hint}</span>}
                </span>
                {o.key === value && <Check className="size-3.5 shrink-0 text-signal" />}
              </MenuItem>
            </div>
          )
        })}
      </div>
    </Menu>
  )
}

export function ActivityPanel({
  entries,
  sessions = [],
  controllers = [],
}: {
  entries: AuditEntry[]
  sessions?: Session[]
  controllers?: Controller[]
}) {
  const [query, setQuery] = useState('')
  const [eventKey, setEventKey] = useState('all')
  const [actorKey, setActorKey] = useState('all')
  const [timeKey, setTimeKey] = useState('all')

  const ctx = useMemo(() => actorContext(sessions, controllers), [sessions, controllers])

  // Build the option lists from the events actually present.
  const eventOpts = useMemo<Opt[]>(() => {
    const seen = new Map<string, string>()
    for (const e of entries) if (!seen.has(e.event)) seen.set(e.event, auditLabel(e.event))
    const opts = [...seen.entries()]
      .map(([key, label]) => ({ key, label }))
      .sort((a, b) => a.label.localeCompare(b.label))
    return [{ key: 'all', label: 'All events' }, ...opts]
  }, [entries])

  // Actors: admins (browser sessions, live ones first) and controllers. Labels come
  // from the write-time snapshot, so expired sessions and deleted controllers stay
  // readable instead of collapsing to an id.
  const actorOpts = useMemo<Opt[]>(() => {
    const admins = new Map<string, Opt & { live: boolean }>()
    const ctls = new Map<string, Opt & { live: boolean }>()
    for (const e of entries) {
      const actor = describeActor(e, ctx)
      if (!actor || actor.kind === 'system') continue
      const bucket = actor.kind === 'admin' ? admins : ctls
      if (bucket.has(actor.key)) continue
      bucket.set(actor.key, {
        key: actor.key,
        label: actor.live ? actor.label : `${actor.label} · ${actor.kind === 'admin' ? 'signed out' : 'deleted'}`,
        hint: actor.sub,
        group: actor.kind === 'admin' ? 'Admins' : 'Controllers',
        live: actor.live,
      })
    }
    const order = (a: { live: boolean; label: string }, b: { live: boolean; label: string }) =>
      Number(b.live) - Number(a.live) || a.label.localeCompare(b.label)
    return [
      { key: 'all', label: 'Everyone' },
      ...[...admins.values()].sort(order),
      ...[...ctls.values()].sort(order),
    ]
  }, [entries, ctx])

  const q = query.trim().toLowerCase()
  const cutoff = timeKey === 'all' ? 0 : Date.now() / 1000 - (RANGES[timeKey] ?? 0)
  const filtered = useMemo(
    () =>
      entries.filter((e) => {
        if (eventKey !== 'all' && e.event !== eventKey) return false
        const actor = actorKey !== 'all' || q ? describeActor(e, ctx) : null
        if (actorKey !== 'all' && actor?.key !== actorKey) return false
        if (cutoff && e.ts < cutoff) return false
        if (q && !`${auditLabel(e.event)} ${e.ip} ${e.detail ?? ''} ${actor?.label ?? ''} ${actor?.sub ?? ''}`.toLowerCase().includes(q))
          return false
        return true
      }),
    [entries, eventKey, actorKey, cutoff, q, ctx],
  )

  const filtersOn = !!q || eventKey !== 'all' || actorKey !== 'all' || timeKey !== 'all'
  const clear = () => {
    setQuery('')
    setEventKey('all')
    setActorKey('all')
    setTimeKey('all')
  }

  // Virtualize: render only the visible rows so the list stays smooth at any size
  // (10k+ events). The DOM holds ~20 nodes regardless of how many events there are.
  const parentRef = useRef<HTMLDivElement>(null)
  const virt = useVirtualizer({
    count: filtered.length,
    getScrollElement: () => parentRef.current,
    estimateSize: () => 52,
    overscan: 12,
  })

  return (
    <Panel
      title="Activity"
      subtitle={`${filtered.length} of ${entries.length} event${entries.length === 1 ? '' : 's'}`}
    >
      <div className="space-y-2.5 border-b border-line/60 px-5 py-3">
        <div className="relative">
          <Search className="pointer-events-none absolute left-2.5 top-1/2 size-3.5 -translate-y-1/2 text-faint" />
          <input
            value={query}
            onChange={(e) => setQuery(e.target.value)}
            placeholder="Search activity…"
            className="w-full rounded-lg bg-surface-2/60 py-1.5 pl-8 pr-2.5 text-[12.5px] text-fg ring-1 ring-line/70 placeholder:text-faint focus:outline-none focus:ring-signal/40"
          />
        </div>
        <div className="flex flex-wrap items-center gap-2">
          <FilterMenu icon={Zap} value={eventKey} options={eventOpts} onChange={setEventKey} />
          <FilterMenu icon={User} value={actorKey} options={actorOpts} onChange={setActorKey} />
          <FilterMenu icon={Clock} value={timeKey} options={TIME_OPTS} onChange={setTimeKey} />
          {filtersOn && (
            <button
              onClick={clear}
              className="inline-flex items-center gap-1 rounded-lg px-2 py-1.5 text-[12px] text-muted transition-colors hover:text-fg"
            >
              <X className="size-3.5" />
              Clear
            </button>
          )}
        </div>
      </div>

      {filtered.length === 0 ? (
        <div className="px-5 py-10 text-center">
          <div className="mx-auto grid size-10 place-items-center rounded-xl bg-surface-2 text-faint ring-1 ring-line">
            <History className="size-5" />
          </div>
          <p className="mt-3 text-[13px] text-muted">
            {entries.length ? 'No activity matches these filters.' : 'No activity recorded yet.'}
          </p>
        </div>
      ) : (
        <div ref={parentRef} className="max-h-[28rem] overflow-y-auto">
          <div className="relative w-full" style={{ height: `${virt.getTotalSize()}px` }}>
            {virt.getVirtualItems().map((vi) => {
              const e = filtered[vi.index]
              const meta = META[e.event] ?? { label: humanizeEvent(e.event), tone: 'muted' as Tone, icon: History }
              const Icon = meta.icon
              const summary = summarizeDetail(e.event, e.detail)
              const actor = describeActor(e, ctx)
              return (
                <div
                  key={e.id}
                  ref={virt.measureElement}
                  data-index={vi.index}
                  style={{ position: 'absolute', top: 0, left: 0, width: '100%', transform: `translateY(${vi.start}px)` }}
                  className="flex items-center gap-3 border-b border-line/60 px-5 py-2.5"
                >
                  <div
                    className={cn(
                      'grid size-7 shrink-0 place-items-center rounded-lg bg-surface-2 ring-1 ring-line',
                      toneText[meta.tone],
                    )}
                  >
                    <Icon className="size-3.5" />
                  </div>
                  <div className="min-w-0 flex-1">
                    <div className="flex items-center gap-2">
                      <span className="truncate text-[13px] font-medium text-fg-dim">{meta.label}</span>
                      {actor && actor.kind !== 'system' && (
                        <button
                          type="button"
                          onClick={() => setActorKey(actor.key)}
                          title={actor.kind === 'controller' ? 'Controller · click to filter' : 'Admin session · click to filter'}
                          className={cn(
                            'inline-flex max-w-[11rem] shrink-0 items-center gap-1 rounded px-1.5 py-px text-[10px] font-medium ring-1 transition-colors',
                            actor.kind === 'controller'
                              ? 'bg-signal/8 text-signal/90 ring-signal/25 hover:bg-signal/14'
                              : 'bg-surface-2 text-muted ring-line/70 hover:text-fg',
                          )}
                        >
                          {actor.kind === 'controller' ? <Smartphone className="size-2.5" /> : <User className="size-2.5" />}
                          <span className="truncate">{actor.label}</span>
                        </button>
                      )}
                    </div>
                    <div className="mt-0.5 truncate font-mono text-[10.5px] text-faint">
                      {[summary, e.ip].filter(Boolean).join(' · ') || '—'}
                    </div>
                  </div>
                  <span className="shrink-0 text-[11px] text-muted tnum">{fmtRel(e.ts)}</span>
                </div>
              )
            })}
          </div>
        </div>
      )}
    </Panel>
  )
}
