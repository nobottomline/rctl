import { useEffect, useRef, useState, type ReactNode } from 'react'
import { Camera, Check, Circle, Copy, Download, SwitchCamera, X } from 'lucide-react'
import { api, apiDo, apiJSON, destructivePost } from '../lib/rctl'
import type { FileTransfer } from '../lib/files'
import { Sheet } from './Sheet'
import { cn } from '../lib/cn'
import { CameraTransport } from '../lib/camera'
import { cameraRecordingToMp4 } from '../lib/cameraRecording'

// Console: the rich, occasional device tooling. Device/Diagnostics (data-dense)
// run full-width up top; the action tools flow in a 2-column masonry below, so
// the wide sheet reads horizontally instead of one tall column. Pure /v1 calls.
// (Camera / on-device screenshot / record-play are ported in a follow-up.)
type DeviceInfo = {
  name?: string; model?: string; model_id?: string; ios?: string; build?: string
  battery?: string; battery_state?: string; brightness?: number; cpu?: string
  memory?: string; storage?: string; uptime?: string; udid?: string; serial?: string; imei?: string
}
type DiagnosticsResponse = { categories: { title: string; fields: { label: string; value: string }[] }[] }
type RecordApi = {
  mode: 'idle' | 'recording' | 'paused' | 'playing'
  count: number
  start: () => void
  pause: () => void
  resume: () => void
  stop: () => void
  play: () => void
  stopPlay: () => void
}
type CameraStatus = {
  enabled: boolean
  state: 'off' | 'waiting_for_app' | 'live'
  position: 'front' | 'back'
  owner?: string
  recording: boolean
  record_bytes: number
  record_ms: number
  record_path: string
}

const enc = encodeURIComponent
const FIELD =
  'h-9 w-full min-w-0 rounded-lg bg-fg/[0.06] px-2.5 text-[13px] text-fg outline-none ring-1 ring-line/70 transition placeholder:text-faint focus:ring-2 focus:ring-signal/70'

export default function ConsolePanel({
  onClose,
  onScreenshot,
  record,
  transfer,
}: {
  onClose: () => void
  onScreenshot: () => void | Promise<void>
  record: RecordApi
  transfer: FileTransfer
}) {
  return (
    <Sheet title="Console" onClose={onClose} wide>
      <div className="space-y-2.5 p-3.5">
        <DeviceCard />
        <DiagnosticsCard />
        <div className="gap-2.5 sm:columns-2 [&>*]:mb-2.5 [&>*]:break-inside-avoid">
          <FxCard />
          <CameraCard transfer={transfer} />
          <ScreenshotCard onScreenshot={onScreenshot} />
          <RecordCard record={record} />
          <LaunchCard />
          <TextAction title="Open URL" placeholder="https://apple.com" button="Open" run={(v) => apiDo(`/v1/openurl?url=${enc(v)}`)} />
          <TextAction title="Type text" placeholder="into the focused field" button="Type" run={(v) => apiDo(`/v1/type?text=${enc(v)}`)} />
          <AlertCard />
          <TextAction title="Toast" placeholder="message" button="Show" run={(v) => apiDo(`/v1/toast?text=${enc(v)}`)} />
          <ClipboardCard />
          <ScriptCard />
          <RespringCard />
        </div>
      </div>
    </Sheet>
  )
}

// ── primitives ──────────────────────────────────────────────────────────────
function Card({ title, action, children }: { title: string; action?: ReactNode; children: ReactNode }) {
  return (
    <div className="rounded-xl bg-fg/[0.04] p-3 ring-1 ring-line/60">
      <div className="mb-2.5 flex items-center gap-2">
        <div className="text-[10px] font-semibold uppercase tracking-wider text-muted">{title}</div>
        {action && <div className="ml-auto">{action}</div>}
      </div>
      {children}
    </div>
  )
}

function Btn({ onClick, children, primary }: { onClick: () => void; children: ReactNode; primary?: boolean }) {
  return (
    <button
      onClick={onClick}
      className={cn(
        'inline-flex h-9 shrink-0 items-center rounded-lg px-3 text-[12px] font-medium transition-colors',
        primary ? 'bg-signal font-semibold text-on-signal active:opacity-80' : 'bg-fg/8 text-fg active:bg-fg/15',
      )}
    >
      {children}
    </button>
  )
}

