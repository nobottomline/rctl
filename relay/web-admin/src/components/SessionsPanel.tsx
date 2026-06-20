import { useState } from 'react'
import { AnimatePresence, motion } from 'framer-motion'
import { Activity, Globe, Info, LogOut, Monitor, MoreHorizontal } from 'lucide-react'
import { Button } from './ui/Button'
import { Menu, MenuItem, MenuSeparator } from './ui/Menu'
import { Modal } from './ui/Modal'
import { DetailField, DetailSection } from './ui/Detail'
import { Panel } from './Shell'
import { auditLabel } from './ActivityPanel'
import { describeClient, fmtAbs, fmtRel, fmtUntil } from '../lib/format'
import type { AuditEntry, Session } from '../types'

export type SessionsPanelProps = {
  sessions: Session[]
  busyId: string
  audit?: AuditEntry[]
  onRevoke: (id: string) => void
  onRevokeOthers: () => void
}

export function SessionsPanel({
  sessions,
  busyId,
  audit,
  onRevoke,
  onRevokeOthers,
}: SessionsPanelProps) {
  const [detail, setDetail] = useState<Session | null>(null)
  const others = sessions.filter((s) => !s.current).length
  const detailLive = detail ? sessions.find((s) => s.id === detail.id) ?? detail : null

  return (
    <>
      <Panel
        title="Sessions"
        subtitle={`${sessions.length} active`}
        action={
          others > 0 ? (
            <Button variant="danger" size="sm" onClick={onRevokeOthers}>
              Revoke others
            </Button>
          ) : undefined
        }
      >
        <ul className="divide-y divide-line/70">
          <AnimatePresence initial={false}>
            {sessions.map((s) => (
              <motion.li
                key={s.id}
                initial={{ opacity: 0, y: 6 }}
                animate={{ opacity: 1, y: 0 }}
                exit={{ opacity: 0, height: 0 }}
                transition={{ duration: 0.22 }}
                className="group flex items-center gap-3 overflow-hidden px-5 py-3.5"
              >
                <div className="grid size-8 shrink-0 place-items-center rounded-lg bg-surface-2 text-muted ring-1 ring-line">
                  <Monitor className="size-4" />
                </div>
                <button
                  onClick={() => setDetail(s)}
                  className="min-w-0 flex-1 cursor-pointer text-left"
                  title="View details"
                >
                  <div className="flex items-center gap-2">
                    <span className="truncate text-[13.5px] font-medium text-fg">
                      {describeClient(s.user_agent, s.client_hints)}
                    </span>
                    {s.current && (
                      <span className="shrink-0 rounded-full bg-online/10 px-2 py-0.5 text-[10px] font-medium uppercase tracking-wide text-online ring-1 ring-online/25">
                        this device
                      </span>
                    )}
                  </div>
                  <div className="mt-0.5 flex items-center gap-1.5 text-[12px] text-muted">
                    <span className="font-mono text-fg-dim">{s.ip || 'unknown IP'}</span>
                    <span className="text-faint">·</span>
                    <span>seen {fmtRel(s.last_seen_at)}</span>
                  </div>
                </button>
                <Menu
                  trigger={
                    <Button
                      variant="ghost"
                      size="icon"
                      loading={busyId === s.id}
                      aria-label="Session actions"
                    >
                      {busyId !== s.id && <MoreHorizontal className="size-[18px]" />}
                    </Button>
                  }
                >
                  <MenuItem icon={Info} onSelect={() => setDetail(s)}>
                    View details
                  </MenuItem>
                  {!s.current && (
                    <>
                      <MenuSeparator />
                      <MenuItem icon={LogOut} danger onSelect={() => onRevoke(s.id)}>
                        Revoke session
                      </MenuItem>
                    </>
                  )}
                </Menu>
              </motion.li>
            ))}
          </AnimatePresence>
        </ul>
      </Panel>

      <SessionDetailModal
        session={detailLive}
        audit={audit}
        onOpenChange={(o) => !o && setDetail(null)}
        onRevoke={(id) => {
          setDetail(null)
          onRevoke(id)
        }}
      />
    </>
  )
}

function SessionDetailModal({
  session,
  audit = [],
  onOpenChange,
  onRevoke,
}: {
  session: Session | null
  audit?: AuditEntry[]
  onOpenChange: (open: boolean) => void
  onRevoke: (id: string) => void
}) {
  // Recent audit events performed by *this* session (each admin action records the
  // acting session id), so it's precise per-session, not just same-IP.
  const acts = session ? audit.filter((e) => e.session_id && e.session_id === session.id).slice(0, 8) : []
  return (
    <Modal open={!!session} onOpenChange={onOpenChange} title="Session" className="max-w-lg">
      {session && (
        <div className="space-y-5">
          <div className="flex items-center gap-3">
            <div className="grid size-10 shrink-0 place-items-center rounded-xl bg-surface-2 text-muted ring-1 ring-line">
              <Monitor className="size-5" />
            </div>
            <div className="min-w-0 flex-1">
              <div className="truncate text-[14.5px] font-medium text-fg">
                {describeClient(session.user_agent, session.client_hints)}
              </div>
              <div className="font-mono text-[12px] text-muted">{session.ip || 'unknown IP'}</div>
            </div>
            {session.current && (
              <span className="shrink-0 rounded-full bg-online/10 px-2 py-0.5 text-[10px] font-medium uppercase tracking-wide text-online ring-1 ring-online/25">
                this device
              </span>
            )}
          </div>

          <DetailSection title="Details">
            <div className="grid grid-cols-2 gap-x-4 gap-y-3">
              <DetailField icon={Globe} label="IP address" value={session.ip || 'unknown'} />
              <DetailField label="Signed in" value={fmtAbs(session.created_at)} />
              <DetailField label="Last seen" value={fmtRel(session.last_seen_at)} />
              <DetailField label="Auto sign-out" value={fmtUntil(session.expires_at)} />
            </div>
          </DetailSection>

          {acts.length > 0 && (
            <DetailSection title="Recent activity · this session">
              <ul className="space-y-1.5">
                {acts.map((e) => (
                  <li key={e.id} className="flex items-center gap-2 text-[12.5px]">
                    <Activity className="size-3.5 shrink-0 text-muted" />
                    <span className="truncate text-fg-dim">{auditLabel(e.event)}</span>
                    <span className="ml-auto shrink-0 text-muted tnum">{fmtRel(e.ts)}</span>
                  </li>
                ))}
              </ul>
            </DetailSection>
          )}

          <DetailSection title="User agent">
            <p className="break-all font-mono text-[11.5px] leading-relaxed text-fg-dim">
              {session.user_agent || 'unknown'}
            </p>
          </DetailSection>

          <div className="flex justify-end gap-2.5 pt-1">
            <Button variant="secondary" onClick={() => onOpenChange(false)}>
              Close
            </Button>
            {!session.current && (
              <Button variant="danger-solid" onClick={() => onRevoke(session.id)}>
                <LogOut className="size-4" />
                Revoke session
              </Button>
            )}
          </div>
        </div>
      )}
    </Modal>
  )
}
