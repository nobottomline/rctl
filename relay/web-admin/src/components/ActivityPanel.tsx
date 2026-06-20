import { useMemo, useState, type ComponentType } from 'react'
import { AnimatePresence, motion } from 'framer-motion'
import {
  AlertTriangle,
  Ban,
  History,
  KeyRound,
  LogIn,
  LogOut,
  Plus,
  Power,
  PlugZap,
  Radio,
  Search,
  ShieldCheck,
  Trash2,
  type LucideProps,
} from 'lucide-react'
import { Panel } from './Shell'
import { describeClient, fmtRel, shortId } from '../lib/format'
import { cn } from '../lib/cn'
import type { AuditEntry, Session } from '../types'

type Tone = 'online' | 'danger' | 'signal' | 'muted'

const META: Record<string, { label: string; tone: Tone; icon: ComponentType<LucideProps> }> = {
  admin_login_succeeded: { label: 'Admin signed in', tone: 'online', icon: LogIn },
  admin_login_failed: { label: 'Failed sign-in attempt', tone: 'danger', icon: AlertTriangle },
  admin_logout: { label: 'Admin signed out', tone: 'muted', icon: LogOut },
  admin_device_approved: { label: 'Device approved', tone: 'online', icon: ShieldCheck },
  admin_device_revoked: { label: 'Device access revoked', tone: 'danger', icon: Ban },
  admin_device_deleted: { label: 'Device deleted', tone: 'danger', icon: Trash2 },
  admin_enrollment_created: { label: 'Enrollment token created', tone: 'signal', icon: Plus },
  admin_enrollment_revoked: { label: 'Enrollment token revoked', tone: 'danger', icon: Ban },
  admin_enrollment_deleted: { label: 'Enrollment token deleted', tone: 'danger', icon: Trash2 },
  admin_session_revoked: { label: 'Session revoked', tone: 'danger', icon: LogOut },
  admin_other_sessions_revoked: { label: 'Other sessions revoked', tone: 'danger', icon: LogOut },
  admin_all_sessions_revoked: { label: 'All sessions revoked', tone: 'danger', icon: LogOut },
  device_connected: { label: 'Device connected', tone: 'online', icon: PlugZap },
  device_disconnected: { label: 'Device disconnected', tone: 'muted', icon: Power },
  device_enrollment_claimed: { label: 'Enrollment claimed', tone: 'signal', icon: KeyRound },
  device_secret_authenticated: { label: 'Device authenticated', tone: 'online', icon: ShieldCheck },
  device_auth_failed: { label: 'Device auth failed', tone: 'danger', icon: AlertTriangle },
  webrtc_signal_open: { label: 'Live control session', tone: 'signal', icon: Radio },
}

// Human label for an audit event, reused by the session detail's activity list.
export function auditLabel(event: string): string {
  return META[event]?.label ?? event
}

const toneText: Record<Tone, string> = {
  online: 'text-online',
  danger: 'text-danger',
  signal: 'text-signal',
  muted: 'text-muted',
}

const FILTERS: { key: string; label: string }[] = [
  { key: 'all', label: 'All' },
  { key: 'admin', label: 'Admin' },
  { key: 'device', label: 'Devices' },
  { key: 'live', label: 'Live' },
]

function categoryOf(event: string): string {
  if (event.startsWith('admin_')) return 'admin'
  if (event.startsWith('device_')) return 'device'
  if (event === 'webrtc_signal_open') return 'live'
  return 'other'
}

function summarizeDetail(detail?: string): string {
  if (!detail) return ''
  try {
    const obj = JSON.parse(detail) as Record<string, unknown>
    return Object.values(obj)
      .map((v) => {
        const s = String(v)
        return s.length > 20 ? shortId(s, 10, 4) : s
      })
      .join(' · ')
  } catch {
    return ''
  }
}

