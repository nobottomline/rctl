import { useState } from 'react'
import { AnimatePresence, motion } from 'framer-motion'
import {
  Ban,
  Check,
  ChevronDown,
  Clock,
  Copy,
  KeyRound,
  Plus,
  ShieldAlert,
  Ticket,
} from 'lucide-react'
import { toast } from 'sonner'
import { Button } from './ui/Button'
import { Field } from './ui/Field'
import { Menu, MenuItem } from './ui/Menu'
import { Panel } from './Shell'
import { api } from '../lib/api'
import { fmtAbs, fmtRel, rfc3339ToSec, shortId } from '../lib/format'
import { cn } from '../lib/cn'
import type { Enrollment, EnrollmentStatus, EnrollmentSummary } from '../types'

const TTLS = [
  { label: '30 minutes', value: 1800 },
  { label: '1 hour', value: 3600 },
  { label: '6 hours', value: 21600 },
  { label: '1 day', value: 86400 },
  { label: '7 days', value: 604800 },
  { label: '30 days', value: 2592000 },
]

const statusStyle: Record<EnrollmentStatus, string> = {
  active: 'text-online ring-online/25 bg-online/8',
  used: 'text-muted ring-line bg-surface-2',
  expired: 'text-faint ring-line bg-surface-2',
  revoked: 'text-danger ring-danger/25 bg-danger/8',
}

export type EnrollPanelProps = {
  enrollments: EnrollmentSummary[]
  onChanged: () => void
}