// ── device ──────────────────────────────────────────────────────────────────
function KV({ k, v }: { k: string; v?: string | number }) {
  if (v === undefined || v === null || v === '') return null
  return (
    <div className="flex flex-col gap-0.5">
      <span className="text-[9.5px] uppercase tracking-wide text-muted">{k}</span>
      <span className="truncate text-[12.5px] text-fg">{String(v)}</span>
    </div>
  )
}

function CopyRow({ k, v }: { k: string; v?: string }) {
  const [copied, setCopied] = useState(false)
  if (!v) return null
  const copy = () => {
    navigator.clipboard
      ?.writeText(v)
      .then(() => {
        setCopied(true)
        setTimeout(() => setCopied(false), 1200)
      })
      .catch(() => {})
  }
  return (
    <button onClick={copy} className="flex w-full items-center gap-2 text-left">
      <span className="w-11 shrink-0 text-[9.5px] uppercase tracking-wide text-muted">{k}</span>
      <span className="min-w-0 flex-1 truncate font-mono text-[12px] text-fg-dim">{v}</span>
      {copied ? <Check className="size-3.5 shrink-0 text-online" /> : <Copy className="size-3.5 shrink-0 text-faint" />}
    </button>
  )
}

function DeviceCard() {
  const [info, setInfo] = useState<DeviceInfo | null>(null)
  const load = () => apiJSON<DeviceInfo>('/v1/deviceinfo').then((j) => j && setInfo(j))
  useEffect(() => {
    load()
  }, [])
  return (
    <Card title="Device" action={<Btn onClick={load}>Refresh</Btn>}>
      {!info ? (
        <div className="text-[12px] text-muted">…</div>
      ) : (
        <>
          <div className="grid grid-cols-2 gap-x-4 gap-y-2.5 sm:grid-cols-4">
            <KV k="Name" v={info.name} />
            <KV k="Model" v={info.model} />
            <KV k="Model ID" v={info.model_id} />
            <KV k="iOS" v={info.ios && `${info.ios}${info.build ? ` (${info.build})` : ''}`} />
            <KV k="CPU" v={info.cpu} />
            <KV k="Memory" v={info.memory} />
            <KV k="Storage" v={info.storage} />
            <KV k="Battery" v={info.battery && `${info.battery}%${info.battery_state ? ` · ${info.battery_state}` : ''}`} />
            <KV k="Brightness" v={info.brightness != null ? `${Math.round(info.brightness * 100)}%` : undefined} />
            <KV k="Uptime" v={info.uptime} />
          </div>
          {(info.udid || info.serial || info.imei) && (
            <div className="mt-3 space-y-1.5 border-t border-line/60 pt-2.5">
              <CopyRow k="UDID" v={info.udid} />
              <CopyRow k="Serial" v={info.serial} />
              <CopyRow k="IMEI" v={info.imei} />
            </div>
          )}
        </>
      )}
    </Card>
  )
}

function DiagnosticsCard() {
  const [data, setData] = useState<DiagnosticsResponse | null>(null)
  const [loading, setLoading] = useState(false)
  const run = async () => {
    setLoading(true)
    const j = await apiJSON<DiagnosticsResponse>('/v1/diagnostics')
    setLoading(false)
    if (j) setData(j)
  }
  return (
    <Card title="Diagnostics" action={<Btn onClick={run}>{loading ? '…' : data ? 'Refresh' : 'Run'}</Btn>}>
      {!data ? (
        <div className="text-[12px] text-muted">Jailbreak · performance · storage · network status, gathered on demand.</div>
      ) : (
        <div className="grid grid-cols-1 gap-x-5 gap-y-3.5 sm:grid-cols-2">
          {data.categories.map((cat) => (
            <div key={cat.title}>
              <div className="mb-1.5 text-[10px] font-semibold uppercase tracking-wide text-signal">{cat.title}</div>
              <div className="space-y-1">
                {cat.fields.map((f) => (
                  <div key={f.label} className="flex justify-between gap-3 text-[12px]">
                    <span className="shrink-0 text-muted">{f.label}</span>
                    <span className="truncate text-right font-mono text-fg-dim">{f.value}</span>
                  </div>
                ))}
              </div>
            </div>
          ))}
        </div>
      )}
    </Card>
  )
}

