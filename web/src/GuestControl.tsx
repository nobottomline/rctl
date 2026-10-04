import { useEffect, useRef, useState } from 'react'
import { Boxes, Camera, ChevronDown, Clock3, FolderOpen, House, Images, Keyboard, Lock, LogOut, Moon, RotateCw, Settings2, ShieldCheck, SlidersHorizontal, SquareTerminal, Sun, Volume1, Volume2, Wand2, Headphones } from 'lucide-react'
import { Sheet } from './components/Sheet'
import { applyTheme, getStoredTheme, type Theme } from './lib/theme'
import { guestEndState, guestTime, guestTools, type GuestTool } from './lib/guestNavigation'
import { ControlEngine, codeToUsage } from './lib/engine'
import { GUEST_ACCESS, guestHas, guestButtonHas, type GuestAccess } from './lib/rctl'
import { GUEST_PERMISSIONS } from './lib/guestPermissions.generated'
import './guest.css'
import GuestWorkspace from './components/GuestWorkspace'
import { GuestOperations } from './lib/guestOperations'
import { AudioPlayer } from './lib/audio'
import { MicTalk } from './lib/mic'

// This entry point does not mount owner panels or their privileged API effects.
export default function GuestControl() {
  const access = GUEST_ACCESS!
  const [operations] = useState(() => new GuestOperations())
  const [audio] = useState(() => new AudioPlayer())
  const [microphone] = useState(() => new AudioPlayer(2))
  const [talk] = useState(() => new MicTalk())
  const [toolsReady, setToolsReady] = useState(false)
  const stage = useRef<HTMLDivElement>(null)
  const canvas = useRef<HTMLCanvasElement>(null)
  const video = useRef<HTMLVideoElement>(null)
  const engine = useRef<ControlEngine | null>(null)
  const endSession = useRef<(() => void) | null>(null)
  const [status, setStatus] = useState('Connecting…')
  const [ended, setEnded] = useState(false)
  const [inputBlocked, setInputBlocked] = useState(false)
  const [now, setNow] = useState(Date.now())
  const [error, setError] = useState('')
  const [leaving, setLeaving] = useState(false)
  const [keyboard, setKeyboard] = useState(false)
  const tools = guestTools(access.permissions)
  const [controlsExpanded, setControlsExpanded] = useState(false)
  const [view, setView] = useState<GuestTool | 'access' | null>(() => guestHas('screen.view') ? null : tools[0]?.id ?? 'access')
  const [theme, setTheme] = useState<Theme>(getStoredTheme)
  const [activities, setActivities] = useState<string[]>([])
  const panel = useRef<HTMLDivElement>(null)
  const controlsButton = useRef<HTMLButtonElement>(null)
  const activeTool = tools.find(tool => tool.id === view)

  useEffect(() => {
    const nav = panel.current?.querySelector<HTMLElement>('.guest-tool-nav')
    if (!view || !nav || ended) return
    const reveal = () => nav.querySelector<HTMLElement>('[aria-current]')?.scrollIntoView({ block: 'nearest', inline: 'center' })
    reveal()
    const observer = new ResizeObserver(reveal)
    observer.observe(nav)
    return () => observer.disconnect()
  }, [view, ended])

  useEffect(() => {
    if (!view || ended) return
    setKeyboard(false)
    const previous = document.activeElement
    panel.current?.querySelector<HTMLElement>('[data-panel-title]')?.focus()
    return () => {
      if (previous instanceof HTMLElement && previous !== document.body && previous.isConnected && previous.getClientRects().length) previous.focus()
      else controlsButton.current?.focus()
    }
  }, [view, ended])

  const show = (next: GuestTool | 'access') => { setView(next); setControlsExpanded(false) }
  const toggleTheme = () => {
    const next = theme === 'dark' ? 'warm' : 'dark'
    applyTheme(next); setTheme(next)
  }


  // Keep expiry presentation current after transport teardown without polling
  // the network or retaining a per-second clock for a disconnected session.
  useEffect(() => {
    const refresh = () => setNow(Date.now())
    if (ended) {
      const deadline = window.setTimeout(refresh, Math.max(0, access.expires_at * 1000 - Date.now()) + 1)
      return () => clearTimeout(deadline)
    }
    const clock = window.setInterval(refresh, 1000)
    return () => clearInterval(clock)
  }, [ended, access.expires_at])

  useEffect(() => {
    const held = new Set<number>()
    const touches = new Map<number, { finger: number; x: number; y: number }>()
    const closedCheck = new AbortController()
    let stopped = false
    const control = new ControlEngine(stage.current!, canvas.current!, video.current!, {
      onGuestOperations: (channel) => operations.attach(channel),
      onAudioChannel: (channel) => audio.attach(channel),
      onRoomMicChannel: (channel) => microphone.attach(channel),
      onMicChannel: (channel) => talk.attach(channel),
      onStatus: (text) => setStatus(text || 'Connected'),
      onEnded: (reason) => end(reason),
      onInputBlocked: () => { setInputBlocked(true); setKeyboard(false) },
    })
    operations.onReady = setToolsReady
    engine.current = control
    const end = (reason?: string, kind?: 'Access ended' | 'Permissions changed') => {
      if (!reason && !kind) closedCheck.abort()
      if (stopped) return
      stopped = true
      abort.abort()
      clearTimeout(deadline)
      clearInterval(clock)
      operations.stop(); audio.dispose(); microphone.dispose(); talk.dispose()
      control.stop()
      setEnded(true)
      setKeyboard(false)
      const endedAt = Date.now()
      setNow(endedAt)
      setStatus(endedAt >= access.expires_at * 1000 ? 'Access expired' : kind ?? 'Session disconnected')
      if (kind) setError('')
      else if (reason) setError(reason.includes('signaling connection') ? 'The relay connection was interrupted.' : reason)
      // Authority and resources are already retired. This bounded, read-only
      // check only explains the closure; it never renews or resumes a lease.
      if (reason && !kind && endedAt < access.expires_at * 1000) {
        const timeout = window.setTimeout(() => closedCheck.abort(), 4000)
        void fetch('/api/guest/session', { cache: 'no-store', signal: closedCheck.signal }).then(async response => {
          if (!response.ok && response.status !== 401 && response.status !== 403) return
          const current = response.ok ? await response.json() as GuestAccess : null
          if (closedCheck.signal.aborted) return
          const next = guestEndState(access, current)
          setStatus(next)
          if (next !== 'Session disconnected') setError('')
        }).catch(() => {}).finally(() => clearTimeout(timeout))
      }
    }
    const release = () => {
      for (const usage of held) control.key(usage, 0)
      held.clear()
      for (const contact of touches.values()) control.sendTouchAt(2, contact.x, contact.y, contact.finger)
      touches.clear()
    }
    const surface = stage.current!
    const down = (event: PointerEvent) => {
      setControlsExpanded(false)
      if (!guestHas('input.touch') || stopped || touches.size >= 10 || touches.has(event.pointerId)) return
      const finger = Array.from({ length: 10 }, (_, i) => i).find((i) => ![...touches.values()].some((p) => p.finger === i))!
      const contact = { finger, x: event.clientX, y: event.clientY }
      touches.set(event.pointerId, contact)
      surface.setPointerCapture(event.pointerId)
      control.sendTouchAt(0, contact.x, contact.y, finger)
      event.preventDefault()
    }
    const move = (event: PointerEvent) => {
      const contact = touches.get(event.pointerId)
      if (!contact) return
      contact.x = event.clientX; contact.y = event.clientY
      control.sendTouchAt(1, contact.x, contact.y, contact.finger)
    }
    const up = (event: PointerEvent) => {
      const contact = touches.get(event.pointerId)
      if (!contact) return
      control.sendTouchAt(2, contact.x, contact.y, contact.finger)
      touches.delete(event.pointerId)
    }
    surface.addEventListener('pointerdown', down)
    surface.addEventListener('pointermove', move)
    surface.addEventListener('pointerup', up)
    surface.addEventListener('pointercancel', up)
    surface.addEventListener('lostpointercapture', up)
    window.addEventListener('blur', release)
    const visibility = () => { if (document.hidden) release() }
    document.addEventListener('visibilitychange', visibility)
    const deadline = window.setTimeout(end, Math.max(0, access.expires_at * 1000 - Date.now()))
    // Hard deadline and a current-revision check supplement signaling closure.
    const abort = new AbortController()
    let pending = false
    const clock = window.setInterval(async () => {
      if (stopped || pending) return
      pending = true
      const timeout = window.setTimeout(end, 4000)
      try {
        const response = await fetch('/api/guest/session', { cache: 'no-store', signal: abort.signal })
        if (!response.ok) { end(undefined, response.status === 401 || response.status === 403 ? 'Access ended' : undefined); return }
        const current = await response.json() as GuestAccess
        if (current.session_id !== access.session_id || current.authorization_revision !== access.authorization_revision) end(undefined, current.session_id !== access.session_id ? 'Access ended' : 'Permissions changed')
      } catch { if (!abort.signal.aborted) end() }
      finally { clearTimeout(timeout); pending = false }
    }, 5000)
    endSession.current = end
    control.start()
    return () => {
      stopped = true
      closedCheck.abort()
      abort.abort()
      clearTimeout(deadline); clearInterval(clock)
      release(); operations.stop(); audio.mute(); microphone.mute(); talk.stop(); control.stop()
      surface.removeEventListener('pointerdown', down)
      surface.removeEventListener('pointermove', move)
      surface.removeEventListener('pointerup', up)
      surface.removeEventListener('pointercancel', up)
      surface.removeEventListener('lostpointercapture', up)
      window.removeEventListener('blur', release)
      document.removeEventListener('visibilitychange', visibility)
      if (engine.current === control) engine.current = null
      window.setTimeout(() => { if (!engine.current) { audio.dispose(); microphone.dispose(); talk.dispose() } }, 0)
      if (endSession.current === end) endSession.current = null
    }
  }, [access, operations, audio, microphone, talk])

  useEffect(() => {
    if (!keyboard || ended || !guestHas('input.keyboard')) return
    const held = new Set<number>()
    const key = (event: KeyboardEvent, down: number) => {
      if (event.target instanceof Element && event.target.closest('button, a, input, textarea, select, summary, [contenteditable="true"]')) return
      if (event.code === 'Escape') {
        if (down === 1) { event.preventDefault(); setKeyboard(false) }
        return
      }
      const usage = codeToUsage(event.code)
      if (!usage) return
      if (down === 1) held.add(usage)
      else held.delete(usage)
      event.preventDefault()
      engine.current?.key(usage, down)
    }
    const down = (event: KeyboardEvent) => { if (!event.repeat) key(event, 1) }
    const up = (event: KeyboardEvent) => key(event, 0)
    const release = () => { for (const usage of held) engine.current?.key(usage, 0); held.clear() }
    const visibility = () => { if (document.hidden) release() }
    document.addEventListener('visibilitychange', visibility)
    window.addEventListener('keydown', down); window.addEventListener('keyup', up); window.addEventListener('blur', release)
    return () => { release(); document.removeEventListener('visibilitychange', visibility); window.removeEventListener('keydown', down); window.removeEventListener('keyup', up); window.removeEventListener('blur', release) }
  }, [keyboard, ended])

  async function leave() {
    endSession.current?.(); setLeaving(true); setError('')
    const abort = new AbortController()
    const timeout = window.setTimeout(() => abort.abort(), 6000)
    try {
      const response = await fetch('/api/guest/session/end', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: '{}', signal: abort.signal })
      if (!response.ok && response.status !== 401) throw new Error('Could not confirm sign out. Please retry.')
      setStatus('Access ended')
    } catch { setError('The connection is closed here, but sign out could not be confirmed. Retry to end access in other tabs.') }
    finally { clearTimeout(timeout); setLeaving(false) }
  }
  const seconds = Math.max(0, Math.ceil((access.expires_at * 1000 - now) / 1000))
  const toolIcons = { console: Wand2, sound: Headphones, camera: Camera, media: Images, files: FolderOpen, system: Boxes, terminal: SquareTerminal }
  const screen = guestHas('screen.view')
  const viewOnly = access.permissions.length === 1 && screen
  const closePanel = () => setView(null)
  const trapPanel = (event: React.KeyboardEvent<HTMLDivElement>) => {
    if (event.key === 'Escape') { event.preventDefault(); event.stopPropagation(); closePanel(); return }
    if (event.key !== 'Tab') return
    const elements = [...event.currentTarget.querySelectorAll<HTMLElement>('button:not(:disabled), a[href], input:not(:disabled), select:not(:disabled), textarea:not(:disabled), summary, [tabindex="0"]')].filter(element => element.getClientRects().length > 0)
    if (!elements.length) return
    const first = elements[0], last = elements[elements.length - 1]
    if (event.shiftKey && (document.activeElement === first || !elements.includes(document.activeElement as HTMLElement))) { event.preventDefault(); last.focus() }
    else if (!event.shiftKey && (document.activeElement === last || !elements.includes(document.activeElement as HTMLElement))) { event.preventDefault(); first.focus() }
  }
  const panelTitle = <h2 id="guest-panel-title" data-panel-title tabIndex={-1}>{view === 'access' ? 'Your access' : activeTool?.label}</h2>
  return <main className={`guest-control${screen ? '' : ' guest-tools-only'}`}>
    <div ref={stage} className="guest-stage" aria-label="Device screen" tabIndex={guestHas('input.keyboard') ? 0 : undefined} style={{ touchAction: guestHas('input.touch') ? 'none' : 'auto' }}>
      <canvas ref={canvas} /><video ref={video} />
    </div>
    <header className="guest-hud">
      <button className="guest-session" onClick={() => !ended && show('access')} disabled={ended} aria-label="View access permissions">
        <ShieldCheck size={16} aria-hidden="true" />
        <span className="guest-session-name">{access.label}</span>
        {viewOnly && <span className="guest-mode">View only</span>}
      </button>
      <div className="guest-connection" role="status"><i className={ended ? 'is-ended' : status === 'Connected' ? 'is-live' : ''} />{seconds === 0 ? 'Access expired' : status}</div>
      {!ended && <div className="guest-clock" title="Access time remaining"><Clock3 size={13} aria-hidden="true" /><span>{guestTime(seconds)}</span></div>}
      {!ended && keyboard && <span className="guest-mode">Keyboard captured · Esc to release</span>}
      {!ended && activities.length > 0 && <span className="guest-activity" title={activities.join(' · ')}>{activities.join(' · ')}</span>}
    </header>

    {!ended && !screen && !view && <section className="guest-empty"><ShieldCheck size={28} /><h1>Shared device tools</h1><p>The owner has shared {tools.length ? 'the tools below' : 'limited access'}. Choose an available tool to continue.</p><div className="guest-launchers">{tools.map(tool => { const Icon = toolIcons[tool.id]; return <button key={tool.id} onClick={() => show(tool.id)}><Icon size={20} />{tool.label}</button> })}</div><button onClick={() => show('access')}>View permissions</button></section>}

    {!ended && <>
      <button ref={controlsButton} className={`guest-controls-button${controlsExpanded ? ' is-active' : ''}`} aria-label="Controls" aria-expanded={controlsExpanded} aria-controls="guest-controls" onClick={() => { setView(null); setControlsExpanded(!controlsExpanded) }}><Settings2 size={20} /></button>
      <aside id="guest-controls" className="guest-control-center" hidden={!controlsExpanded} aria-label="Guest controls">
        <header><strong>Control</strong><button className="guest-icon-button" onClick={toggleTheme} aria-label="Change theme">{theme === 'dark' ? <Sun size={16} /> : <Moon size={16} />}</button></header>
        {!inputBlocked && access.permissions.some(right => right.startsWith('input.button.')) && <section><h3>Device</h3><div className="guest-quick-grid">
          {(['home', 'lock', 'volup', 'voldn'] as const).filter(guestButtonHas).map(key => { const Icon = { home: House, lock: Lock, volup: Volume2, voldn: Volume1 }[key]; return <button key={key} onClick={() => engine.current?.sysPress(key)}><Icon size={15} />{({ home: 'Home', lock: 'Lock', volup: 'Volume +', voldn: 'Volume −' })[key]}</button> })}
          {guestHas('input.button.system_ui') && <><button onClick={() => engine.current?.springboard(1)}><SlidersHorizontal size={15} />Control Center</button><button onClick={() => engine.current?.springboard(2)}><ChevronDown size={15} />Notifications</button></>}
        </div></section>}
        {!inputBlocked && guestHas('input.keyboard') && <section><h3>Keyboard</h3><div className="guest-quick-grid"><button aria-pressed={keyboard} onClick={() => { setKeyboard(!keyboard); if (!keyboard) stage.current?.focus() }}><Keyboard size={15} />{keyboard ? 'Release · Esc' : 'Use keyboard'}</button><button onClick={() => engine.current?.key(0x29, 2)}>Send Escape</button></div></section>}
        {screen && <section><h3>Display</h3><button className="guest-wide-action" onClick={() => engine.current?.rotate()}><RotateCw size={15} />Rotate view</button></section>}
        {tools.length > 0 && <section><h3>Tools</h3><div className="guest-launchers">{tools.map(tool => { const Icon = toolIcons[tool.id]; return <button key={tool.id} title={tool.description} onClick={() => show(tool.id)}><Icon size={19} />{tool.label}</button> })}</div></section>}
        <footer><button onClick={() => show('access')}><ShieldCheck size={14} />Permissions</button><button className="guest-end-button" disabled={leaving} onClick={() => void leave()}><LogOut size={14} />End access</button></footer>
      </aside>
      <div ref={panel} hidden={!view} role="dialog" aria-modal={view ? true : undefined} aria-labelledby="guest-panel-title" onKeyDown={trapPanel}>
        <Sheet title={panelTitle} onClose={closePanel} wide={view !== 'access'} toolbar={view !== 'access' && <nav className="guest-tool-nav" aria-label="Permitted tools">{tools.map(tool => { const Icon = toolIcons[tool.id]; return <button key={tool.id} aria-current={view === tool.id ? 'page' : undefined} onClick={() => show(tool.id)}><Icon size={15} />{tool.label}</button> })}</nav>}>
          {view === 'access' && <section className="guest-access-panel"><div className="guest-access-heading"><ShieldCheck size={24} /><div><h3>{access.label}</h3><p>Temporary device access</p></div></div><p>The owner can change permissions or end this session at any time.</p><div className="guest-access-time"><Clock3 size={16} />{guestTime(seconds)} remaining</div>{[...new Set(GUEST_PERMISSIONS.filter(p => access.permissions.includes(p.id)).map(p => p.group))].map(group => <section key={group}><h4>{group}</h4><ul>{GUEST_PERMISSIONS.filter(p => p.group === group && access.permissions.includes(p.id)).map(p => <li key={p.id}>{p.label}</li>)}</ul></section>)}<button className="guest-end-button" disabled={leaving} onClick={() => void leave()}><LogOut size={16} />{leaving ? 'Ending access…' : 'End my access'}</button></section>}
          {tools.length > 0 && <div hidden={view === 'access'}><GuestWorkspace visible={Boolean(activeTool)} section={activeTool?.id ?? tools[0].id} engine={engine} operations={operations} ready={toolsReady} audio={audio} microphone={microphone} talk={talk} onActivity={setActivities} /></div>}
        </Sheet>
      </div>
    </>}
    {ended && <section className="guest-ended" aria-labelledby="guest-ended-title"><ShieldCheck size={28} /><p className="guest-eyebrow">Temporary access</p><h1 id="guest-ended-title">{seconds === 0 ? 'Access expired' : status === 'Access ended' ? 'Access ended' : status === 'Permissions changed' ? 'Permissions changed' : 'Connection closed'}</h1><p>{seconds === 0 || status === 'Access ended' ? 'Ask the owner for a new invitation to connect again.' : status === 'Permissions changed' ? 'The owner changed your permissions. Reconnect to continue with the updated access.' : 'Your screen and device tools have been disconnected. You can reconnect if the owner still allows access.'}</p>{error && seconds > 0 && <p className="guest-error" role="alert">{error}</p>}<div className="guest-ended-actions">{seconds > 0 && status !== 'Access ended' && <button className="guest-primary" onClick={() => window.location.reload()}>Reconnect</button>}{seconds > 0 && status !== 'Access ended' && <button disabled={leaving} onClick={() => void leave()}>{leaving ? 'Ending access…' : 'End my access'}</button>}</div></section>}
  </main>
}