export function EnrollPanel({ enrollments, onChanged }: EnrollPanelProps) {
  const [label, setLabel] = useState('')
  const [ttl, setTtl] = useState(TTLS[0])
  const [creating, setCreating] = useState(false)
  const [created, setCreated] = useState<Enrollment | null>(null)
  const [copied, setCopied] = useState(false)
  const [revoking, setRevoking] = useState('')

  const active = enrollments.filter((e) => e.status === 'active').length

  async function create() {
    setCreating(true)
    try {
      const r = await api.createEnrollment({
        label: label.trim() || undefined,
        ttl_seconds: ttl.value,
      })
      setCreated(r)
      setCopied(false)
      setLabel('')
      onChanged()
    } catch (err) {
      toast.error(err instanceof Error ? err.message : 'Could not create token')
    } finally {
      setCreating(false)
    }
  }

  function copy() {
    if (!created) return
    const env = `RELAY_URL=${created.relay_url}\nENROLL_TOKEN=${created.token}`
    navigator.clipboard?.writeText(env).then(() => {
      setCopied(true)
      toast.success('Enrollment config copied')
      setTimeout(() => setCopied(false), 1800)
    })
  }

  async function revoke(id: string) {
    setRevoking(id)
    try {
      await api.revokeEnrollment(id)
      toast.success('Token revoked')
      onChanged()
    } catch (err) {
      toast.error(err instanceof Error ? err.message : 'Revoke failed')
    } finally {
      setRevoking('')
    }
  }

  return (
    <Panel title="Enrollment" subtitle={`${active} active token${active === 1 ? '' : 's'}`}>
      <div className="space-y-4 p-5">
        {/* create */}
        <div className="space-y-2.5">
          <Field
            placeholder="Label (optional) — e.g. John's iPad"
            value={label}
            onChange={(e) => setLabel(e.target.value)}
            maxLength={80}
          />
          <div className="flex gap-2">
            <Menu
              align="start"
              trigger={
                <Button variant="secondary" size="md" className="min-w-0 flex-1 justify-between">
                  <span className="flex items-center gap-2 truncate">
                    <Clock className="size-4 shrink-0 text-muted" />
                    {ttl.label}
                  </span>
                  <ChevronDown className="size-4 shrink-0 text-muted" />
                </Button>
              }
            >
              {TTLS.map((o) => (
                <MenuItem key={o.value} icon={Clock} onSelect={() => setTtl(o)}>
                  {o.label}
                </MenuItem>
              ))}
            </Menu>
            <Button variant="primary" size="md" onClick={create} loading={creating}>
              {!creating && <Plus className="size-4" />}
              Create
            </Button>
          </div>
        </div>

        {/* freshly created token reveal */}
        <AnimatePresence mode="wait">
          {created && (
            <motion.div
              key={created.token}
              initial={{ opacity: 0, height: 0 }}
              animate={{ opacity: 1, height: 'auto' }}
              exit={{ opacity: 0, height: 0 }}
              transition={{ duration: 0.3, ease: [0.16, 1, 0.3, 1] }}
              className="overflow-hidden"
            >
              <div className="overflow-hidden rounded-xl bg-bg/70 ring-1 ring-signal/30">
                <div className="flex items-center justify-between border-b border-line/80 px-3 py-2">
                  <span className="flex items-center gap-1.5 text-[11px] font-medium uppercase tracking-wider text-faint">
                    <KeyRound className="size-3.5" /> relay.env
                  </span>
                  <Button variant="ghost" size="sm" onClick={copy}>
                    {copied ? (
                      <Check className="size-3.5 text-online" />
                    ) : (
                      <Copy className="size-3.5" />
                    )}
                    {copied ? 'Copied' : 'Copy'}
                  </Button>
                </div>
                <pre className="overflow-x-auto px-3.5 py-3 font-mono text-[11.5px] leading-relaxed text-fg-dim">
                  <span className="text-faint">RELAY_URL=</span>
                  {created.relay_url}
                  {'\n'}
                  <span className="text-faint">ENROLL_TOKEN=</span>
                  <span className="text-signal">{created.token}</span>
                </pre>
              </div>
              <div className="mt-2.5 flex items-start gap-2 text-[12px] leading-relaxed text-muted">
                <ShieldAlert className="mt-0.5 size-3.5 shrink-0 text-signal/80" />
                <span>
                  Shown once. Keep it private — it embeds in the package. Expires{' '}
                  <span className="text-fg-dim">{fmtAbs(rfc3339ToSec(created.expires_at))}</span>.
                </span>
              </div>
            </motion.div>
          )}
        </AnimatePresence>

        {/* token list */}
        {enrollments.length > 0 && (
          <div className="-mx-5 border-t border-line/70">
            <ul className="divide-y divide-line/60">
              <AnimatePresence initial={false}>
                {enrollments.map((e) => (
                  <motion.li
                    key={e.id}
                    layout
                    initial={{ opacity: 0 }}
                    animate={{ opacity: 1 }}
                    exit={{ opacity: 0, height: 0 }}
                    transition={{ duration: 0.2 }}
                    className="flex items-center gap-3 px-5 py-2.5"
                  >
                    <div className="grid size-7 shrink-0 place-items-center rounded-lg bg-surface-2 text-muted ring-1 ring-line">
                      <Ticket className="size-3.5" />
                    </div>
                    <div className="min-w-0 flex-1">
                      <div className="flex items-center gap-2">
                        <span className="truncate text-[13px] font-medium text-fg">
                          {e.label || 'Untitled token'}
                        </span>
                        <span
                          className={cn(
                            'shrink-0 rounded-full px-1.5 py-0.5 text-[9.5px] font-medium uppercase tracking-wide ring-1',
                            statusStyle[e.status],
                          )}
                        >
                          {e.status}
                        </span>
                      </div>
                      <div className="mt-0.5 font-mono text-[10.5px] text-faint">
                        {shortId(e.id, 12, 0)} ·{' '}
                        {e.status === 'active' ? `expires ${fmtRel(e.expires_at)}` : fmtRel(e.created_at)}
                      </div>
                    </div>
                    {e.status === 'active' && (
                      <Button
                        variant="ghost"
                        size="icon"
                        loading={revoking === e.id}
                        onClick={() => revoke(e.id)}
                        aria-label="Revoke token"
                        className="size-7 text-muted hover:text-danger"
                      >
                        {revoking !== e.id && <Ban className="size-3.5" />}
                      </Button>
                    )}
                  </motion.li>
                ))}
              </AnimatePresence>
            </ul>
          </div>
        )}
      </div>
    </Panel>
  )
}
