import { useCallback, useEffect, useState } from 'react'
import {
  BatteryMedium,
  Check,
  Copy,
  Cpu,
  ExternalLink,
  Hash,
  PlugZap,
  Power,
  RefreshCw,
  RotateCw,
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
  audit = [],
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
  const [respringing, setRespringing] = useState(false)
  const [confirmRespring, setConfirmRespring] = useState(false)

  const reachable = !!device && device.online && device.status === 'approved'

  const history = device
    ? audit
        .filter((e) => {
          if (e.event !== 'device_connected' && e.event !== 'device_disconnected') return false
          try {
            return (JSON.parse(e.detail || '{}') as { device_id?: string }).device_id === device.id
          } catch {
            return false
          }
        })
        .slice(0, 6)
    : []

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
    setConfirmRespring(false)
    if (device) load(device)
  }, [device, load])

  function copyId() {
    if (!device) return
    navigator.clipboard?.writeText(device.id).then(() => {
      setCopied(true)
      toast.success('Device ID copied')
      setTimeout(() => setCopied(false), 1600)
    })
  }

  async function respring() {
    if (!device) return
    setRespringing(true)
    try {
      await api.respringDevice(device.id)
      toast.success('Respring sent')
      setConfirmRespring(false)
    } catch (e) {
      toast.error(e instanceof Error ? e.message : 'Respring failed')
    } finally {
      setRespringing(false)
    }
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
                <DetailField icon={Cpu} label="Model" value={info.model} />
                <DetailField icon={Hash} label="iOS" value={info.ios} />
                <DetailField icon={BatteryMedium} label="Battery" value={info.battery} />
                <DetailField
                  icon={Sun}
                  label="Brightness"
                  value={
                    typeof info.brightness === 'number'
                      ? `${Math.round(info.brightness * 100)}%`
                      : undefined
                  }
                />
              </div>
            ) : null}
          </DetailSection>

          {reachable && (
            <DetailSection title="Controls">
              {!confirmRespring ? (
                <Button variant="secondary" size="sm" onClick={() => setConfirmRespring(true)}>
                  <RotateCw className="size-3.5" />
                  Respring
                </Button>
              ) : (
                <div className="flex flex-wrap items-center gap-2.5">
                  <span className="text-[12.5px] text-muted">Restart SpringBoard?</span>
                  <Button variant="ghost" size="sm" onClick={() => setConfirmRespring(false)}>
                    Cancel
                  </Button>
                  <Button variant="danger-solid" size="sm" loading={respringing} onClick={respring}>
                    Confirm
                  </Button>
                </div>
              )}
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

          {history.length > 0 && (
            <DetailSection title="Connection history">
              <ul className="space-y-1.5">
                {history.map((e) => (
                  <li key={e.id} className="flex items-center gap-2 text-[12.5px]">
                    {e.event === 'device_connected' ? (
                      <PlugZap className="size-3.5 shrink-0 text-online" />
                    ) : (
                      <Power className="size-3.5 shrink-0 text-muted" />
                    )}
                    <span className="text-fg-dim">
                      {e.event === 'device_connected' ? 'Connected' : 'Disconnected'}
                    </span>
                    <span className="ml-auto text-muted tnum">{fmtRel(e.ts)}</span>
                  </li>
                ))}
              </ul>
            </DetailSection>
          )}

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
