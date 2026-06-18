import type { ComponentType } from 'react'
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
  ShieldCheck,
  Trash2,
  type LucideProps,
} from 'lucide-react'
import { Panel } from './Shell'
import { fmtRel, shortId } from '../lib/format'
import { cn } from '../lib/cn'
import type { AuditEntry } from '../types'

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

const toneText: Record<Tone, string> = {
  online: 'text-online',
  danger: 'text-danger',
  signal: 'text-signal',
  muted: 'text-muted',
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

export function ActivityPanel({ entries }: { entries: AuditEntry[] }) {
  return (
    <Panel title="Activity" subtitle={`${entries.length} recent event${entries.length === 1 ? '' : 's'}`}>
      {entries.length === 0 ? (
        <div className="px-5 py-10 text-center">
          <div className="mx-auto grid size-10 place-items-center rounded-xl bg-surface-2 text-faint ring-1 ring-line">
            <History className="size-5" />
          </div>
          <p className="mt-3 text-[13px] text-muted">No activity recorded yet.</p>
        </div>
      ) : (
        <ul className="max-h-[28rem] divide-y divide-line/60 overflow-y-auto">
          <AnimatePresence initial={false}>
            {entries.map((e) => {
              const meta = META[e.event] ?? {
                label: e.event,
                tone: 'muted' as Tone,
                icon: History,
              }
              const Icon = meta.icon
              const summary = summarizeDetail(e.detail)
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
                    <div className="truncate text-[13px] font-medium text-fg-dim">{meta.label}</div>
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