// ── action tools ────────────────────────────────────────────────────────────
function TextAction({
  title,
  placeholder,
  button,
  run,
}: {
  title: string
  placeholder: string
  button: string
  run: (v: string) => void
}) {
  const [v, setV] = useState('')
  return (
    <Card title={title}>
      <div className="flex gap-1.5">
        <input
          value={v}
          onChange={(e) => setV(e.target.value)}
          onKeyDown={(e) => e.key === 'Enter' && run(v)}
          placeholder={placeholder}
          spellCheck={false}
          className={FIELD}
        />
        <Btn primary onClick={() => run(v)}>
          {button}
        </Btn>
      </div>
    </Card>
  )
}

function FxCard() {
  const [t, setT] = useState('')
  const text = () => enc(t || 'Boo!')
  return (
    <Card title="FX / Pranks">
      <input
        value={t}
        onChange={(e) => setT(e.target.value)}
        placeholder="text to speak / show"
        spellCheck={false}
        className={cn(FIELD, 'mb-2')}
      />
      <div className="flex flex-wrap gap-1.5">
        <Btn onClick={() => apiDo(`/v1/say?text=${text()}`)}>Speak</Btn>
        <Btn onClick={() => apiDo(`/v1/say?text=${text()}&pitch=0.45&rate=0.38`)}>Creepy</Btn>
        <Btn onClick={() => apiDo(`/v1/banner?text=${text()}&secs=4`)}>Banner</Btn>
        <Btn onClick={() => apiDo(`/v1/spook?text=${text()}`)}>Spook</Btn>
        <Btn onClick={() => apiDo(`/v1/flash?times=8&color=ff0000`)}>Flash</Btn>
        <Btn onClick={() => apiDo(`/v1/sound?id=1304`)}>Sound</Btn>
      </div>
    </Card>
  )
}

function LaunchCard() {
  const [v, setV] = useState('')
  const [apps, setApps] = useState<{ name: string; id: string }[]>([])
  useEffect(() => {
    apiJSON<{ name: string; id: string }[]>('/v1/apps').then((a) => a && setApps(a))
  }, [])
  const launch = () => {
    const t = v.trim()
    if (!t) return
    const m = apps.find((a) => a.name === t)
    apiDo(`/v1/launch?bundle=${enc(m ? m.id : t)}`)
  }
  return (
    <Card title="Launch app">
      <div className="flex gap-1.5">
        <input
          list="rctl-apps"
          value={v}
          onChange={(e) => setV(e.target.value)}
          onKeyDown={(e) => e.key === 'Enter' && launch()}
          placeholder="App name or bundle id"
          spellCheck={false}
          className={FIELD}
        />
        <datalist id="rctl-apps">
          {apps.map((a) => (
            <option key={a.id} value={a.name}>
              {a.id}
            </option>
          ))}
        </datalist>
        <Btn primary onClick={launch}>
          Launch
        </Btn>
      </div>
    </Card>
  )
}

function AlertCard() {
  const [title, setTitle] = useState('')
  const [msg, setMsg] = useState('')
  return (
    <Card title="Alert">
      <div className="space-y-1.5">
        <input value={title} onChange={(e) => setTitle(e.target.value)} placeholder="Title" className={FIELD} />
        <div className="flex gap-1.5">
          <input value={msg} onChange={(e) => setMsg(e.target.value)} placeholder="Message" className={FIELD} />
          <Btn primary onClick={() => apiDo(`/v1/alert?title=${enc(title)}&message=${enc(msg)}`)}>
            Show
          </Btn>
        </div>
      </div>
    </Card>
  )
}

function ClipboardCard() {
  const [v, setV] = useState('')
  const get = async () => {
    const j = await apiJSON<{ text?: string }>('/v1/clipboard')
    if (j) setV(j.text || '')
  }
  return (
    <Card title="Clipboard">
      <textarea
        value={v}
        onChange={(e) => setV(e.target.value)}
        rows={2}
        placeholder="clipboard text"
        className={cn(FIELD, 'h-auto resize-none py-2')}
      />
      <div className="mt-1.5 flex gap-1.5">
        <Btn onClick={get}>Get</Btn>
        <Btn primary onClick={() => api('/v1/clipboard', { method: 'POST', body: v }).catch(() => {})}>
          Set on iPad
        </Btn>
      </div>
    </Card>
  )
}

