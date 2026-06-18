import { useState } from 'react'
import { AnimatePresence, motion } from 'framer-motion'
import {
  Ban,
  Check,
  Copy,
  KeyRound,
  MoreHorizontal,
  Plus,
  ShieldAlert,
  Ticket,
  Trash2,
} from 'lucide-react'
import { toast } from 'sonner'
import { Button } from './ui/Button'
import { Field } from './ui/Field'
import { Menu, MenuItem, MenuSeparator } from './ui/Menu'
import { Modal } from './ui/Modal'
import { Panel } from './Shell'
import { api } from '../lib/api'
import { fmtAbs, fmtRel, rfc3339ToSec, shortId } from '../lib/format'
import { cn } from '../lib/cn'
import type { Enrollment, EnrollmentStatus, EnrollmentSummary } from '../types'

const TTLS = [
  { label: '30 min', value: 1800 },
  { label: '1 hour', value: 3600 },
  { label: '6 hours', value: 21600 },
  { label: '1 day', value: 86400 },
  { label: '7 days', value: 604800 },
  { label: '30 days', value: 2592000 },
  { label: 'Never', value: -1 },
]

const NEVER_THRESHOLD = 4_000_000_000 // ~year 2096

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
  const [open, setOpen] = useState(false)
  const [label, setLabel] = useState('')
  const [ttl, setTtl] = useState(TTLS[0])
  const [creating, setCreating] = useState(false)
  const [created, setCreated] = useState<Enrollment | null>(null)
  const [copied, setCopied] = useState(false)
  const [busy, setBusy] = useState('')

  const active = enrollments.filter((e) => e.status === 'active').length

  function openModal() {
    setCreated(null)
    setLabel('')
    setTtl(TTLS[0])
    setCopied(false)
    setOpen(true)
  }

  async function create() {
    setCreating(true)
    try {
      const r = await api.createEnrollment({
        label: label.trim() || undefined,
        ttl_seconds: ttl.value,
      })
      setCreated(r)
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

  async function act(id: string, kind: 'revoke' | 'delete') {
    setBusy(id)
    try {
      if (kind === 'revoke') await api.revokeEnrollment(id)
      else await api.deleteEnrollment(id)
      toast.success(kind === 'revoke' ? 'Token revoked' : 'Token deleted')
      onChanged()
    } catch (err) {
      toast.error(err instanceof Error ? err.message : `${kind} failed`)
    } finally {
      setBusy('')
    }
  }

  function expiryText(e: EnrollmentSummary): string {
    if (e.status !== 'active') return fmtRel(e.created_at)
    return e.expires_at >= NEVER_THRESHOLD ? 'never expires' : `expires ${fmtRel(e.expires_at)}`
  }

  return (
    <Panel
      title="Enrollment"
      subtitle={`${active} active token${active === 1 ? '' : 's'}`}
      action={
        <Button variant="primary" size="sm" onClick={openModal}>
          <Plus className="size-4" />
          New token
        </Button>
      }
    >
      {enrollments.length === 0 ? (
        <div className="px-5 py-10 text-center">
          <div className="mx-auto grid size-10 place-items-center rounded-xl bg-surface-2 text-faint ring-1 ring-line">
            <Ticket className="size-5" />
          </div>
          <p className="mt-3 text-[13px] text-muted">No tokens yet. Create one to pair a device.</p>
        </div>
      ) : (
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
                className="flex items-center gap-3 px-5 py-3"
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
                    {shortId(e.id, 12, 0)} · {expiryText(e)}
                  </div>
                </div>
                <Menu
                  trigger={
                    <Button
                      variant="ghost"
                      size="icon"
                      className="size-7"
                      loading={busy === e.id}
                      aria-label="Token actions"
                    >
                      {busy !== e.id && <MoreHorizontal className="size-4" />}
                    </Button>
                  }
                >
                  {e.status === 'active' && (
                    <>
                      <MenuItem icon={Ban} onSelect={() => act(e.id, 'revoke')}>
                        Revoke token
                      </MenuItem>
                      <MenuSeparator />
                    </>
                  )}
                  <MenuItem icon={Trash2} danger onSelect={() => act(e.id, 'delete')}>
                    Delete from history
                  </MenuItem>
                </Menu>
              </motion.li>
            ))}
          </AnimatePresence>
        </ul>
      )}

      <Modal
        open={open}
        onOpenChange={setOpen}
        title={created ? 'Token created' : 'New enrollment token'}
        description={
          created
            ? undefined
            : 'A one-time token to pair a device. Drop it into make-device-deb to build a personalized package.'
        }
        className="max-w-lg"
      >
        <AnimatePresence mode="wait">
          {!created ? (
            <motion.div
              key="form"
              initial={{ opacity: 0 }}
              animate={{ opacity: 1 }}
              exit={{ opacity: 0 }}
              className="space-y-5"
            >
              <Field
                label="Label"
                placeholder="Optional — e.g. John's iPad"
                value={label}
                autoFocus
                maxLength={80}
                onChange={(e) => setLabel(e.target.value)}
              />
              <div>
                <span className="mb-2 block text-[13px] font-medium text-fg-dim">Expires after</span>
                <div className="flex flex-wrap gap-1.5">
                  {TTLS.map((o) => (
                    <button
                      key={o.value}
                      type="button"
                      onClick={() => setTtl(o)}
                      className={cn(
                        'rounded-lg px-2.5 py-1.5 text-[12.5px] font-medium ring-1 transition-colors',
                        ttl.value === o.value
                          ? 'bg-signal text-on-signal ring-signal'
                          : 'bg-surface-2 text-fg-dim ring-line hover:text-fg hover:ring-line-2',
                      )}
                    >
                      {o.label}
                    </button>
                  ))}
                </div>
              </div>
              <div className="flex justify-end gap-2.5 pt-1">
                <Button variant="secondary" onClick={() => setOpen(false)}>
                  Cancel
                </Button>
                <Button variant="primary" onClick={create} loading={creating}>
                  {!creating && <Plus className="size-4" />}
                  Create token
                </Button>
              </div>
            </motion.div>
          ) : (
            <motion.div
              key="reveal"
              initial={{ opacity: 0, y: 6 }}
              animate={{ opacity: 1, y: 0 }}
              className="space-y-4"
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
              <div className="flex items-start gap-2 text-[12px] leading-relaxed text-muted">
                <ShieldAlert className="mt-0.5 size-3.5 shrink-0 text-signal/80" />
                <span>
                  Shown once — copy it now. It embeds in the package; keep it private. Expires{' '}
                  <span className="text-fg-dim">
                    {rfc3339ToSec(created.expires_at) >= NEVER_THRESHOLD
                      ? 'never'
                      : fmtAbs(rfc3339ToSec(created.expires_at))}
                  </span>
                  .
                </span>
              </div>
              <div className="flex justify-end pt-1">
                <Button variant="primary" onClick={() => setOpen(false)}>
                  Done
                </Button>
              </div>
            </motion.div>
          )}
        </AnimatePresence>
      </Modal>
    </Panel>
  )
}