export function ActivityPanel({
  entries,
  sessions = [],
}: {
  entries: AuditEntry[]
  sessions?: Session[]
}) {
  const [cat, setCat] = useState('all')
  const [query, setQuery] = useState('')

  // Resolve the acting admin for each event from its session id (browser brand);
  // falls back to "admin" once that session is gone, "" for device/system events.
  const sessMap = useMemo(() => new Map(sessions.map((s) => [s.id, s])), [sessions])
  const actorOf = (e: AuditEntry): string => {
    if (!e.session_id) return ''
    const s = sessMap.get(e.session_id)
    return s ? describeClient(s.user_agent, s.client_hints).split(' · ')[0] : 'admin'
  }

  const q = query.trim().toLowerCase()
  const filtered = useMemo(
    () =>
      entries.filter((e) => {
        if (cat !== 'all' && categoryOf(e.event) !== cat) return false
        if (!q) return true
        const hay = `${auditLabel(e.event)} ${e.ip} ${e.detail ?? ''} ${actorOf(e)}`.toLowerCase()
        return hay.includes(q)
      }),
    // eslint-disable-next-line react-hooks/exhaustive-deps
    [entries, cat, q, sessMap],
  )

  return (
    <Panel
      title="Activity"
      subtitle={`${filtered.length} of ${entries.length} event${entries.length === 1 ? '' : 's'}`}
    >
      <div className="flex flex-wrap items-center gap-2 border-b border-line/60 px-5 py-3">
        <div className="relative min-w-0 flex-1">
          <Search className="pointer-events-none absolute left-2.5 top-1/2 size-3.5 -translate-y-1/2 text-faint" />
          <input
            value={query}
            onChange={(e) => setQuery(e.target.value)}
            placeholder="Search activity…"
            className="w-full rounded-lg bg-surface-2/60 py-1.5 pl-8 pr-2.5 text-[12.5px] text-fg ring-1 ring-line/70 placeholder:text-faint focus:outline-none focus:ring-signal/40"
          />
        </div>
        <div className="flex shrink-0 items-center gap-1">
          {FILTERS.map((f) => (
            <button
              key={f.key}
              onClick={() => setCat(f.key)}
              className={cn(
                'rounded-md px-2.5 py-1 text-[11.5px] font-medium transition-colors',
                cat === f.key
                  ? 'bg-signal/15 text-signal ring-1 ring-signal/30'
                  : 'text-muted hover:text-fg-dim',
              )}
            >
              {f.label}
            </button>
          ))}
        </div>
      </div>

      {filtered.length === 0 ? (
        <div className="px-5 py-10 text-center">
          <div className="mx-auto grid size-10 place-items-center rounded-xl bg-surface-2 text-faint ring-1 ring-line">
            <History className="size-5" />
          </div>
          <p className="mt-3 text-[13px] text-muted">
            {entries.length ? 'No matching activity.' : 'No activity recorded yet.'}
          </p>
        </div>
      ) : (
        <ul className="max-h-[28rem] divide-y divide-line/60 overflow-y-auto">
          <AnimatePresence initial={false}>
            {filtered.map((e) => {
              const meta = META[e.event] ?? { label: e.event, tone: 'muted' as Tone, icon: History }
              const Icon = meta.icon
              const summary = summarizeDetail(e.detail)
              const actor = actorOf(e)
              return (
                <motion.li
                  key={e.id}
                  initial={{ opacity: 0 }}
                  animate={{ opacity: 1 }}
                  transition={{ duration: 0.18 }}
                  className="flex items-center gap-3 px-5 py-2.5"
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
                      {actor && (
                        <span className="shrink-0 rounded bg-surface-2 px-1.5 py-px text-[10px] font-medium text-muted ring-1 ring-line/70">
                          {actor}
                        </span>
                      )}
                    </div>
                    <div className="mt-0.5 truncate font-mono text-[10.5px] text-faint">
                      {[summary, e.ip].filter(Boolean).join(' · ') || '—'}
                    </div>
                  </div>
                  <span className="shrink-0 text-[11px] text-muted tnum">{fmtRel(e.ts)}</span>
                </motion.li>
              )
            })}
          </AnimatePresence>
        </ul>
      )}
    </Panel>
  )
}
