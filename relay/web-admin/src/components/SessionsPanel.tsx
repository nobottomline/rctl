import { AnimatePresence, motion } from 'framer-motion'
import { LogOut, Monitor } from 'lucide-react'
import { Button } from './ui/Button'
import { Panel } from './Shell'
import { describeUserAgent, fmtRel } from '../lib/format'
import type { Session } from '../types'

export type SessionsPanelProps = {
  sessions: Session[]
  busyId: string
  onRevoke: (id: string) => void
  onRevokeOthers: () => void
}

export function SessionsPanel({
  sessions,
  busyId,
  onRevoke,
  onRevokeOthers,
}: SessionsPanelProps) {
  const others = sessions.filter((s) => !s.current).length

  return (
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
              layout
              initial={{ opacity: 0, y: 6 }}
              animate={{ opacity: 1, y: 0 }}
              exit={{ opacity: 0, height: 0 }}
              transition={{ duration: 0.22 }}
              className="flex items-center gap-3 px-5 py-3.5"
            >
              <div className="grid size-8 shrink-0 place-items-center rounded-lg bg-surface-2 text-muted ring-1 ring-line">
                <Monitor className="size-4" />
              </div>
              <div className="min-w-0 flex-1">
                <div className="flex items-center gap-2">
                  <span className="truncate text-[13.5px] font-medium text-fg">
                    {describeUserAgent(s.user_agent)}
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
              </div>
              {!s.current && (
                <Button
                  variant="ghost"
                  size="icon"
                  loading={busyId === s.id}
                  onClick={() => onRevoke(s.id)}
                  aria-label="Revoke session"
                  className="text-muted hover:text-danger"
                >
                  {busyId !== s.id && <LogOut className="size-4" />}
                </Button>
              )}
            </motion.li>
          ))}
        </AnimatePresence>
      </ul>
    </Panel>
  )
}
