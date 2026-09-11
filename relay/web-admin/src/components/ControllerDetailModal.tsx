import { useState } from 'react'
import {
  Activity,
  BatteryCharging,
  BatteryFull,
  BatteryLow,
  BatteryMedium,
  Ban,
  Check,
  Copy,
  Cpu,
  Fingerprint,
  Globe,
  HardDrive,
  Languages,
  MemoryStick,
  Pencil,
  Radio,
  ShieldCheck,
  Smartphone,
  Tablet,
  Thermometer,
  Trash2,
  Wifi,
  WifiOff,
} from 'lucide-react'
import { toast } from 'sonner'
import { Modal } from './ui/Modal'
import { Button } from './ui/Button'
import { DetailSection, DetailField } from './ui/Detail'
import { auditLabel } from './ActivityPanel'
import { concernsController } from '../lib/actors'
import { fmtAbs, fmtBytes, fmtRel, shortId } from '../lib/format'
import { scopeElevated, scopeLabel } from '../lib/scopes'
import { cn } from '../lib/cn'
import type { AuditEntry, Controller, ControllerTelemetry } from '../types'

export function ControllerDetailModal({
  controller,
  audit = [],
  onOpenChange,
  onRename,
  onRevoke,
  onDelete,
}: {
  controller: Controller | null
  audit?: AuditEntry[]
  onOpenChange: (open: boolean) => void
  onRename: (controller: Controller) => void
  onRevoke: (controller: Controller) => void
  onDelete: (controller: Controller) => void
}) {
  const [copied, setCopied] = useState('')

  function copy(key: string, value?: string) {
    if (!value) return
    navigator.clipboard?.writeText(value).then(
      () => {
        setCopied(key)
        window.setTimeout(() => setCopied(''), 1500)
      },
      () => toast.error('Copy failed'),
    )
  }

  const c = controller
  const client = c?.client
  const telemetry = c?.telemetry
  const acts = c ? audit.filter((e) => concernsController(e, c.id)).slice(0, 8) : []
  const isPad = client?.idiom === 'pad'
  const DeviceIcon = isPad ? Tablet : Smartphone
  const modelLine = client ? [client.model_name || client.model, systemLine(client.system_name, client.system_version)].filter(Boolean).join(' · ') : ''

  return (
    <Modal open={!!c} onOpenChange={onOpenChange} title="Controller" className="max-w-xl">
      {c && (
        <div className="space-y-5">
          <div className="flex items-center gap-3">
            <div className="grid size-11 shrink-0 place-items-center rounded-xl bg-surface-2 text-muted ring-1 ring-line">
              <DeviceIcon className="size-5" />
            </div>
            <div className="min-w-0 flex-1">
              <div className="flex flex-wrap items-center gap-2">
                <span className="truncate text-[15px] font-medium text-fg">{c.name}</span>
                <span
                  className={cn(
                    'shrink-0 rounded-full px-1.5 py-0.5 text-[9.5px] font-medium uppercase ring-1',
                    c.status === 'active' ? 'bg-online/8 text-online ring-online/25' : 'bg-danger/8 text-danger ring-danger/25',
                  )}
                >
                  {c.status === 'active' ? 'Authorized' : 'Revoked'}
                </span>
                {c.status === 'active' && <PresenceTag presence={c.presence} />}
              </div>
              <div className="mt-0.5 truncate text-[12px] text-muted">
                {modelLine || `${c.platform.toUpperCase()} · profile not reported yet`}
              </div>
            </div>
          </div>

          <DetailSection title="Access">
            <div className="grid grid-cols-2 gap-x-4 gap-y-3">
              <DetailField label="Paired" value={fmtAbs(c.created_at)} />
              <DetailField label="Last request" value={c.last_seen_at ? fmtRel(c.last_seen_at) : 'never'} />
              {c.status === 'active' ? (
                <>
                  <DetailField icon={Radio} label="Foreground heartbeat" value={c.heartbeat_at ? fmtRel(c.heartbeat_at) : 'not yet'} />
                  <DetailField label="Open control sessions" value={String(c.open_sessions ?? 0)} />
                </>
              ) : (
                <DetailField icon={Ban} label="Revoked" value={fmtAbs(c.revoked_at)} />
              )}
            </div>
            <div className="mt-3 flex flex-wrap gap-1.5">
              {c.scopes.map((scope) => (
                <span
                  key={scope}
                  className={cn(
                    'inline-flex items-center gap-1 rounded-md px-2 py-0.5 text-[11px] ring-1',
                    scopeElevated(scope) ? 'bg-signal/8 text-signal ring-signal/25' : 'bg-surface-2 text-fg-dim ring-line/70',
                  )}
                  title={scope}
                >
                  {scopeElevated(scope) && <ShieldCheck className="size-3" />}
                  {scopeLabel(scope)}
                </span>
              ))}
            </div>
          </DetailSection>

          {client && (
            <DetailSection
              title="Device"
              action={<span className="text-[10.5px] text-faint">reported {fmtRel(c.client_updated_at)}</span>}
            >
              <div className="grid grid-cols-2 gap-x-4 gap-y-3">
                <DetailField icon={DeviceIcon} label="Model" value={client.model_name || client.model} />
                <DetailField label="Identifier" value={client.model} />
                <DetailField label="System" value={systemLine(client.system_name, client.system_version, client.os_build)} />
                <DetailField label="App" value={appLine(client.app_version, client.app_build)} />
                <DetailField label="Device name" value={client.device_name} />
                <DetailField label="Screen" value={client.screen} />
                <DetailField icon={Languages} label="Locale" value={[client.locale, client.timezone].filter(Boolean).join(' · ')} />
                <DetailField icon={Cpu} label="CPU cores" value={client.cpu_count ? String(client.cpu_count) : undefined} />
                <DetailField icon={MemoryStick} label="Memory" value={client.memory_bytes ? fmtBytes(client.memory_bytes) : undefined} />
                <DetailField
                  icon={HardDrive}
                  label="Storage"
                  value={storageLine(client.disk_bytes, telemetry?.disk_free_bytes ?? client.disk_free_bytes)}
                />
              </div>
            </DetailSection>
          )}

          {telemetry && (
            <DetailSection
              title="Live"
              action={<span className="text-[10.5px] text-faint">updated {fmtRel(c.telemetry_updated_at)}</span>}
            >
              <div className="grid grid-cols-2 gap-x-4 gap-y-3">
                <DetailField icon={batteryIcon(telemetry)} label="Battery" value={batteryLine(telemetry)} />
                <DetailField label="Low power mode" value={telemetry.low_power === undefined ? undefined : telemetry.low_power === 'true' ? 'on' : 'off'} />
                <DetailField icon={telemetry.network === 'none' ? WifiOff : Wifi} label="Network" value={telemetry.network} />
                <DetailField icon={Thermometer} label="Thermal state" value={telemetry.thermal} />
              </div>
            </DetailSection>
          )}

          <DetailSection title="Network">
            <div className="grid grid-cols-2 gap-x-4 gap-y-3">
              <DetailField icon={Globe} label="Paired from" value={c.paired_ip || 'unknown'} />
              <DetailField icon={Globe} label="Last IP" value={c.last_ip || 'unknown'} />
            </div>
            {c.user_agent && (
              <p className="mt-3 break-all font-mono text-[11px] leading-relaxed text-fg-dim">{c.user_agent}</p>
            )}
          </DetailSection>

          <DetailSection title="Identity">
            <div className="space-y-2">
              <IdentityRow label="Controller ID" value={c.id} copied={copied === 'id'} onCopy={() => copy('id', c.id)} />
              <IdentityRow
                icon={Fingerprint}
                label="Key fingerprint"
                value={c.key_fingerprint ? `SHA-256 ${shortId(c.key_fingerprint, 12, 8)}` : '—'}
                copied={copied === 'key'}
                onCopy={() => copy('key', c.key_fingerprint)}
              />
            </div>
          </DetailSection>

          {acts.length > 0 && (
            <DetailSection title="Recent activity · this controller">
              <ul className="space-y-1.5">
                {acts.map((e) => (
                  <li key={e.id} className="flex items-center gap-2 text-[12.5px]">
                    <Activity className="size-3.5 shrink-0 text-muted" />
                    <span className="truncate text-fg-dim">{auditLabel(e.event)}</span>
                    {e.actor_kind === 'admin' && <span className="shrink-0 text-[10px] uppercase text-faint">by admin</span>}
                    <span className="ml-auto shrink-0 text-muted tnum">{fmtRel(e.ts)}</span>
                  </li>
                ))}
              </ul>
            </DetailSection>
          )}

          <div className="flex flex-wrap justify-end gap-2.5 pt-1">
            <Button variant="secondary" onClick={() => onOpenChange(false)}>
              Close
            </Button>
            {c.status === 'active' ? (
              <>
                <Button variant="secondary" onClick={() => onRename(c)}>
                  <Pencil className="size-4" />
                  Rename
                </Button>
                <Button variant="danger-solid" onClick={() => onRevoke(c)}>
                  <Ban className="size-4" />
                  Revoke access
                </Button>
              </>
            ) : (
              <Button variant="danger" onClick={() => onDelete(c)}>
                <Trash2 className="size-4" />
                Delete from history
              </Button>
            )}
          </div>
        </div>
      )}
    </Modal>
  )
}