function ScriptCard() {
  const [v, setV] = useState('')
  return (
    <Card title="Script (JSON macro)">
      <textarea
        value={v}
        onChange={(e) => setV(e.target.value)}
        rows={3}
        placeholder='{"actions":[{"type":"tap","x":0.5,"y":0.5}]}'
        spellCheck={false}
        className={cn(FIELD, 'h-auto resize-none py-2 font-mono text-[12px]')}
      />
      <div className="mt-1.5">
        <Btn primary onClick={() => api('/v1/script', { method: 'POST', body: v }).catch(() => {})}>
          Run
        </Btn>
      </div>
    </Card>
  )
}

function CameraCard({ transfer }: { transfer: FileTransfer }) {
  const [info, setInfo] = useState('')
  const [img, setImg] = useState<string | null>(null)
  const blobRef = useRef<Blob | null>(null)
  const [livePosition, setLivePosition] = useState<'back' | 'front' | null>(null)
  const snap = async (pos: 'back' | 'front') => {
    setInfo('capturing…')
    setImg(null)
    try {
      // /v1/camera only triggers the snap and returns a tiny status; the JPEG is
      // pulled over the P2P files channel (the relay tunnel can't carry a multi-MB
      // body without dropping the device link).
      const r = await api(`/v1/camera?pos=${pos}&nodata=1`)
      if (!r.ok) {
        let m = 'failed'
        try {
          m = ((await r.json()) as { error?: string }).error || m
        } catch {
          /* ignore */
        }
        setInfo(m)
        return
      }
      const j = (await r.json()) as { ready?: boolean; path?: string }
      if (!j.ready) {
        setInfo('no photo')
        return
      }
      setInfo('transferring…')
      const blob = await transfer.fetch(j.path || '/tmp/rctl_cam.jpg')
      blobRef.current = blob
      setImg(URL.createObjectURL(blob))
      setInfo('')
    } catch (e) {
      setInfo(e instanceof Error ? e.message : 'transfer failed')
    }
  }
  const save = () => {
    const b = blobRef.current
    if (!b) return
    const u = URL.createObjectURL(b)
    const a = document.createElement('a')
    a.href = u
    a.download = `rctl-cam-${Date.now()}.jpg`
    a.click()
    setTimeout(() => URL.revokeObjectURL(u), 1000)
  }
  return (
    <Card title="Camera">
      <div className="flex flex-wrap gap-1.5">
        <Btn primary onClick={() => setLivePosition('back')}>
          <Camera className="mr-1.5 size-3.5" /> Live
        </Btn>
        <Btn onClick={() => snap('back')}>Rear</Btn>
        <Btn onClick={() => snap('front')}>Front</Btn>
        {img && (
          <Btn primary onClick={save}>
            Save
          </Btn>
        )}
      </div>
      {info && <div className="mt-2 text-[12px] text-muted">{info}</div>}
      {img && <img src={img} alt="camera" className="mt-2 w-full rounded-lg" />}
      {livePosition && (
        <CameraLiveView initialPosition={livePosition} transfer={transfer} onClose={() => setLivePosition(null)} />
      )}
    </Card>
  )
}

