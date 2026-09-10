import { useEffect, useRef, useState, type RefObject } from 'react'
import { ControlEngine, codeToUsage, type DiagStats, type MacroEvent } from '../lib/engine'
import { KeyboardState } from '../lib/keyboardState'
import { GameKeyboard, validateKeyboardResponse, type GameKeyboardStatus } from '../lib/gameKeyboard'
import { GamePointer, pointerCaptureUnavailable, pointerWheelDelta, type PointerStatus } from '../lib/gamePointer'
import { AudioPlayer } from '../lib/audio'
import { FileTransfer } from '../lib/files'
import { MicTalk, micSupported } from '../lib/mic'
import { api, apiJSON } from '../lib/rctl'
import { macroScript } from '../lib/macroPlayback'

const REC_PATH = '/var/mobile/rctl/mic-recording.m4a'

// Save a Blob to a file. The click -> save is kept synchronous (no async gap) so
// Safari, which only allows downloads inside the user-gesture window, accepts it.
function downloadBlob(blob: Blob, name: string) {
  const u = URL.createObjectURL(blob)
  const a = document.createElement('a')
  a.href = u
  a.download = name
  document.body.appendChild(a)
  a.click()
  a.remove()
  setTimeout(() => URL.revokeObjectURL(u), 2000)
}

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
  const gameKeyboardRef = useRef<GameKeyboard | null>(null)
  const textKeyboardRef = useRef<KeyboardState | null>(null)
  const [keyboardStatus, setKeyboardStatus] = useState<GameKeyboardStatus>({ mode: 'text' })
  const gamePointerRef = useRef<GamePointer | null>(null)
  const [pointerStatus, setPointerStatus] = useState<PointerStatus>({ mode: 'idle', available: false })
  const audioRef = useRef(new AudioPlayer())
  const filesRef = useRef(new FileTransfer())
  const micRef = useRef(new MicTalk())
  const roomMicRef = useRef(new AudioPlayer(3)) // the iPad's own mic, run a bit louder (raw input is quiet)
  const [talking, setTalking] = useState(false)
  const [talkMode, setTalkMode] = useState<'speaker' | 'mic' | 'both'>('speaker')
  const [listeningMic, setListeningMic] = useState(false)
  const [micRec, setMicRec] = useState({ recording: false, seconds: 0, bytes: 0 })
  const recBlob = useRef<{ bytes: number; blob: Blob } | null>(null) // the fetched .m4a, cached for instant re-save
  const [savingRec, setSavingRec] = useState(false)
  const [micRecordError, setMicRecordError] = useState('')
  const [micRecordBusy, setMicRecordBusy] = useState(false)
  const micMutation = useRef(false)
  const [listening, setListening] = useState(false)
  const [audioBusy, setAudioBusy] = useState(false)
  const [deviceSpeaker, setDeviceSpeaker] = useState(true)
  const [brightness, setBrightness] = useState(0.5)
  const brBusy = useRef(false)
  const brPend = useRef<number | null>(null)
  const [recMode, setRecMode] = useState<'idle' | 'recording' | 'paused' | 'playing' | 'pausing' | 'play-paused'>('idle')
  const [macroLen, setMacroLen] = useState(0)
  const macroRef = useRef<MacroEvent[]>([])

  useEffect(() => {
    apiJSON<{ mode?: 'speaker' | 'mic' | 'both' }>('/v1/talk_route').then((response) => {
      if (response?.mode) setTalkMode(response.mode)
    })
  }, [])

  const changeTalkMode = async (mode: 'speaker' | 'mic' | 'both') => {
    const response = await apiJSON<{ mode?: 'speaker' | 'mic' | 'both' }>(`/v1/talk_route?mode=${mode}`)
    if (response?.mode) setTalkMode(response.mode)
  }

  useEffect(() => {
    const stage = stageRef.current
    const canvas = canvasRef.current
    if (!stage || !canvas) return

    const pointer = new GamePointer(status => {
      setPointerStatus(status)
      if ((status.mode === 'idle' || status.mode === 'error') && document.pointerLockElement === stage) document.exitPointerLock()
    })
    gamePointerRef.current = pointer

    const video = document.createElement('video')
    const engine = new ControlEngine(stage, canvas, video, {
      onStatus: setStatus,
      onOrient: (o, manual) => setOrient({ o, manual }),
      onAudioChannel: (ch) => audioRef.current.attach(ch),
      onFilesChannel: (ch) => filesRef.current.attach(ch),
      onMicChannel: (ch) => micRef.current.attach(ch),
      onRoomMicChannel: (ch) => roomMicRef.current.attach(ch),
      onPointerChannel: (ch) => pointer.attach(ch),
    })
    micRef.current.onState = setTalking
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
      stage.focus({ preventScroll: true })
      if (document.pointerLockElement === stage) return
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
      if (document.pointerLockElement === stage) return
      const p = ptrs.get(e.pointerId)
      if (!p) return
      const now = performance.now()
      if (now - p.lastMove < 16) return // ~60fps cap, mirrors the vanilla page
      p.lastMove = now
      engine.sendTouchAt(1, e.clientX, e.clientY, p.finger)
      e.preventDefault()
    }
    const onUp = (e: PointerEvent) => {
      if (document.pointerLockElement === stage) return
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

    const onMouseMove = (e: MouseEvent) => {
      if (document.pointerLockElement === stage) pointer.move(e.movementX, e.movementY)
    }
    // Pointer Events only emit down/up for the first/last held mouse button.
    // Mouse Events preserve each transition in left+right button combinations.
    const onMouseDown = (e: MouseEvent) => {
      if (document.pointerLockElement === stage) { pointer.button(e.button, true); e.preventDefault() }
    }
    const onMouseUp = (e: MouseEvent) => {
      if (document.pointerLockElement === stage) { pointer.button(e.button, false); e.preventDefault() }
    }
    const onWheel = (e: WheelEvent) => {
      if (document.pointerLockElement !== stage) return
      e.preventDefault()
      pointer.move(0, 0, pointerWheelDelta(e.deltaY, e.deltaMode))
    }
    const onContextMenu = (e: Event) => { if (document.pointerLockElement === stage) e.preventDefault() }
    const onPointerLock = () => {
      if (document.pointerLockElement === stage) {
        for (const [id, p] of ptrs) {
          engine.sendTouchAt(2, 0, 0, p.finger)
          try { stage.releasePointerCapture(id) } catch { /* pointer already ended */ }
        }
        ptrs.clear()
        stage.focus({ preventScroll: true })
        void pointer.start()
      } else {
        if (pointer.status.mode === 'active' || pointer.status.mode === 'connecting') pointer.stop()
        gameKeyboardRef.current?.releaseKeys()
      }
    }
    const onPointerError = () => pointer.stop('Mouse capture was denied by the browser')
    document.addEventListener('pointerlockchange', onPointerLock)
    document.addEventListener('pointerlockerror', onPointerError)
    document.addEventListener('mousemove', onMouseMove)
    document.addEventListener('mousedown', onMouseDown)
    document.addEventListener('mouseup', onMouseUp)
    stage.addEventListener('wheel', onWheel, { passive: false })
    stage.addEventListener('contextmenu', onContextMenu)

    // ---- keyboard: preserve local form/menu navigation and release on blur ----
    const keyboard = new KeyboardState((usage, down) => engine.key(usage, down))
    textKeyboardRef.current = keyboard
    const gameKeyboard = new GameKeyboard(async (body) => {
      const abort = new AbortController()
      const timeout = setTimeout(() => abort.abort(), 1000)
      try {
        const response = await api('/v1/keyboard', {
          method: 'POST', headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify(body), signal: abort.signal, keepalive: body.action === 'release',
        })
        const result: unknown = await response.json()
        validateKeyboardResponse(result, body.action)
        if (!response.ok) throw new Error('keyboard_unavailable')
      } finally { clearTimeout(timeout) }
    }, setKeyboardStatus)
    gameKeyboardRef.current = gameKeyboard
    const inField = (t: EventTarget | null) => {
      return t instanceof HTMLElement && (
        t.isContentEditable || !!t.closest('input, textarea, select, button, a, [role="dialog"], [role="menu"]')
      )
    }
    const onKeyDown = (e: KeyboardEvent) => {
      if (document.pointerLockElement === stage && e.code === 'Escape') return
      if (e.defaultPrevented || e.isComposing || inField(e.target)) return
      const u = codeToUsage(e.code)
      if (!u) return
      e.preventDefault()
      if (gameKeyboard.enabled) gameKeyboard.down(u, e.repeat)
      else keyboard.down(u, e.repeat)
    }
    const onKeyUp = (e: KeyboardEvent) => {
      const u = codeToUsage(e.code)
      if (!u) return
      // A forwarded modifier must be released even when focus has moved to UI.
      const released = gameKeyboard.enabled ? gameKeyboard.up(u) : keyboard.up(u)
      if (released && !inField(e.target)) e.preventDefault()
    }
    const releaseKeys = () => { keyboard.release(); gameKeyboard.releaseKeys(); pointer.stop() }
    const stopKeyboard = () => { keyboard.release(); gameKeyboard.stop(); pointer.stop() }
    const onVisibility = () => { if (document.hidden) stopKeyboard() }
    const onFocus = (e: FocusEvent) => { if (inField(e.target)) releaseKeys() }
    addEventListener('keydown', onKeyDown)
    addEventListener('keyup', onKeyUp)
    addEventListener('blur', releaseKeys)
    addEventListener('pagehide', stopKeyboard)
    addEventListener('focusin', onFocus)
    document.addEventListener('visibilitychange', onVisibility)

    const onResize = () => engine.applyOrient()
    addEventListener('resize', onResize)

    return () => {
      stopKeyboard()
      pointer.detach()
      gamePointerRef.current = null
      engine.stop()
      stage.removeEventListener('pointerdown', onDown)
      stage.removeEventListener('pointermove', onMove)
      stage.removeEventListener('pointerup', onUp)
      stage.removeEventListener('pointercancel', onUp)
      document.removeEventListener('pointerlockchange', onPointerLock)
      document.removeEventListener('pointerlockerror', onPointerError)
      document.removeEventListener('mousemove', onMouseMove)
      document.removeEventListener('mousedown', onMouseDown)
      document.removeEventListener('mouseup', onMouseUp)
      stage.removeEventListener('wheel', onWheel)
      stage.removeEventListener('contextmenu', onContextMenu)
      removeEventListener('keydown', onKeyDown)
      removeEventListener('keyup', onKeyUp)
      removeEventListener('blur', releaseKeys)
      removeEventListener('pagehide', stopKeyboard)
      removeEventListener('focusin', onFocus)
      document.removeEventListener('visibilitychange', onVisibility)
      removeEventListener('resize', onResize)
      try {
        video.remove()
      } catch {
        /* ignore */
      }
      engineRef.current = null
      gameKeyboardRef.current = null
      textKeyboardRef.current = null
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
    gameKeyboardRef.current?.stop()
    gamePointerRef.current?.stop()
    eng.recordStart() // cancels any in-flight playback internally
    setMacroLen(0)
    setRecMode('recording')
  }
  const pauseRecord = () => {
    engineRef.current?.recordPause()
    setRecMode('paused')
  }
  const resumeRecord = () => {
    gameKeyboardRef.current?.stop()
    gamePointerRef.current?.stop()
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
    gameKeyboardRef.current?.stop()
    gamePointerRef.current?.stop()
    setRecMode('playing')
    await eng.play(macroRef.current, (state) => setRecMode((current) =>
      current === 'playing' || current === 'pausing' || current === 'play-paused' ? state : current))
    // only fall back to idle if we're still the active playback (a fresh record
    // may have taken over and switched the mode)
    setRecMode((m) => (m === 'playing' ? 'idle' : m))
  }
  const stopPlay = () => engineRef.current?.stopPlay()

  // Best-quality screenshot: a full-res lossless PNG straight from the device's
  // capture surface (/v1/screenshot). Falls back to the local <video> frame
  // (downscaled + H.264, the stream's quality) only if the device can't oblige.
  const captureScreenshot = async () => {
    const eng = engineRef.current
    if (!eng) throw new Error('Device is not connected.')
    try {
      const r = await api('/v1/screenshot')
      if (r.ok) {
        return await eng.orientedBlob(await r.blob())
      }
    } catch {
      /* fall through to the local capture */
    }
    return eng.screenshot()
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

  // Mic recording lives on the device (it keeps recording after the browser leaves),
  // so the truth is the daemon's status. Poll it: fast while recording (live timer),
  // slow otherwise. Restores the live state + elapsed time after a page reload.
  useEffect(() => {
    let alive = true
    const tick = async () => {
      try {
        const j = (await apiJSON('/v1/mic_record')) as { recording?: boolean; seconds?: number; bytes?: number }
        if (alive && !micMutation.current && j) setMicRec({ recording: !!j.recording, seconds: j.seconds || 0, bytes: j.bytes || 0 })
      } catch {
        /* ignore */
      }
    }
    tick()
    const id = window.setInterval(tick, micRec.recording ? 1000 : 5000)
    return () => {
      alive = false
      clearInterval(id)
    }
  }, [micRec.recording])

  // Listen to the iPad's own microphone (the room), captured by the daemon itself
  // so it works regardless of what app is foreground. resume() needs this click as
  // the audio-unlock gesture.
  const toggleListenMic = async () => {
    if (listeningMic) {
      roomMicRef.current.mute()
      setListeningMic(false)
      api('/v1/mic_capture?on=0').catch(() => {})
    } else {
      const ok = await roomMicRef.current.resume()
      if (!ok) return
      setListeningMic(true)
      api('/v1/mic_capture?on=1').catch(() => {})
    }
  }

  const mutateMicRecording = async (query: string) => {
    if (micMutation.current) return
    micMutation.current = true
    setMicRecordBusy(true)
    setMicRecordError('')
    try {
      const response = await api(`/v1/mic_record?${query}`)
      if (!response.ok) throw new Error('Microphone recording failed. Check the device audio session and available storage.')
      const status = await apiJSON<{ recording: boolean; seconds: number; bytes: number }>('/v1/mic_record')
      if (!status) throw new Error('Could not confirm recording status.')
      recBlob.current = null
      setMicRec(status)
    } catch (error) {
      setMicRecordError(error instanceof Error ? error.message : 'Recording request failed.')
    } finally {
      micMutation.current = false
      setMicRecordBusy(false)
    }
  }

  const pointerUnavailable = pointerCaptureUnavailable(recMode !== 'idle', keyboardStatus.mode,
    pointerStatus.available, typeof document.body.requestPointerLock === 'function')

  return {
    status,
    orient,
    stats,
    statsOn,
    keyboard: {
      ...keyboardStatus,
      canStartGame: recMode === 'idle',
      setGame: (enabled: boolean) => {
        if (enabled && recMode !== 'idle') return
        textKeyboardRef.current?.release()
        if (enabled) void gameKeyboardRef.current?.start()
        else { gameKeyboardRef.current?.stop(); gamePointerRef.current?.stop() }
      },
    },
    pointer: {
      ...pointerStatus,
      canCapture: !pointerUnavailable,
      unavailableReason: pointerUnavailable,
      capture: () => {
        const stage = stageRef.current
        if (!stage || pointerUnavailable) return
        try {
          // Must run directly in the user's click, before any asynchronous work.
          Promise.resolve(stage.requestPointerLock()).catch(() => gamePointerRef.current?.stop('Mouse capture was denied by the browser'))
        } catch { gamePointerRef.current?.stop('Mouse capture is unavailable in this browser') }
      },
    },
    audio: { listening, busy: audioBusy, deviceSpeaker, toggleListen, toggleSpeaker },
    brightness,
    setBrightness: changeBrightness,
    filesTransfer: filesRef.current,
    talk: {
      supported: micSupported(),
      talking,
      mode: talkMode,
      setMode: changeTalkMode,
      start: () => micRef.current.start(),
      stop: () => micRef.current.stop(),
    },
    listenMic: { active: listeningMic, toggle: toggleListenMic },
    micRecord: {
      busy: micRecordBusy,
      error: micRecordError,
      recording: micRec.recording,
      seconds: micRec.seconds,
      bytes: micRec.bytes,
      saving: savingRec,
      start: () => mutateMicRecording('on=1'),
      stop: () => mutateMicRecording('on=0'),
      // Pull the finished .m4a over the P2P files channel, cache it, and download.
      // Re-saving uses the cache so the click -> download stays synchronous (Safari
      // only permits a download inside the user-gesture window).
      save: async () => {
        if (recBlob.current && recBlob.current.bytes === micRec.bytes) {
          downloadBlob(recBlob.current.blob, 'rctl-mic-recording.m4a')
          return
        }
        setSavingRec(true)
        try {
          const blob = await filesRef.current.fetch(REC_PATH)
          recBlob.current = { bytes: micRec.bytes, blob }
          downloadBlob(blob, 'rctl-mic-recording.m4a')
        } catch {
          /* ignore */
        }
        setSavingRec(false)
      },
      discard: () => mutateMicRecording('discard=1'),
    },
    toggleStats: () => setStatsOn((v) => !v),
    setQuality: (scale: number, fps: number, bitrate: number) =>
      engineRef.current?.setQuality(scale, fps, bitrate),
    screenshot: captureScreenshot,
    record: {
      exportScript: () => downloadBlob(new Blob([JSON.stringify(macroScript(macroRef.current), null, 2)], { type: 'application/json' }), 'rctl-macro.json'),
      pausePlay: () => engineRef.current?.pausePlay(),
      resumePlay: () => engineRef.current?.resumePlay(),
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