export function PresenceTag({ presence }: { presence?: Controller['presence'] }) {
  const online = presence === 'online'
  return (
    <span
      className={cn('inline-flex items-center gap-1.5 text-[11px]', online ? 'text-online' : 'text-muted')}
      title="Online means a foreground heartbeat within 90 seconds. Closing the app or switching relays expires this status; it does not revoke access."
    >
      <span className={cn('size-1.5 rounded-full', online ? 'bg-online' : 'bg-faint')} />
      {online ? 'Online' : presence === 'offline' ? 'Offline' : 'Presence unknown'}
    </span>
  )
}

function IdentityRow({
  icon: Icon,
  label,
  value,
  copied,
  onCopy,
}: {
  icon?: typeof Fingerprint
  label: string
  value: string
  copied: boolean
  onCopy: () => void
}) {
  return (
    <div className="flex items-center gap-2">
      <div className="min-w-0 flex-1">
        <div className="flex items-center gap-1.5 text-[11px] text-muted">
          {Icon && <Icon className="size-3 opacity-70" />}
          {label}
        </div>
        <div className="truncate font-mono text-[12px] text-fg" title={value}>
          {value}
        </div>
      </div>
      <Button variant="ghost" size="icon" className="size-7 shrink-0" aria-label={`Copy ${label}`} onClick={onCopy}>
        {copied ? <Check className="size-3.5 text-online" /> : <Copy className="size-3.5" />}
      </Button>
    </div>
  )
}

function systemLine(name?: string, version?: string, build?: string): string | undefined {
  const base = [name, version].filter(Boolean).join(' ')
  if (!base) return undefined
  return build ? `${base} (${build})` : base
}

function appLine(version?: string, build?: string): string | undefined {
  if (!version && !build) return undefined
  if (version && build) return `${version} (${build})`
  return version || build
}

function storageLine(total?: number, free?: number): string | undefined {
  if (!total) return undefined
  return free !== undefined ? `${fmtBytes(free)} free of ${fmtBytes(total)}` : fmtBytes(total)
}

function batteryLine(t: ControllerTelemetry): string | undefined {
  if (t.battery_level === undefined) return undefined
  const state = t.battery_state && t.battery_state !== 'unknown' ? ` · ${t.battery_state}` : ''
  return `${t.battery_level}%${state}`
}

function batteryIcon(t: ControllerTelemetry) {
  if (t.battery_state === 'charging' || t.battery_state === 'full') return BatteryCharging
  if ((t.battery_level ?? 100) <= 20) return BatteryLow
  if ((t.battery_level ?? 100) >= 80) return BatteryFull
  return BatteryMedium
}
