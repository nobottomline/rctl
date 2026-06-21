import { useEffect, useRef, useState, type RefObject } from 'react'
import { ControlEngine, codeToUsage, MOD_USAGES, type DiagStats, type MacroEvent } from '../lib/engine'
import { AudioPlayer } from '../lib/audio'
import { FileTransfer } from '../lib/files'
import { api, apiJSON } from '../lib/rctl'

// Wires the imperative ControlEngine to React: creates it against the stage +
// canvas elements, attaches pointer/keyboard input + window resize, and surfaces
// status/orientation + action callbacks. All the delicate behavior lives in the
// engine; this hook is just the React lifecycle + DOM event plumbing.
export function useControl(
  stageRef: RefObject<HTMLDivElement | null>,
  canvasRef: RefObject<HTMLCanvasElement | null>,
) {
  const [status, setStatus] = useState('connecting…')
  const [orient, setOrient] = useState<{ o: number; manual: boolean }>({ o: 1, manual: false })
  const [stats, setStats] = useState<DiagStats | null>(null)
  const [statsOn, setStatsOn] = useState(false)
  const engineRef = useRef<ControlEngine | null>(null)
  const audioRef = useRef(new AudioPlayer())
  const filesRef = useRef(new FileTransfer())
  const [listening, setListening] = useState(false)
  const [audioBusy, setAudioBusy] = useState(false)
  const [deviceSpeaker, setDeviceSpeaker] = useState(true)
  const [brightness, setBrightness] = useState(0.5)
  const brBusy = useRef(false)
  const brPend = useRef<number | null>(null)
  const [recMode, setRecMode] = useState<'idle' | 'recording' | 'paused' | 'playing'>('idle')
  const [macroLen, setMacroLen] = useState(0)
  const macroRef = useRef<MacroEvent[]>([])

  useEffect(() => {
    const stage = stageRef.current
    const canvas = canvasRef.current
    if (!stage || !canvas) return

    const video = document.createElement('video')
    const engine = new ControlEngine(stage, canvas, video, {
      onStatus: setStatus,
      onOrient: (o, manual) => setOrient({ o, manual }),
      onAudioChannel: (ch) => audioRef.current.attach(ch),
      onFilesChannel: (ch) => filesRef.current.attach(ch),
    })
    engineRef.current = engine
    engine.start()

    // ---- multitouch: each active pointer (finger) gets its own index 0..10 ----
    const ptrs = new Map<number, { finger: number; lastMove: number }>()
    const allocFinger = () => {
      const used = new Set<number>()
      ptrs.forEach((p) => used.add(p.finger))
      for (let i = 0; i < 11; i++) if (!used.has(i)) return i
      return 0
    }
    const onDown = (e: PointerEvent) => {
      const f = allocFinger()
      ptrs.set(e.pointerId, { finger: f, lastMove: 0 })
      try {
        stage.setPointerCapture(e.pointerId)
      } catch {
        /* ignore */
      }
      engine.sendTouchAt(0, e.clientX, e.clientY, f)
      e.preventDefault()
    }
    const onMove = (e: PointerEvent) => {
      const p = ptrs.get(e.pointerId)
      if (!p) return
      const now = performance.now()
      if (now - p.lastMove < 16) return // ~60fps cap, mirrors the vanilla page
      p.lastMove = now
      engine.sendTouchAt(1, e.clientX, e.clientY, p.finger)
      e.preventDefault()
    }
    const onUp = (e: PointerEvent) => {
      const p = ptrs.get(e.pointerId)
      if (!p) return
      ptrs.delete(e.pointerId)
      engine.sendTouchAt(2, e.clientX, e.clientY, p.finger)
      e.preventDefault()
    }
    stage.addEventListener('pointerdown', onDown)
    stage.addEventListener('pointermove', onMove)
    stage.addEventListener('pointerup', onUp)
    stage.addEventListener('pointercancel', onUp)

    // ---- keyboard: forward physical keystrokes (skip Console form fields) ----
    const inField = (t: EventTarget | null) => {
      const tag = (t as HTMLElement | null)?.tagName
      return tag === 'INPUT' || tag === 'TEXTAREA'
    }
    const onKeyDown = (e: KeyboardEvent) => {
      if (inField(e.target)) return
      const u = codeToUsage(e.code)
      if (!u) return
      e.preventDefault()
      // Modifiers held; regular keys as one atomic tap (d=2) so a lost release
      // can't trigger iOS auto-repeat.
      if (MOD_USAGES.has(u)) {
        if (!e.repeat) engine.key(u, 1)
      } else engine.key(u, 2)
    }
    const onKeyUp = (e: KeyboardEvent) => {
      if (inField(e.target)) return
      const u = codeToUsage(e.code)
      if (!u) return
      e.preventDefault()
      if (MOD_USAGES.has(u)) engine.key(u, 0)
    }
    addEventListener('keydown', onKeyDown)
    addEventListener('keyup', onKeyUp)

    const onResize = () => engine.applyOrient()
    addEventListener('resize', onResize)

    return () => {
      engine.stop()
      stage.removeEventListener('pointerdown', onDown)
      stage.removeEventListener('pointermove', onMove)
      stage.removeEventListener('pointerup', onUp)
      stage.removeEventListener('pointercancel', onUp)
      removeEventListener('keydown', onKeyDown)
      removeEventListener('keyup', onKeyUp)
      removeEventListener('resize', onResize)
      try {
        video.remove()
      } catch {
        /* ignore */
      }
      engineRef.current = null
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [])

  // Diagnostics poll: only while the overlay is open, so there's zero cost in
  // normal use. getStats is cheap; 1s cadence keeps the numbers readable.
  useEffect(() => {
    if (!statsOn) {
      setStats(null)
      return
    }
    let alive = true
    const tick = async () => {
      const s = await engineRef.current?.sampleStats()
      if (alive && s) setStats(s)
    }
    tick()
    const id = window.setInterval(tick, 1000)
    return () => {
      alive = false
      clearInterval(id)
    }
  }, [statsOn])

  // Brightness: read the device's current backlight once, then set it (coalescing
  // while a request is in flight so dragging the slider can't flood rctld).
  useEffect(() => {
    apiJSON<{ brightness?: number }>('/v1/deviceinfo').then((j) => {
      if (j && typeof j.brightness === 'number') setBrightness(j.brightness)
    })
  }, [])
  const sendBr = (v: number) => {
    if (brBusy.current) {
      brPend.current = v
      return
    }
    brBusy.current = true
    api(`/v1/brightness?v=${v.toFixed(3)}`)
      .catch(() => {})
      .finally(() => {
        brBusy.current = false
        if (brPend.current != null) {
          const p = brPend.current
          brPend.current = null
          sendBr(p)
        }
      })
  }
  const changeBrightness = (v: number) => {
    setBrightness(v)
    sendBr(v)
  }

  // Record / replay a touch+key macro (captured in the engine's input layer) as a
  // small state machine: idle · recording · paused · playing.
  const startRecord = () => {
    const eng = engineRef.current
    if (!eng) return
    eng.recordStart() // cancels any in-flight playback internally
    setMacroLen(0)
    setRecMode('recording')
  }
  const pauseRecord = () => {
    engineRef.current?.recordPause()
    setRecMode('paused')
  }
  const resumeRecord = () => {
    engineRef.current?.recordResume()
    setRecMode('recording')
  }
  const stopRecord = () => {
    const eng = engineRef.current
    if (!eng) return
    const m = eng.recordStop()
    macroRef.current = m
    setMacroLen(m.length)
    setRecMode('idle')
  }
  const playMacro = async () => {
    const eng = engineRef.current
    if (!eng || !macroRef.current.length) return
    setRecMode('playing')
    await eng.play(macroRef.current)
    // only fall back to idle if we're still the active playback (a fresh record
    // may have taken over and switched the mode)
    setRecMode((m) => (m === 'playing' ? 'idle' : m))
  }
  const stopPlay = () => engineRef.current?.stopPlay()

  // Best-quality screenshot: a full-res lossless PNG straight from the device's
  // capture surface (/v1/screenshot). Falls back to the local <video> frame
  // (downscaled + H.264, the stream's quality) only if the device can't oblige.
  const captureScreenshot = async () => {
    try {
      const r = await api('/v1/screenshot')
      if (r.ok) {
        const b = await r.blob()
        const u = URL.createObjectURL(b)
        const a = document.createElement('a')
        a.href = u
        a.download = `rctl-${Date.now()}.png`
        a.click()
        setTimeout(() => URL.revokeObjectURL(u), 1500)
        return
      }
    } catch {
      /* fall through to the local capture */
    }
    engineRef.current?.screenshot()
  }

  // Listen toggle: start browser playback (needs this user gesture to unblock
  // autoplay) AND tell the device to begin capturing + sending Opus. Either part
  // failing reverts the whole toggle so the UI never lies about being live.
  const toggleListen = async () => {
    if (audioBusy) return
    setAudioBusy(true)
    const next = !listening
    try {
      if (next && !(await audioRef.current.resume())) throw new Error('audioctx')
      const r = await api(`/v1/audio_capture?on=${next ? 1 : 0}`)
      if (!r.ok) throw new Error('capture')
      if (!next) audioRef.current.mute()
      setListening(next)
    } catch {
      audioRef.current.mute()
      setListening(false)
    } finally {
      setAudioBusy(false)
    }
  }

  // Mute/unmute the iPad's own speaker (capture happens before output, so browser
  // playback keeps working with the device silent).
  const toggleSpeaker = async () => {
    try {
      const next = !deviceSpeaker
      const r = await api(`/v1/audio_output?device=${next ? 1 : 0}`)
      if (!r.ok) return
      const j = (await r.json()) as { device?: boolean }
      setDeviceSpeaker(!!j.device)
    } catch {
      /* ignore */
    }
  }

  return {
    status,
    orient,
    stats,
    statsOn,
    audio: { listening, busy: audioBusy, deviceSpeaker, toggleListen, toggleSpeaker },
    brightness,
    setBrightness: changeBrightness,
    filesTransfer: filesRef.current,
    toggleStats: () => setStatsOn((v) => !v),
    setQuality: (scale: number, fps: number, bitrate: number) =>
      engineRef.current?.setQuality(scale, fps, bitrate),
    screenshot: captureScreenshot,
    record: {
      mode: recMode,
      count: macroLen,
      start: startRecord,
      pause: pauseRecord,
      resume: resumeRecord,
      stop: stopRecord,
      play: playMacro,
      stopPlay,
    },
    sysPress: (n: string) => engineRef.current?.sysPress(n),
    springboard: (u: number) => engineRef.current?.springboard(u),
    rotate: () => engineRef.current?.rotate(),
    setAuto: () => engineRef.current?.setAutoOrient(),
  }
}
