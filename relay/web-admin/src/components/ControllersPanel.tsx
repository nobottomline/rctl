import { useEffect, useMemo, useState } from 'react'
import { AnimatePresence, motion } from 'framer-motion'
import {
  Ban,
  Check,
  Copy,
  KeyRound,
  MoreHorizontal,
  Pencil,
  Plus,
  QrCode,
  ShieldCheck,
  Smartphone,
} from 'lucide-react'
import { QRCodeSVG } from 'qrcode.react'
import { toast } from 'sonner'
import { api, ApiError } from '../lib/api'
import { cn } from '../lib/cn'
import { fmtRel, fmtUntil, shortId } from '../lib/format'
import type { Controller, ControllerPairing, ControllerScope } from '../types'
import { Panel } from './Shell'
import { Button } from './ui/Button'
import { Field } from './ui/Field'
import { Menu, MenuItem, MenuSeparator } from './ui/Menu'
import { Modal } from './ui/Modal'

const SCOPE_OPTIONS: Array<{ id: ControllerScope; label: string; elevated?: boolean }> = [
  { id: 'screen.view', label: 'View screen' },
  { id: 'device.control', label: 'Control device' },
  { id: 'audio.listen', label: 'Listen to audio' },
  { id: 'microphone.talk', label: 'Use Talk' },
  { id: 'camera', label: 'Use cameras' },
  { id: 'files.read', label: 'Read files' },
  { id: 'files.write', label: 'Change files' },
  { id: 'terminal', label: 'Open terminal', elevated: true },
  { id: 'device.update', label: 'Update device', elevated: true },
  { id: 'system.destructive', label: 'Destructive actions', elevated: true },
]

const EVERYDAY_SCOPES = SCOPE_OPTIONS.filter((scope) => !scope.elevated).map((scope) => scope.id)
const OWNER_SCOPES = SCOPE_OPTIONS.map((scope) => scope.id)

type AccessPreset = 'everyday' | 'owner' | 'custom'