function CameraLiveView({
  initialPosition,
  transfer,
  onClose,
}: {
  initialPosition: 'back' | 'front'
  transfer: FileTransfer
  onClose: () => void
}) {
  const videoRef = useRef<HTMLVideoElement>(null)
  const transportRef = useRef<CameraTransport | null>(null)
  const [position, setPosition] = useState(initialPosition)
  const [transportState, setTransportState] = useState('connecting')
  const [status, setStatus] = useState<CameraStatus | null>(null)
  const [busy, setBusy] = useState(false)

  const applyStatus = (value: CameraStatus) => {
    setStatus(value)
    transportRef.current?.setExpectedLive(value.state === 'live')
  }
  const loadStatus = () => apiJSON<CameraStatus>('/v1/cam_status?lease=1')
  useEffect(() => {
    let cancelled = false
    let startTimer = 0
    let requestAbort: AbortController | null = null
    const retryStart = () => {
      if (!cancelled) startTimer = window.setTimeout(start, 1500)
    }
    const start = async () => {
      const controller = new AbortController()
      requestAbort = controller
      const timeout = window.setTimeout(() => controller.abort(), 8000)
      let response: Response
      try {
        response = await api(`/v1/cam_live?on=1&pos=${initialPosition}&fps=10&bitrate=1500000`, {
          signal: controller.signal,
        })
      } catch {
        if (!cancelled) {
          setTransportState('reconnecting')
          retryStart()
        }
        return
      } finally {
        window.clearTimeout(timeout)
        if (requestAbort === controller) requestAbort = null
      }
      if (!response.ok) {
        if (!cancelled) {
          setTransportState('camera unavailable')
          retryStart()
        }
        return
      }
      if (cancelled) return
      const value = (await response.json()) as CameraStatus
      if (cancelled) return
      setStatus(value)
      const video = videoRef.current
      if (!video) return
      const transport = new CameraTransport(video, { onState: setTransportState })
      transportRef.current = transport
      transport.start()
      transport.setExpectedLive(value.state === 'live')
    }
    start().catch(() => {
      if (!cancelled) {
        setTransportState('camera unavailable')
        retryStart()
      }
    })
    let pollTimer = window.setTimeout(async function poll() {
      try {
        const value = await loadStatus()
        if (!cancelled && value) applyStatus(value)
      } catch {
        if (!cancelled) setTransportState('reconnecting')
      } finally {
        if (!cancelled) pollTimer = window.setTimeout(poll, 1000)
      }
    }, 1000)
    return () => {
      cancelled = true
      requestAbort?.abort()
      window.clearTimeout(startTimer)
      window.clearTimeout(pollTimer)
      transportRef.current?.stop()
      apiDo('/v1/cam_live?on=0')
    }
  }, [initialPosition])

  const switchPosition = async () => {
    const next = position === 'back' ? 'front' : 'back'
    setBusy(true)
    const response = await api(`/v1/cam_live?on=1&pos=${next}&fps=10&bitrate=1500000`).catch(() => null)
    setBusy(false)
    if (response?.ok) {
      setPosition(next)
      loadStatus().then((value) => { if (value) applyStatus(value) }).catch(() => {})
    }
  }
  const toggleRecording = async () => {
    setBusy(true)
    const on = !status?.recording
    const response = await api(`/v1/cam_record?on=${on ? 1 : 0}`).catch(() => null)
    setBusy(false)
    if (response?.ok) applyStatus((await response.json()) as CameraStatus)
  }
  const saveRecording = async () => {
    if (!status?.record_path || status.recording) return
    setBusy(true)
    try {
      const recording = await transfer.fetch(status.record_path)
      const mp4 = await cameraRecordingToMp4(recording)
      const url = URL.createObjectURL(mp4)
      const anchor = document.createElement('a')
      anchor.href = url
      anchor.download = `rctl-camera-${Date.now()}.mp4`
      anchor.click()
      window.setTimeout(() => URL.revokeObjectURL(url), 1000)
    } catch {
      setTransportState('recording download failed')
    } finally {
      setBusy(false)
    }
  }
  const stateLabel = status?.state === 'waiting_for_app'
    ? 'Open an app on the iPad'
    : status?.state === 'live'
      ? `${position === 'front' ? 'Front' : 'Rear'} camera${status.owner ? ` · ${status.owner}` : ''}`
      : transportState

  return (
    <div className="fixed inset-0 z-[70] flex flex-col bg-black text-white">
      <div className="flex h-12 shrink-0 items-center gap-2 border-b border-white/10 px-3">
        <Camera className="size-4" />
        <span className="min-w-0 flex-1 truncate text-[13px] font-medium">{stateLabel}</span>
        {status?.recording && (
          <span className="flex items-center gap-1.5 font-mono text-[11px] text-red-300">
            <span className="size-2 animate-pulse rounded-full bg-red-500" />
            {formatCameraDuration(status.record_ms)}
          </span>
        )}
        <button onClick={onClose} title="Close" aria-label="Close camera" className="grid size-8 place-items-center rounded-lg bg-white/10 active:bg-white/20">
          <X className="size-4" />
        </button>
      </div>
      <div className="relative min-h-0 flex-1 bg-black">
        <video ref={videoRef} autoPlay playsInline muted className="size-full object-contain" />
        {status?.state !== 'live' && (
          <div className="absolute inset-0 grid place-items-center px-6 text-center text-[13px] text-white/60">{stateLabel}</div>
        )}
      </div>
      <div className="flex min-h-16 shrink-0 items-center justify-center gap-3 border-t border-white/10 px-3 pb-[env(safe-area-inset-bottom)]">
        <button
          onClick={switchPosition}
          disabled={busy}
          title="Switch camera"
          aria-label="Switch camera"
          className="grid size-10 place-items-center rounded-full bg-white/12 disabled:opacity-40"
        >
          <SwitchCamera className="size-5" />
        </button>
        <button
          onClick={toggleRecording}
          disabled={busy || status?.state !== 'live'}
          title={status?.recording ? 'Stop recording' : 'Start recording'}
          aria-label={status?.recording ? 'Stop recording' : 'Start recording'}
          className={cn(
            'grid size-12 place-items-center rounded-full ring-2 ring-white/70 disabled:opacity-40',
            status?.recording ? 'bg-red-500' : 'bg-white/10',
          )}
        >
          {status?.recording ? <span className="size-4 rounded-sm bg-white" /> : <Circle className="size-7 fill-red-500 text-red-500" />}
        </button>
        <button
          onClick={saveRecording}
          disabled={busy || status?.recording || !status?.record_bytes}
          title="Save recording"
          aria-label="Save recording"
          className="grid size-10 place-items-center rounded-full bg-white/12 disabled:opacity-30"
        >
          <Download className="size-5" />
        </button>
      </div>
    </div>
  )
}

