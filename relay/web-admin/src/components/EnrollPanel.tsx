import { useState } from 'react'
import { AnimatePresence, motion } from 'framer-motion'
import {
  Ban,
  Check,
  ChevronDown,
  Copy,
  Download,
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
  packageAvailable: boolean
  packageVersion?: string
  onChanged: () => void
}

export function EnrollPanel({ enrollments, packageAvailable, packageVersion, onChanged }: EnrollPanelProps) {
  const [open, setOpen] = useState(false)
  const [label, setLabel] = useState('')
  const [ttl, setTtl] = useState(TTLS[0])
  const [creating, setCreating] = useState(false)
  const [packaging, setPackaging] = useState(false)
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

  async function downloadPackage() {
    setPackaging(true)
    try {
      const filename = await api.createDevicePackage({
        device_name: label.trim() || 'iPad',
        label: label.trim() || undefined,
        ttl_seconds: ttl.value,
      })
      toast.success(`${filename} downloaded`)
      setOpen(false)
      onChanged()
    } catch (err) {
      toast.error(err instanceof Error ? err.message : 'Could not create device package')
    } finally {
      setPackaging(false)
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
          Pair device
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
                initial={{ opacity: 0 }}
                animate={{ opacity: 1 }}
                exit={{ opacity: 0, height: 0 }}
                transition={{ duration: 0.2, ease: 'easeOut' }}
                className="flex items-center gap-3 overflow-hidden px-5 py-3"
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
        title={created ? 'Token created' : 'Pair a device'}
        description={
          created
            ? undefined
            : packageAvailable
              ? `Download a private rctl${packageVersion ? ` ${packageVersion}` : ''} package configured for this relay.`
              : 'Create a one-time token for the manual package workflow.'
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
                label="Device name"
                placeholder="iPad Air"
                value={label}
                autoFocus
                maxLength={80}
                onChange={(e) => setLabel(e.target.value)}
              />
              <div>
                <span className="mb-2 block text-[13px] font-medium text-fg-dim">Expires after</span>
                <Menu
                  align="start"
                  trigger={
                    <button
                      type="button"
                      className="group flex w-full items-center justify-between rounded-xl bg-surface-2 px-3.5 py-2.5 text-[14px] text-fg ring-1 ring-line transition-colors hover:ring-line-2 focus:outline-none focus-visible:outline-none data-[state=open]:ring-signal/60"
                    >
                      {ttl.label}
                      <ChevronDown className="size-4 text-muted transition-transform group-data-[state=open]:rotate-180" />
                    </button>
                  }
                >
                  {TTLS.map((o) => (
                    <MenuItem
                      key={o.value}
                      icon={ttl.value === o.value ? Check : undefined}
                      onSelect={() => setTtl(o)}
                    >
                      {o.label}
                    </MenuItem>
                  ))}
                </Menu>
              </div>
              <div className="grid grid-cols-2 gap-2.5 pt-1 sm:flex sm:justify-end">
                <Button variant="secondary" className="w-full sm:w-auto" onClick={() => setOpen(false)}>
                  Cancel
                </Button>
                {packageAvailable && (
                  <Button variant="secondary" className="w-full sm:w-auto" onClick={create} loading={creating} disabled={packaging}>
                    {!creating && <KeyRound className="size-4" />}
                    Token only
                  </Button>
                )}
                <Button
                  variant="primary"
                  onClick={packageAvailable ? downloadPackage : create}
                  loading={packageAvailable ? packaging : creating}
                  disabled={packageAvailable ? creating : packaging}
                  className={cn(packageAvailable && 'col-span-2 w-full sm:w-auto')}
                >
                  {packageAvailable ? (
                    !packaging && <Download className="size-4" />
                  ) : (
                    !creating && <Plus className="size-4" />
                  )}
                  {packageAvailable ? 'Download package' : 'Create token'}
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
