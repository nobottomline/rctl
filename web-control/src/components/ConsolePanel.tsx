import { useEffect, useState, type ReactNode } from 'react'
import { api, apiDo, apiJSON } from '../lib/rctl'
import { Sheet } from './Sheet'
import { cn } from '../lib/cn'

// Console: the rich, occasional device tooling, grouped as cards (mirrors the
// vanilla page's Console modal). Pure HTTP calls to rctld's /v1 endpoints. The
// stateful/visual tools (camera, record/play, on-device screenshot) are ported
// in a follow-up; this covers the form/button tools.
const enc = encodeURIComponent
const FIELD =
  'w-full min-w-0 rounded-lg bg-fg/8 px-2.5 py-2 text-[13px] text-fg outline-none ring-1 ring-line placeholder:text-faint focus:ring-signal'

export default function ConsolePanel({ onClose }: { onClose: () => void }) {
  return (
    <Sheet title="Console" onClose={onClose}>
      <div className="space-y-2.5 p-3.5">
        <FxCard />
        <LaunchCard />
        <TextAction title="Open URL" placeholder="https://apple.com" button="Open" run={(v) => apiDo(`/v1/openurl?url=${enc(v)}`)} />
        <TextAction title="Type text" placeholder="into the focused field" button="Type" run={(v) => apiDo(`/v1/type?text=${enc(v)}`)} />
        <AlertCard />
        <TextAction title="Toast" placeholder="message" button="Show" run={(v) => apiDo(`/v1/toast?text=${enc(v)}`)} />
        <ClipboardCard />
        <DeviceCard />
        <ScriptCard />
        <RespringCard />
      </div>
    </Sheet>
  )
}

function Card({ title, children }: { title: string; children: ReactNode }) {
  return (
    <div className="rounded-2xl bg-fg/5 p-3">
      <div className="mb-2 text-[11px] font-semibold uppercase tracking-wide text-muted">{title}</div>
      {children}
    </div>
  )
}

function Btn({ onClick, children, primary }: { onClick: () => void; children: ReactNode; primary?: boolean }) {
  return (
    <button
      onClick={onClick}
      className={cn(
        'shrink-0 rounded-lg px-3 py-2 text-[12px] font-medium transition-colors',
        primary ? 'bg-signal text-on-signal active:opacity-80' : 'bg-fg/10 text-fg active:bg-fg/15',
      )}
    >
      {children}
    </button>
  )
}

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
        placeholder="text to speak / show on screen"
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
        className={cn(FIELD, 'mb-1.5 resize-none')}
      />
      <div className="flex gap-1.5">
        <Btn onClick={get}>Get from iPad</Btn>
        <Btn primary onClick={() => api('/v1/clipboard', { method: 'POST', body: v }).catch(() => {})}>
          Set on iPad
        </Btn>
      </div>
    </Card>
  )
}

function DeviceCard() {
  const [info, setInfo] = useState('—')
  const refresh = async () => {
    const j = await apiJSON<{ name?: string; model?: string; ios?: string; battery?: string }>('/v1/deviceinfo')
    setInfo(j ? `${j.name || '?'} · ${j.model || ''} · iOS ${j.ios || ''} · ${j.battery || '?'}%` : '(no reply)')
  }
  return (
    <Card title="Device info">
      <div className="mb-2 font-mono text-[12px] text-fg-dim">{info}</div>
      <Btn onClick={refresh}>Refresh</Btn>
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
        className={cn(FIELD, 'mb-1.5 resize-none font-mono')}
      />
      <Btn primary onClick={() => api('/v1/script', { method: 'POST', body: v }).catch(() => {})}>
        Run
      </Btn>
    </Card>
  )
}

function RespringCard() {
  return (
    <Card title="Device">
      <Btn
        onClick={() => {
          if (confirm('Respring the device?')) api('/v1/respring', { method: 'POST' }).catch(() => {})
        }}
      >
        Respring
      </Btn>
    </Card>
  )
}