export function ControllersPanel({ controllers, onChanged }: { controllers: Controller[]; onChanged: () => void }) {
  const [pairOpen, setPairOpen] = useState(false)
  const [name, setName] = useState('My phone')
  const [ttl, setTTL] = useState(300)
  const [preset, setPreset] = useState<AccessPreset>('everyday')
  const [scopes, setScopes] = useState<ControllerScope[]>(EVERYDAY_SCOPES)
  const [pairing, setPairing] = useState<ControllerPairing | null>(null)
  const [creating, setCreating] = useState(false)
  const [closingPairing, setClosingPairing] = useState(false)
  const [copied, setCopied] = useState(false)
  const [now, setNow] = useState(() => Date.now())
  const [rename, setRename] = useState<Controller | null>(null)
  const [renameValue, setRenameValue] = useState('')
  const [renaming, setRenaming] = useState(false)
  const [revoke, setRevoke] = useState<Controller | null>(null)
  const [revoking, setRevoking] = useState(false)

  const activeCount = controllers.filter((controller) => controller.status === 'active').length
  const pairingJSON = useMemo(() => (pairing ? JSON.stringify(pairing) : ''), [pairing])
  const expired = !!pairing && pairing.expires_at * 1000 <= now

  useEffect(() => {
    if (!pairing) return
    const timer = window.setInterval(() => setNow(Date.now()), 1000)
    return () => window.clearInterval(timer)
  }, [pairing])

  function openPairing() {
    setName('My phone')
    setTTL(300)
    setPreset('everyday')
    setScopes(EVERYDAY_SCOPES)
    setPairing(null)
    setCopied(false)
    setNow(Date.now())
    setPairOpen(true)
  }

  function selectPreset(next: AccessPreset) {
    setPreset(next)
    if (next === 'everyday') setScopes(EVERYDAY_SCOPES)
    if (next === 'owner') setScopes(OWNER_SCOPES)
  }

  function toggleScope(scope: ControllerScope) {
    setPreset('custom')
    setScopes((current) =>
      current.includes(scope) ? current.filter((candidate) => candidate !== scope) : [...current, scope],
    )
  }

  async function createPairing() {
    if (scopes.length === 0) {
      toast.error('Select at least one permission')
      return
    }
    setCreating(true)
    try {
      const result = await api.createControllerPairing({ name: name.trim() || 'My phone', scopes, ttl_seconds: ttl })
      setPairing(result.pairing)
      setNow(Date.now())
    } catch (error) {
      toast.error(error instanceof Error ? error.message : 'Could not create pairing')
    } finally {
      setCreating(false)
    }
  }

  async function closePairing() {
    if (closingPairing) return
    const activePairing = pairing
    setClosingPairing(true)
    try {
      if (activePairing && activePairing.expires_at * 1000 > Date.now()) {
        try {
          await api.revokeControllerPairing(activePairing.pairing_id)
        } catch (error) {
          // A 404 means the one-time pairing was already claimed or expired.
          if (!(error instanceof ApiError && error.status === 404)) throw error
        }
      }
      setPairOpen(false)
      setPairing(null)
      onChanged()
    } catch (error) {
      toast.error(error instanceof Error ? error.message : 'Could not close pairing')
    } finally {
      setClosingPairing(false)
    }
  }

  async function copyPairing() {
    if (!pairingJSON) return
    try {
      await navigator.clipboard.writeText(pairingJSON)
      setCopied(true)
      toast.success('Pairing data copied')
      window.setTimeout(() => setCopied(false), 1800)
    } catch {
      toast.error('Clipboard access was denied')
    }
  }

  function openRename(controller: Controller) {
    setRename(controller)
    setRenameValue(controller.name)
  }

  async function saveRename() {
    if (!rename || !renameValue.trim()) return
    setRenaming(true)
    try {
      await api.renameController(rename.id, renameValue.trim())
      toast.success('Controller renamed')
      setRename(null)
      onChanged()
    } catch (error) {
      toast.error(error instanceof Error ? error.message : 'Could not rename controller')
    } finally {
      setRenaming(false)
    }
  }

  async function confirmRevoke() {
    if (!revoke) return
    setRevoking(true)
    try {
      await api.revokeController(revoke.id)
      toast.success(`${revoke.name} access revoked`)
      setRevoke(null)
      onChanged()
    } catch (error) {
      toast.error(error instanceof Error ? error.message : 'Could not revoke controller')
    } finally {
      setRevoking(false)
    }
  }

  return (
    <>
      <Panel
        title="Controllers"
        subtitle={`${activeCount} active controller${activeCount === 1 ? '' : 's'}`}
        action={
          <Button variant="primary" size="sm" onClick={openPairing}>
            <Plus className="size-4" />
            Pair controller
          </Button>
        }
      >
        {controllers.length === 0 ? (
          <div className="px-5 py-10 text-center">
            <div className="mx-auto grid size-10 place-items-center rounded-xl bg-surface-2 text-faint ring-1 ring-line">
              <Smartphone className="size-5" />
            </div>
            <p className="mt-3 text-[13px] text-muted">No native controllers paired.</p>
          </div>
        ) : (
          <ul className="divide-y divide-line/60">
            <AnimatePresence initial={false}>
              {controllers.map((controller) => (
                <motion.li
                  key={controller.id}
                  initial={{ opacity: 0 }}
                  animate={{ opacity: 1 }}
                  exit={{ opacity: 0, height: 0 }}
                  className="flex items-center gap-3 overflow-hidden px-5 py-3"
                >
                  <div className="grid size-8 shrink-0 place-items-center rounded-lg bg-surface-2 text-muted ring-1 ring-line">
                    <Smartphone className="size-4" />
                  </div>
                  <div className="min-w-0 flex-1">
                    <div className="flex items-center gap-2">
                      <span className="truncate text-[13px] font-medium text-fg">{controller.name}</span>
                      <span
                        className={cn(
                          'shrink-0 rounded-full px-1.5 py-0.5 text-[9.5px] font-medium uppercase ring-1',
                          controller.status === 'active'
                            ? 'bg-online/8 text-online ring-online/25'
                            : 'bg-danger/8 text-danger ring-danger/25',
                        )}
                      >
                        {controller.status}
                      </span>
                    </div>
                    <div className="mt-0.5 truncate font-mono text-[10.5px] text-faint">
                      {controller.platform.toUpperCase()} · {controller.scopes.length} permissions ·{' '}
                      {controller.status === 'active' ? `seen ${fmtRel(controller.last_seen_at)}` : `revoked ${fmtRel(controller.revoked_at)}`}
                    </div>
                  </div>
                  {controller.status === 'active' && (
                    <Menu
                      trigger={
                        <Button variant="ghost" size="icon" className="size-7" aria-label="Controller actions">
                          <MoreHorizontal className="size-4" />
                        </Button>
                      }
                    >
                      <MenuItem icon={Pencil} onSelect={() => openRename(controller)}>
                        Rename
                      </MenuItem>
                      <MenuSeparator />
                      <MenuItem icon={Ban} danger onSelect={() => setRevoke(controller)}>
                        Revoke access
                      </MenuItem>
                    </Menu>
                  )}
                </motion.li>
              ))}
            </AnimatePresence>
          </ul>
        )}
      </Panel>

      <Modal
        open={pairOpen}
        onOpenChange={(open) => {
          if (!open) void closePairing()
        }}
        title={pairing ? 'Scan to pair' : 'Pair a controller'}
        description={pairing ? 'Open rctl Controller on the phone and scan this code.' : 'Create a short-lived, one-time pairing code.'}
        className="max-w-lg"
      >
        {!pairing ? (
          <div className="space-y-5">
            <Field label="Controller name" value={name} maxLength={80} autoFocus onChange={(event) => setName(event.target.value)} />

            <div>
              <span className="mb-2 block text-[13px] font-medium text-fg-dim">Access</span>
              <div className="grid grid-cols-3 gap-1 rounded-xl bg-surface-2 p-1 ring-1 ring-line">
                {(['everyday', 'owner', 'custom'] as const).map((option) => (
                  <button
                    key={option}
                    type="button"
                    aria-pressed={preset === option}
                    onClick={() => selectPreset(option)}
                    className={cn(
                      'h-9 rounded-lg text-[12.5px] font-medium capitalize text-muted transition-colors',
                      preset === option && 'bg-bg text-fg shadow-sm ring-1 ring-line-2',
                    )}
                  >
                    {option}
                  </button>
                ))}
              </div>
            </div>

            <div className="grid grid-cols-2 gap-2">
              {SCOPE_OPTIONS.map((scope) => {
                const selected = scopes.includes(scope.id)
                return (
                  <button
                    key={scope.id}
                    type="button"
                    aria-pressed={selected}
                    onClick={() => toggleScope(scope.id)}
                    className={cn(
                      'flex min-h-10 items-center gap-2 rounded-lg px-3 text-left text-[12px] ring-1 transition-colors',
                      selected ? 'bg-signal/10 text-fg ring-signal/30' : 'bg-surface-2 text-muted ring-line hover:text-fg-dim',
                    )}
                  >
                    <span className={cn('grid size-4 shrink-0 place-items-center rounded border', selected ? 'border-signal bg-signal text-on-signal' : 'border-line-2')}>
                      {selected && <Check className="size-3" />}
                    </span>
                    <span className="min-w-0 leading-tight">{scope.label}</span>
                  </button>
                )
              })}
            </div>

            <div>
              <span className="mb-2 block text-[13px] font-medium text-fg-dim">Code lifetime</span>
              <div className="grid grid-cols-3 gap-1 rounded-xl bg-surface-2 p-1 ring-1 ring-line">
                {[120, 300, 600].map((seconds) => (
                  <button
                    key={seconds}
                    type="button"
                    aria-pressed={ttl === seconds}
                    onClick={() => setTTL(seconds)}
                    className={cn(
                      'h-9 rounded-lg text-[12.5px] font-medium text-muted transition-colors',
                      ttl === seconds && 'bg-bg text-fg shadow-sm ring-1 ring-line-2',
                    )}
                  >
                    {seconds / 60} min
                  </button>
                ))}
              </div>
            </div>

            {preset === 'owner' && (
              <div className="flex gap-2.5 rounded-xl bg-signal/8 p-3 text-[12px] leading-relaxed text-fg-dim ring-1 ring-signal/20">
                <ShieldCheck className="mt-0.5 size-4 shrink-0 text-signal" />
                Owner access includes terminal, updates, and destructive system actions.
              </div>
            )}

            <div className="flex justify-end gap-2.5">
              <Button variant="secondary" onClick={() => setPairOpen(false)}>
                Cancel
              </Button>
              <Button variant="primary" loading={creating} onClick={createPairing}>
                {!creating && <QrCode className="size-4" />}
                Create code
              </Button>
            </div>
          </div>
        ) : (
          <div className="space-y-5">
            <div className={cn('mx-auto w-fit rounded-xl bg-white p-3', expired && 'opacity-35')}>
              <QRCodeSVG value={pairingJSON} size={232} level="M" marginSize={0} title="rctl controller pairing code" />
            </div>

            <div className="grid grid-cols-2 gap-2 rounded-xl bg-surface-2 p-3 ring-1 ring-line">
              <div>
                <span className="block text-[10px] uppercase text-faint">Relay</span>
                <span className="mt-0.5 block truncate font-mono text-[11px] text-fg-dim">{pairing.origin}</span>
              </div>
              <div>
                <span className="block text-[10px] uppercase text-faint">Expires</span>
                <span className={cn('mt-0.5 block font-mono text-[11px]', expired ? 'text-danger' : 'text-fg-dim')}>
                  {fmtUntil(pairing.expires_at)}
                </span>
              </div>
              <div>
                <span className="block text-[10px] uppercase text-faint">Relay identity</span>
                <span className="mt-0.5 block font-mono text-[11px] text-fg-dim">{shortId(pairing.relay_id, 10, 5)}</span>
              </div>
              <div>
                <span className="block text-[10px] uppercase text-faint">Protocol</span>
                <span className="mt-0.5 block font-mono text-[11px] text-fg-dim">v{pairing.protocol_major}</span>
              </div>
            </div>

            {expired && <p className="text-center text-[12px] text-danger">This pairing code has expired.</p>}

            <div className="flex justify-end gap-2.5">
              <Button variant="secondary" onClick={copyPairing} disabled={expired}>
                {copied ? <Check className="size-4 text-online" /> : <Copy className="size-4" />}
                Copy code
              </Button>
              <Button variant="primary" loading={closingPairing} onClick={closePairing}>
                {!closingPairing && <KeyRound className="size-4" />}
                Done
              </Button>
            </div>
          </div>
        )}
      </Modal>

      <Modal open={!!rename} onOpenChange={(open) => !open && !renaming && setRename(null)} title="Rename controller">
        <div className="space-y-5">
          <Field value={renameValue} maxLength={80} autoFocus onChange={(event) => setRenameValue(event.target.value)} onKeyDown={(event) => event.key === 'Enter' && void saveRename()} />
          <div className="flex justify-end gap-2.5">
            <Button variant="secondary" disabled={renaming} onClick={() => setRename(null)}>
              Cancel
            </Button>
            <Button variant="primary" loading={renaming} disabled={!renameValue.trim()} onClick={saveRename}>
              {!renaming && <Pencil className="size-4" />}
              Rename
            </Button>
          </div>
        </div>
      </Modal>

      <Modal
        open={!!revoke}
        onOpenChange={(open) => !open && !revoking && setRevoke(null)}
        title="Revoke controller access?"
        description={revoke ? `“${revoke.name}” will be signed out immediately and must be paired again to regain access.` : undefined}
      >
        <div className="flex justify-end gap-2.5">
          <Button variant="secondary" disabled={revoking} onClick={() => setRevoke(null)}>
            Cancel
          </Button>
          <Button variant="danger-solid" loading={revoking} onClick={confirmRevoke}>
            {!revoking && <Ban className="size-4" />}
            Revoke access
          </Button>
        </div>
      </Modal>
    </>
  )
}
