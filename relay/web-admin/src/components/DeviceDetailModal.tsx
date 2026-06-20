import { useCallback, useEffect, useState } from 'react'
import {
  BatteryMedium,
  Check,
  ChevronRight,
  Copy,
  Cpu,
  ExternalLink,
  Hash,
  RefreshCw,
  Smartphone,
  Sun,
  Tablet,
} from 'lucide-react'
import { toast } from 'sonner'
import { Modal } from './ui/Modal'
import { Button } from './ui/Button'
import { OnlineDot, StatusBadge } from './ui/Status'
import { DetailSection, DetailField } from './ui/Detail'
import { api, controlURL } from '../lib/api'
import { fmtAbs, fmtRel } from '../lib/format'
import type { AuditEntry, Device, DeviceInfo, DiagnosticsResponse } from '../types'

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
  const [showDiag, setShowDiag] = useState(false)

  const reachable = !!device && device.online && device.status === 'approved'

  const load = useCallback((d: Device) => {
    setInfo(null)
    setErr('')
    if (!(d.online && d.status === 'approved')) return
    setLoading(true)
    api
      .deviceInfo(d.id)
      .then(setInfo, (e) => setErr(e instanceof Error ? e.message : 'unreachable'))
      .finally(() => setLoading(false))
  }, [])

  useEffect(() => {
    setShowDiag(false)
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
    <>
      <Modal open={!!device} onOpenChange={onOpenChange} title={device?.name || 'Device'} className="max-w-lg">
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

            {/* Live device info -- the essentials; the rest lives in Diagnostics */}
            <DetailSection
              title="Live"
              action={
                reachable ? (
                  <Button variant="ghost" size="sm" onClick={() => load(device)} loading={loading} aria-label="Refresh">
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
                <div className="space-y-3">
                  <div className="grid grid-cols-2 gap-x-4 gap-y-3">
                    <DetailField icon={Cpu} label="Model" value={info.model_id || info.model} />
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
                  <button
                    onClick={() => setShowDiag(true)}
                    className="flex w-full items-center justify-between rounded-lg bg-surface-2/60 px-3 py-2 text-[12.5px] text-fg-dim ring-1 ring-line/70 transition-colors hover:bg-surface-2 hover:text-fg"
                  >
                    <span className="flex items-center gap-2">
                      <Tablet className="size-3.5 opacity-70" />
                      Full diagnostics
                    </span>
                    <ChevronRight className="size-4 opacity-60" />
                  </button>
                </div>
              ) : null}
            </DetailSection>

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

      <DiagnosticsModal device={device} info={info} open={showDiag} onOpenChange={setShowDiag} />
    </>
  )
}

// Full detailed device view -- opens over the compact modal. Renders the device's
// /v1/deviceinfo, grouped. Designed to grow: drop more grouped fields in here as the
// device gathers them.
function DiagnosticsModal({
  device,
  info,
  open,
  onOpenChange,
}: {
  device: Device | null
  info: DeviceInfo | null
  open: boolean
  onOpenChange: (open: boolean) => void
}) {
  const [diag, setDiag] = useState<DiagnosticsResponse | null>(null)
  const [diagLoading, setDiagLoading] = useState(false)
  const reachable = !!device && device.online && device.status === 'approved'
  useEffect(() => {
    if (!open || !device || !reachable) {
      setDiag(null)
      return
    }
    setDiagLoading(true)
    api
      .diagnostics(device.id)
      .then(setDiag, () => setDiag(null))
      .finally(() => setDiagLoading(false))
    // fetch the heavy diagnostics lazily, only while this modal is open
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [open, device?.id])

  const ident = [
    { label: 'UDID', value: info?.udid },
    { label: 'Serial', value: info?.serial },
    { label: 'IMEI', value: info?.imei },
  ].filter((x) => x.value) as { label: string; value: string }[]

  return (
    <Modal open={open} onOpenChange={onOpenChange} title="Diagnostics" className="max-w-2xl">
      {device && (
        <div className="flex flex-col gap-6 sm:flex-row">
          {/* device illustration */}
          <div className="flex shrink-0 flex-col items-center gap-2.5 sm:w-40">
            <div className="grid aspect-[3/4] w-28 place-items-center rounded-[1.25rem] bg-gradient-to-b from-surface-2 to-surface shadow-inner ring-1 ring-line-2">
              <Tablet className="size-12 text-muted" strokeWidth={1.5} />
            </div>
            <div className="text-center">
              <div className="text-[13.5px] font-medium text-fg">{device.name}</div>
              <div className="font-mono text-[11px] text-muted">{info?.model_id || info?.model || '—'}</div>
              {info?.battery && (
                <div className="mt-1 inline-flex items-center gap-1 text-[11px] text-muted">
                  <BatteryMedium className="size-3" />
                  {info.battery}
                  {info.battery_state ? ` · ${info.battery_state}` : ''}
                </div>
              )}
            </div>
          </div>

          {/* grouped data */}
          <div className="min-w-0 flex-1 space-y-4">
            <DetailSection title="Hardware">
              <div className="grid grid-cols-2 gap-x-4 gap-y-3">
                <DetailField label="Model" value={info?.model_id || info?.model} />
                <DetailField label="CPU" value={info?.cpu} />
                <DetailField label="Memory" value={info?.memory} />
                <DetailField label="Storage" value={info?.storage} />
              </div>
            </DetailSection>

            <DetailSection title="System">
              <div className="grid grid-cols-2 gap-x-4 gap-y-3">
                <DetailField
                  label="iOS"
                  value={info?.ios ? info.ios + (info.build ? ` (${info.build})` : '') : undefined}
                />
                <DetailField label="Uptime" value={info?.uptime} />
                <DetailField
                  label="Brightness"
                  value={
                    typeof info?.brightness === 'number' ? `${Math.round(info.brightness * 100)}%` : undefined
                  }
                />
              </div>
            </DetailSection>

            {ident.length > 0 && (
              <DetailSection title="Identity">
                <div className="space-y-2.5">
                  {ident.map((f) => (
                    <CopyField key={f.label} label={f.label} value={f.value} />
                  ))}
                </div>
              </DetailSection>
            )}

            {/* Daemon-gathered diagnostics -- rendered generically from whatever the
                device reports (jailbreak, performance, storage, network, …). */}
            {diagLoading && !diag && (
              <DetailSection title="Diagnostics">
                <div className="space-y-2 py-1">
                  {[0, 1, 2].map((i) => (
                    <div key={i} className="h-4 w-2/3 animate-pulse rounded bg-surface-2" />
                  ))}
                </div>
              </DetailSection>
            )}
            {diag?.categories?.map((cat) => (
              <DetailSection key={cat.title} title={cat.title}>
                <div className="grid grid-cols-2 gap-x-4 gap-y-3">
                  {cat.fields.map((f) => (
                    <DetailField key={f.label} label={f.label} value={f.value} />
                  ))}
                </div>
              </DetailSection>
            ))}
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