function formatCameraDuration(ms: number) {
  const seconds = Math.max(0, Math.floor(ms / 1000))
  const minutes = Math.floor(seconds / 60)
  return `${minutes}:${String(seconds % 60).padStart(2, '0')}`
}

function RecordCard({ record }: { record: RecordApi }) {
  const { mode, count } = record
  const status =
    mode === 'recording'
      ? 'recording…'
      : mode === 'paused'
        ? 'paused'
        : mode === 'playing'
          ? 'playing…'
          : count
            ? `${count} events recorded`
            : 'no recording'
  const dot =
    mode === 'recording'
      ? 'bg-red-500 animate-pulse'
      : mode === 'paused'
        ? 'bg-amber-400'
        : mode === 'playing'
          ? 'bg-signal animate-pulse'
          : 'bg-faint'
  return (
    <Card title="Record & play">
      <div className="mb-2 flex items-center gap-2 font-mono text-[12px] text-fg-dim">
        <span className={cn('size-2 rounded-full', dot)} />
        {status}
      </div>
      <div className="flex flex-wrap gap-1.5">
        {mode === 'recording' && (
          <>
            <Btn onClick={record.pause}>Pause</Btn>
            <Btn primary onClick={record.stop}>
              Stop
            </Btn>
          </>
        )}
        {mode === 'paused' && (
          <>
            <Btn onClick={record.resume}>Resume</Btn>
            <Btn primary onClick={record.stop}>
              Stop
            </Btn>
          </>
        )}
        {mode === 'playing' && (
          <>
            <Btn onClick={record.start}>Record</Btn>
            <Btn primary onClick={record.stopPlay}>
              Stop
            </Btn>
          </>
        )}
        {mode === 'idle' && (
          <>
            <Btn onClick={record.start}>{count ? 'Re-record' : 'Record'}</Btn>
            {count > 0 && (
              <Btn primary onClick={record.play}>
                Play
              </Btn>
            )}
          </>
        )}
      </div>
    </Card>
  )
}

function ScreenshotCard({ onScreenshot }: { onScreenshot: () => void | Promise<void> }) {
  const [busy, setBusy] = useState(false)
  return (
    <Card title="Screenshot">
      <div className="mb-2 text-[12px] text-muted">
        Full-resolution lossless PNG from the device — invisible on the iPad.
      </div>
      <Btn
        primary
        onClick={async () => {
          setBusy(true)
          try {
            await onScreenshot()
          } finally {
            setBusy(false)
          }
        }}
      >
        {busy ? 'Saving…' : 'Save frame'}
      </Btn>
    </Card>
  )
}

function RespringCard() {
  return (
    <Card title="Device control">
      <Btn
        onClick={() => {
          if (confirm('Respring the device?')) destructivePost('/v1/respring', 'respring', 'SpringBoard').catch(() => {})
        }}
      >
        Respring
      </Btn>
    </Card>
  )
}
