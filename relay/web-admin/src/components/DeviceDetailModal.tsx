import { useCallback, useEffect, useState } from 'react'
import {
  BatteryMedium,
  Check,
  Clock,
  Copy,
  Cpu,
  ExternalLink,
  HardDrive,
  Hash,
  MemoryStick,
  RefreshCw,
  Smartphone,
  Sun,
} from 'lucide-react'
import { toast } from 'sonner'
import { Modal } from './ui/Modal'
import { Button } from './ui/Button'
import { OnlineDot, StatusBadge } from './ui/Status'
import { DetailSection, DetailField } from './ui/Detail'
import { api, controlURL } from '../lib/api'
import { fmtAbs, fmtRel } from '../lib/format'
import type { AuditEntry, Device, DeviceInfo } from '../types'

export function DeviceDetailModal({
  device,
  onOpenChange,
}: {
  device: Device | null
  audit?: AuditEntry[]
  onOpenChange: (open: boolean) => void
}) {
  const [info, setInfo] = useState<DeviceInfo | null>(null)
  const [loading, setLoading] = useState(false)
  const [err, setErr] = useState('')
  const [copied, setCopied] = useState(false)

  const reachable = !!device && device.online && device.status === 'approved'

  const load = useCallback(
    (d: Device) => {
      setInfo(null)
      setErr('')
      if (!(d.online && d.status === 'approved')) return
      setLoading(true)
      api
        .deviceInfo(d.id)
        .then(setInfo, (e) => setErr(e instanceof Error ? e.message : 'unreachable'))
        .finally(() => setLoading(false))
    },
    [],
  )

  useEffect(() => {
    if (device) load(device)
    // refetch only when a different device opens -- not on every device-list poll
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [device?.id, load])

  function copyId() {
    if (!device) return
    navigator.clipboard?.writeText(device.id).then(() => {
      setCopied(true)
      toast.success('Device ID copied')
      setTimeout(() => setCopied(false), 1600)
    })
  }

  return (
    <Modal
      open={!!device}
      onOpenChange={onOpenChange}
      title={device?.name || 'Device'}
      className="max-w-lg"
    >
      {device && (
        <div className="space-y-5">
          <div className="flex items-center gap-3">
            <div className="grid size-10 shrink-0 place-items-center rounded-xl bg-surface-2 text-muted ring-1 ring-line">
              <Smartphone className="size-5" />
            </div>
            <div className="min-w-0 flex-1">
              <button
                onClick={copyId}
                title={device.id}
                className="inline-flex max-w-full items-center gap-1.5 font-mono text-[12px] text-muted transition-colors hover:text-fg-dim"
              >
                <span className="truncate">{device.id}</span>
                {copied ? (
                  <Check className="size-3 shrink-0 text-online" />
                ) : (
                  <Copy className="size-3 shrink-0 opacity-60" />
                )}
              </button>
            </div>
            <OnlineDot online={device.online} />
            <StatusBadge status={device.status} />
          </div>

          {/* Live device info */}
          <DetailSection
            title="Live"
            action={
              reachable ? (
                <Button
                  variant="ghost"
                  size="sm"
                  onClick={() => load(device)}
                  loading={loading}
                  aria-label="Refresh"
                >
                  {!loading && <RefreshCw className="size-3.5" />}
                  Refresh
                </Button>
              ) : undefined
            }
          >
            {!reachable ? (
              <p className="px-1 py-2 text-[13px] text-muted">
                {device.status !== 'approved'
                  ? 'Approve the device to read live info.'
                  : 'Device is offline — live info unavailable.'}
              </p>
            ) : err ? (
              <p className="px-1 py-2 text-[13px] text-danger">Couldn’t reach device ({err}).</p>
            ) : loading && !info ? (
              <div className="space-y-2 px-1 py-1.5">
                {[0, 1, 2].map((i) => (
                  <div key={i} className="h-4 w-2/3 animate-pulse rounded bg-surface-2" />
                ))}
              </div>
            ) : info ? (
              <div className="grid grid-cols-2 gap-x-4 gap-y-3">
                <DetailField icon={Smartphone} label="Model" value={info.model_id || info.model} />
                <DetailField
                  icon={Hash}
                  label="iOS"
                  value={info.ios ? info.ios + (info.build ? ` (${info.build})` : '') : undefined}
                />
                <DetailField icon={Cpu} label="CPU" value={info.cpu} />
                <DetailField icon={MemoryStick} label="Memory" value={info.memory} />
                <DetailField
                  icon={BatteryMedium}
                  label="Battery"
                  value={
                    info.battery
                      ? info.battery + (info.battery_state ? ` · ${info.battery_state}` : '')
                      : undefined
                  }
                />
                <DetailField
                  icon={Sun}
                  label="Brightness"
                  value={
                    typeof info.brightness === 'number'
                      ? `${Math.round(info.brightness * 100)}%`
                      : undefined
                  }
                />
                <DetailField icon={HardDrive} label="Storage" value={info.storage} />
                <DetailField icon={Clock} label="Uptime" value={info.uptime} />
              </div>
            ) : null}
          </DetailSection>

          {info && (info.udid || info.serial || info.imei) && (
            <DetailSection title="Identity">
              <div className="space-y-2.5">
                {info.udid && <CopyField label="UDID" value={info.udid} />}
                {info.serial && <CopyField label="Serial" value={info.serial} />}
                {info.imei && <CopyField label="IMEI" value={info.imei} />}
              </div>
            </DetailSection>
          )}

          {/* Relay-side record */}
          <DetailSection title="Relay record">
            <div className="grid grid-cols-2 gap-x-4 gap-y-3">
              <DetailField label="Created" value={fmtAbs(device.created_at)} />
              <DetailField label="Approved" value={device.approved_at ? fmtAbs(device.approved_at) : '—'} />
              <DetailField label="Last seen" value={device.last_seen_at ? fmtRel(device.last_seen_at) : '—'} />
              <DetailField label="Updated" value={fmtRel(device.updated_at)} />
            </div>
          </DetailSection>

          <div className="flex justify-end gap-2.5 pt-1">
            <Button variant="secondary" onClick={() => onOpenChange(false)}>
              Close
            </Button>
            {reachable && (
              <Button
                variant="primary"
                onClick={() => window.open(controlURL(device.id), '_blank', 'noopener')}
              >
                <ExternalLink className="size-4" />
                Open control
              </Button>
            )}
          </div>
        </div>
      )}
    </Modal>
  )
}

// Copyable identity row (UDID / serial / IMEI) -- long, mono, one-tap copy.
function CopyField({ label, value }: { label: string; value: string }) {
  const [done, setDone] = useState(false)
  return (
    <button
      onClick={() =>
        navigator.clipboard?.writeText(value).then(() => {
          setDone(true)
          toast.success(`${label} copied`)
          setTimeout(() => setDone(false), 1400)
        })
      }
      className="group flex w-full items-center justify-between gap-2 text-left"
    >
      <span className="shrink-0 text-[11px] text-muted">{label}</span>
      <span className="flex min-w-0 items-center gap-1.5">
        <span className="truncate font-mono text-[12.5px] text-fg" title={value}>
          {value}
        </span>
        {done ? (
          <Check className="size-3 shrink-0 text-online" />
        ) : (
          <Copy className="size-3 shrink-0 opacity-40 transition-opacity group-hover:opacity-70" />
        )}
      </span>
    </button>
  )
}
