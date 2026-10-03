import { useEffect, useRef, useState } from 'react'
import { ControlEngine, codeToUsage } from './lib/engine'
import { GUEST_ACCESS, guestHas, guestButtonHas, type GuestAccess } from './lib/rctl'
import { GUEST_PERMISSIONS } from './lib/guestPermissions.generated'
import './guest.css'

// This entry point does not mount owner panels or their privileged API effects.
export default function GuestControl() {
  const access = GUEST_ACCESS!
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

  useEffect(() => {
    const held = new Set<number>()
    const touches = new Map<number, { finger: number; x: number; y: number }>()
    let stopped = false
    const control = new ControlEngine(stage.current!, canvas.current!, video.current!, {
      onStatus: (text) => setStatus(text || 'Connected'),
      onEnded: () => end(),
      onInputBlocked: () => { setInputBlocked(true); setKeyboard(false) },
    })
    engine.current = control
    const end = () => {
      if (stopped) return
      stopped = true
      abort.abort()
      clearTimeout(deadline)
      clearInterval(clock)
      control.stop()
      setEnded(true)
      setKeyboard(false)
      setStatus('Session disconnected')
    }
    const release = () => {
      for (const usage of held) control.key(usage, 0)
      held.clear()
      for (const contact of touches.values()) control.sendTouchAt(2, contact.x, contact.y, contact.finger)
      touches.clear()
    }
    const surface = stage.current!
    const down = (event: PointerEvent) => {
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
      setNow(Date.now())
      if (stopped || pending) return
      pending = true
      const timeout = window.setTimeout(end, 4000)
      try {
        const response = await fetch('/api/guest/session', { cache: 'no-store', signal: abort.signal })
        if (!response.ok) { end(); return }
        const current = await response.json() as GuestAccess
        if (current.session_id !== access.session_id || current.authorization_revision !== access.authorization_revision) end()
      } catch { if (!abort.signal.aborted) end() }
      finally { clearTimeout(timeout); pending = false }
    }, 5000)
    endSession.current = end
    control.start()
    return () => {
      stopped = true
      abort.abort()
      clearTimeout(deadline); clearInterval(clock)
      release(); control.stop()
      surface.removeEventListener('pointerdown', down)
      surface.removeEventListener('pointermove', move)
      surface.removeEventListener('pointerup', up)
      surface.removeEventListener('pointercancel', up)
      surface.removeEventListener('lostpointercapture', up)
      window.removeEventListener('blur', release)
      document.removeEventListener('visibilitychange', visibility)
      if (engine.current === control) engine.current = null
      if (endSession.current === end) endSession.current = null
    }
  }, [access])

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
  return <main className="guest-control">
    <div ref={stage} className="guest-stage" aria-label="Device screen" tabIndex={guestHas('input.keyboard') ? 0 : undefined} style={{ touchAction: guestHas('input.touch') ? 'none' : 'auto' }}>
      <canvas ref={canvas} /><video ref={video} />
    </div>
    <aside className="guest-toolbar" aria-label="Temporary device access">
      <div><strong>{access.label}</strong><span role="status">{status} · {Math.floor(seconds / 60)}:{String(seconds % 60).padStart(2, '0')} remaining</span></div>
      <details><summary>{access.permissions.length > 1 ? 'Permitted actions' : 'View only'} · {access.permissions.length}</summary>
        <ul>{GUEST_PERMISSIONS.filter((p) => access.permissions.includes(p.id)).map((p) => <li key={p.id}>{p.label}</li>)}</ul>
      </details>
      {!ended && <div className="guest-actions">
        <button onClick={() => engine.current?.rotate()}>Rotate view</button>
        {!inputBlocked && guestHas('input.keyboard') && <><button aria-pressed={keyboard} onClick={() => {
          setKeyboard(!keyboard)
          if (!keyboard) stage.current?.focus()
        }}>{keyboard ? 'Release keyboard (Esc)' : 'Use keyboard'}</button><button onClick={() => engine.current?.key(0x29, 2)}>Send Escape</button></>}
        {!inputBlocked && <>{(['home', 'lock', 'volup', 'voldn'] as const).filter(guestButtonHas).map((key) => <button key={key} onClick={() => engine.current?.sysPress(key)}>{({ home: 'Home', lock: 'Lock', volup: 'Volume +', voldn: 'Volume −' })[key]}</button>)}
          {guestHas('input.button.system_ui') && <><button onClick={() => engine.current?.springboard(1)}>Control Center</button><button onClick={() => engine.current?.springboard(2)}>Notifications</button></>}</>}
      </div>}
      {ended && <p>The connection is closed. To continue with current permissions, <a href="/guest/control">connect again</a>.</p>}
      <button disabled={leaving} onClick={() => void leave()}>{leaving ? 'Ending access…' : 'End my access'}</button>
      {error && <p role="alert">{error}</p>}
    </aside>
  </main>
}
