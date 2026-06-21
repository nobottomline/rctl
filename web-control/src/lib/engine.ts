// Live-control engine: a faithful port of the vanilla page's WebRTC video +
// input core. It owns the imperative, delicate bits (the hardware-overlay <video>
// sizing, the orientation math, the input coordinate mapping, the control
// DataChannel vs HTTP input fallback) operating on DOM elements React hands it,
// so the hard-won behavior moves over unchanged instead of being re-derived.
//
// Not yet ported here (follow-ups): the /stream WebCodecs fallback/local path,
// audio playback, the files DataChannel. The engine exposes the audio/files
// channels via callbacks so those layers can attach later.

import { WEBRTC_MODE, RELAY_MODE, api, signalWS } from './rctl'

// UIInterfaceOrientation -> CSS rotation (deg) that makes content upright.
const DEG: Record<number, number> = { 1: 0, 2: 180, 3: -90, 4: 90 }
const ROT = [1, 4, 2, 3] // DEG steps 0,90,180,270 (Rotate button order)
const SYS: Record<string, number> = { home: 0x40, lock: 0x30, volup: 0xe9, voldn: 0xea }

// Physical KeyboardEvent.code -> HID usage (Keyboard/Keypad page 0x07).
export function codeToUsage(c: string): number {
  if (/^Key[A-Z]$/.test(c)) return 0x04 + (c.charCodeAt(3) - 65)
  if (/^Digit[1-9]$/.test(c)) return 0x1e + (c.charCodeAt(5) - 49)
  if (c === 'Digit0') return 0x27
  return (
    (
      {
        Enter: 0x28, NumpadEnter: 0x28, Escape: 0x29, Backspace: 0x2a, Tab: 0x2b, Space: 0x2c,
        Minus: 0x2d, Equal: 0x2e, BracketLeft: 0x2f, BracketRight: 0x30, Backslash: 0x31,
        Semicolon: 0x33, Quote: 0x34, Backquote: 0x35, Comma: 0x36, Period: 0x37, Slash: 0x38, CapsLock: 0x39,
        ArrowRight: 0x4f, ArrowLeft: 0x50, ArrowDown: 0x51, ArrowUp: 0x52,
        Delete: 0x4c, Home: 0x4a, End: 0x4d, PageUp: 0x4b, PageDown: 0x4e,
        ControlLeft: 0xe0, ShiftLeft: 0xe1, AltLeft: 0xe2, MetaLeft: 0xe3,
        ControlRight: 0xe4, ShiftRight: 0xe5, AltRight: 0xe6, MetaRight: 0xe7,
      } as Record<string, number>
    )[c] || 0
  )
}

// HID modifier usages — held (press/release) rather than tapped.
export const MOD_USAGES = new Set([0xe0, 0xe1, 0xe2, 0xe3, 0xe4, 0xe5, 0xe6, 0xe7])

// A recorded input event: a touch ('t': phase p, finger i, normalized x/y) or a
// key ('k': HID usage u, down d). `t` is ms since the recording started.
export type MacroEvent = { t: number; k: 't' | 'k'; p?: number; i?: number; x?: number; y?: number; u?: number; d?: number }

export type DiagStats = {
  fps: number
  res: string
  decodeMs: number
  jitterMs: number
  dropped: number
  freezes: number
  freezeS: number
  pli: number
  rttMs: number | string
  path: string
}

export type EngineCallbacks = {
  onStatus?: (text: string) => void
  onFrame?: () => void
  onOrient?: (o: number, manual: boolean) => void
  onControlChannel?: (ch: RTCDataChannel) => void
  onAudioChannel?: (ch: RTCDataChannel) => void
  onFilesChannel?: (ch: RTCDataChannel) => void
}

export class ControlEngine {
  private stage: HTMLElement
  private canvas: HTMLCanvasElement
  private video: HTMLVideoElement
  private cb: EngineCallbacks

  private orient = 1
  private manualOrient: number | null = null
  private dispEl: HTMLElement // the element the orientation transform applies to
  private frames = 0
  private control: RTCDataChannel | null = null

  // HTTP input fallback (used when no control DataChannel is open).
  private inputBusy = false
  private inputQueue: { p: number; f: number; x: string; y: string }[] = []

  private pc: RTCPeerConnection | null = null
  private ws: WebSocket | null = null
  private orientTimer: number | undefined
  private stopped = false
  private statsPrev: { decoded: number; t: number } | null = null
  private rec: MacroEvent[] | null = null // input recording buffer (null = not recording)
  private recT0 = 0
  private recPaused = false
  private recPausedAt = 0
  private playToken = 0 // bumped to cancel an in-flight play()

  constructor(
    stage: HTMLElement,
    canvas: HTMLCanvasElement,
    video: HTMLVideoElement,
    cb: EngineCallbacks = {},
  ) {
    this.stage = stage
    this.canvas = canvas
    this.video = video
    this.cb = cb
    this.dispEl = canvas
  }

  // ---- lifecycle ----------------------------------------------------------
  start() {
    if (WEBRTC_MODE) this.startWebRTC()
    // else: /stream WebCodecs path — ported in a follow-up.
    else this.status('local /stream path not ported yet')
  }

  stop() {
    this.stopped = true
    if (this.orientTimer) clearInterval(this.orientTimer)
    try {
      this.pc?.close()
    } catch {
      /* ignore */
    }
    try {
      this.ws?.close()
    } catch {
      /* ignore */
    }
    this.control = null
  }

  private status(t: string) {
    this.cb.onStatus?.(t)
  }

  // ---- orientation --------------------------------------------------------
  effOrient() {
    return this.manualOrient != null ? this.manualOrient : this.orient
  }

  setAutoOrient() {
    this.manualOrient = null
    this.applyOrient()
    this.cb.onOrient?.(this.effOrient(), false)
  }

  rotate() {
    let i = ROT.indexOf(this.effOrient())
    if (i < 0) i = 0
    this.manualOrient = ROT[(i + 1) % 4]
    this.applyOrient()
    this.cb.onOrient?.(this.effOrient(), true)
  }

  applyOrient() {
    const deg = DEG[this.effOrient()] || 0
    const cw = this.canvas.width || 1
    const ch = this.canvas.height || 1
    const r90 = deg === 90 || deg === -90
    const el = this.dispEl
    if (el !== this.canvas) {
      // WebRTC <video>: size with object-fit (layout) so the browser keeps it on
      // the zero-copy hardware overlay; a CSS scale/rotate would drop it onto the
      // slow compositor -> lag. Rotate only when actually needed.
      el.style.objectFit = 'contain'
      if (!deg) {
        el.style.position = ''
        el.style.left = ''
        el.style.top = ''
        el.style.width = innerWidth + 'px'
        el.style.height = innerHeight + 'px'
        el.style.transform = ''
      } else {
        el.style.position = 'absolute'
        el.style.left = '50%'
        el.style.top = '50%'
        el.style.width = (r90 ? innerHeight : innerWidth) + 'px'
        el.style.height = (r90 ? innerWidth : innerHeight) + 'px'
        el.style.transform = `translate(-50%,-50%) rotate(${deg}deg)`
      }
      return
    }
    const bbW = r90 ? ch : cw
    const bbH = r90 ? cw : ch
    const sc = Math.min(innerWidth / bbW, innerHeight / bbH)
    el.style.transform = `rotate(${deg}deg) scale(${sc})`
  }

  // Map a client (px) point on the displayed (rotated/scaled) surface back to
  // normalized framebuffer coordinates (the screen's fixed space).
  private clientToNorm(cx: number, cy: number): [number, number] {
    const deg = DEG[this.effOrient()] || 0
    const rad = (-deg * Math.PI) / 180
    const cw = this.canvas.width || 1
    const ch = this.canvas.height || 1
    const r90 = deg === 90 || deg === -90
    const bbW = r90 ? ch : cw
    const bbH = r90 ? cw : ch
    const sc = Math.min(innerWidth / bbW, innerHeight / bbH)
    const dx = (cx - innerWidth / 2) / sc
    const dy = (cy - innerHeight / 2) / sc
    const rx = dx * Math.cos(rad) - dy * Math.sin(rad)
    const ry = dx * Math.sin(rad) + dy * Math.cos(rad)
    return [(rx + cw / 2) / cw, (ry + ch / 2) / ch]
  }

  // ---- input --------------------------------------------------------------
  // Touch phase 0=down 1=move 2=up; finger 0..10.
  sendTouchAt(p: number, cx: number, cy: number, finger: number) {
    const [nx, ny] = this.clientToNorm(cx, cy)
    this.sendTouchNorm(p, nx, ny, finger)
  }

  // Send an already-normalized touch (the input map for live pointers, and the
  // replay path for recorded macros). Captures into the recording when active.
  private sendTouchNorm(p: number, nx: number, ny: number, finger: number) {
    if (this.rec && !this.recPaused)
      this.rec.push({ t: performance.now() - this.recT0, k: 't', p, i: finger, x: +nx.toFixed(4), y: +ny.toFixed(4) })
    if (this.control && this.control.readyState === 'open') {
      try {
        this.control.send(JSON.stringify({ t: 't', p, i: finger, x: +nx.toFixed(4), y: +ny.toFixed(4) }))
      } catch {
        /* ignore */
      }
      return
    }
    this.queueInput({ p, f: finger, x: nx.toFixed(4), y: ny.toFixed(4) })
  }

  private queueInput(ev: { p: number; f: number; x: string; y: string }) {
    if (ev.p === 1) {
      const i = this.inputQueue.findIndex((x) => x.p === 1 && x.f === ev.f)
      if (i >= 0) {
        this.inputQueue[i] = ev
        return
      }
    }
    this.inputQueue.push(ev)
    this.pumpInput()
  }

  private pumpInput() {
    if (this.inputBusy || !this.inputQueue.length) return
    this.inputBusy = true
    const ev = this.inputQueue.shift()!
    api(`/input?phase=${ev.p}&id=${ev.f}&x=${ev.x}&y=${ev.y}`)
      .catch(() => {})
      .finally(() => {
        this.inputBusy = false
        this.pumpInput()
      })
  }

  key(usage: number, down: number) {
    if (this.rec && !this.recPaused) this.rec.push({ t: performance.now() - this.recT0, k: 'k', u: usage, d: down })
    if (this.control && this.control.readyState === 'open') {
      try {
        this.control.send(JSON.stringify({ t: 'k', pg: 7, u: usage, d: down }))
      } catch {
        /* ignore */
      }
      return
    }
    api(`/key?p=7&u=${usage}&d=${down}`).catch(() => {})
  }

  // Hardware buttons (HID Consumer page 0x0C): a press+release tap.
  sysPress(name: string) {
    const u = SYS[name]
    if (!u) return
    if (this.control && this.control.readyState === 'open') {
      try {
        this.control.send(JSON.stringify({ t: 'k', pg: 12, u, d: 1 }))
        setTimeout(() => {
          try {
            this.control?.send(JSON.stringify({ t: 'k', pg: 12, u, d: 0 }))
          } catch {
            /* ignore */
          }
        }, 70)
      } catch {
        /* ignore */
      }
      return
    }
    api(`/key?p=12&u=${u}&d=1`).then(() => setTimeout(() => api(`/key?p=12&u=${u}&d=0`).catch(() => {}), 70))
  }

  // SpringBoard actions (page 0xF0): 1=Control Center, 2=Cover Sheet.
  springboard(u: number) {
    if (this.control && this.control.readyState === 'open') {
      try {
        this.control.send(JSON.stringify({ t: 'k', pg: 240, u, d: 1 }))
      } catch {
        /* ignore */
      }
      return
    }
    api(`/key?p=240&u=${u}&d=1`).catch(() => {})
  }

  // ---- diagnostics --------------------------------------------------------
  // Pull live receive-side WebRTC stats so we can see *why* a viewer (e.g. an
  // iPhone vs a Mac) struggles: decode cost/frame, jitter-buffer depth, drops,
  // freezes, the negotiated ICE path. fps is derived from the framesDecoded
  // delta because Safari often omits the framesPerSecond field.
  async sampleStats(): Promise<DiagStats | null> {
    if (!this.pc) return null
    let report: RTCStatsReport
    try {
      report = await this.pc.getStats()
    } catch {
      return null
    }
    type Any = Record<string, unknown>
    let v: Any | null = null
    let transport: Any | null = null
    let pair: Any | null = null
    report.forEach((r) => {
      const x = r as unknown as Any
      if (x.type === 'inbound-rtp' && x.kind === 'video') v = x
      else if (x.type === 'transport') transport = x
    })
    if (!v) return null
    const get = (id: unknown) => (typeof id === 'string' ? (report.get(id) as unknown as Any | undefined) : undefined)
    if (transport) pair = get((transport as Any).selectedCandidatePairId) ?? null
    if (!pair) report.forEach((r) => {
      const x = r as unknown as Any
      if (x.type === 'candidate-pair' && (x.nominated || x.selected)) pair = x
    })
    let local = '?'
    let remote = '?'
    if (pair) {
      local = (get((pair as Any).localCandidateId)?.candidateType as string) || '?'
      remote = (get((pair as Any).remoteCandidateId)?.candidateType as string) || '?'
    }
    const vv = v as Any
    const decoded = (vv.framesDecoded as number) || 0
    const now = performance.now()
    let fps = (vv.framesPerSecond as number) ?? 0
    if (this.statsPrev) {
      const dt = (now - this.statsPrev.t) / 1000
      if (dt > 0.2) fps = Math.max(0, Math.round((decoded - this.statsPrev.decoded) / dt))
    }
    this.statsPrev = { decoded, t: now }
    const emitted = (vv.jitterBufferEmittedCount as number) || 0
    const jitterMs = emitted ? Math.round((1000 * (vv.jitterBufferDelay as number)) / emitted) : 0
    const decodeMs = decoded ? +((1000 * (vv.totalDecodeTime as number)) / decoded).toFixed(1) : 0
    const rtt = pair ? (pair as Any).currentRoundTripTime : undefined
    return {
      fps,
      res: `${(vv.frameWidth as number) || 0}×${(vv.frameHeight as number) || 0}`,
      decodeMs,
      jitterMs,
      dropped: (vv.framesDropped as number) || 0,
      freezes: (vv.freezeCount as number) || 0,
      freezeS: +(((vv.totalFreezesDuration as number) || 0)).toFixed(1),
      pli: (vv.pliCount as number) || 0,
      rttMs: typeof rtt === 'number' ? Math.round(rtt * 1000) : '?',
      path: `${local}/${remote}`,
    }
  }

  // Change the device's shared encode profile (scale 0..1, fps, bitrate bps).
  // Lets a weak viewer dial the stream down without touching other viewers'
  // clients — the device re-applies it to the single VTCompressionSession.
  setQuality(scale: number, fps: number, bitrate: number) {
    api(`/config?scale=${scale}&fps=${fps}&bitrate=${bitrate}`).catch(() => {})
  }

  // Save the current frame as a PNG to the browser (nothing shows on the iPad).
  // Grabs the raw <video> pixels and rotates them to effOrient so the image is
  // upright regardless of how the device is held. Local MediaStream -> not tainted.
  screenshot() {
    const v = this.video
    const sw = v.videoWidth
    const sh = v.videoHeight
    if (!sw || !sh) return
    const deg = DEG[this.effOrient()] || 0
    const r90 = deg === 90 || deg === -90
    const t = document.createElement('canvas')
    t.width = r90 ? sh : sw
    t.height = r90 ? sw : sh
    const x = t.getContext('2d')
    if (!x) return
    x.translate(t.width / 2, t.height / 2)
    x.rotate((deg * Math.PI) / 180)
    x.drawImage(v, -sw / 2, -sh / 2)
    const a = document.createElement('a')
    a.download = `rctl-${Date.now()}.png`
    a.href = t.toDataURL('image/png')
    a.click()
  }

  // ---- macro record / play ------------------------------------------------
  recordStart() {
    this.stopPlay() // recording from within a playback restarts fresh
    this.rec = []
    this.recT0 = performance.now()
    this.recPaused = false
  }
  // Pause/resume freeze the timeline (recT0 is shifted by the paused span) so the
  // gap doesn't appear in playback.
  recordPause() {
    if (this.rec && !this.recPaused) {
      this.recPausedAt = performance.now()
      this.recPaused = true
    }
  }
  recordResume() {
    if (this.rec && this.recPaused) {
      this.recT0 += performance.now() - this.recPausedAt
      this.recPaused = false
    }
  }
  recordStop(): MacroEvent[] {
    const m = this.rec || []
    this.rec = null
    this.recPaused = false
    return m
  }

  stopPlay() {
    this.playToken++ // invalidates any in-flight play() loop
  }

  // Replay a recorded macro with its original timing. Cancellable: the wait is
  // sliced so stopPlay() (or starting a record) aborts within ~50ms. Replays
  // aren't captured (rec stays null during play). Resolves when done or aborted.
  async play(macro: MacroEvent[]) {
    if (!macro.length || this.rec) return
    const token = ++this.playToken
    const start = performance.now()
    for (const e of macro) {
      while (this.playToken === token && !this.stopped) {
        const remaining = e.t - (performance.now() - start)
        if (remaining <= 0) break
        await new Promise((r) => setTimeout(r, Math.min(remaining, 50)))
      }
      if (this.playToken !== token || this.stopped) return // cancelled
      if (e.k === 't') this.sendTouchNorm(e.p ?? 1, e.x ?? 0, e.y ?? 0, e.i ?? 0)
      else this.key(e.u ?? 0, e.d ?? 0)
    }
  }

  // ---- WebRTC -------------------------------------------------------------
  private startWebRTC() {
    const vid = this.video
    vid.autoplay = true
    vid.playsInline = true
    vid.muted = true
    vid.style.cssText = 'transform-origin:center center;pointer-events:none;background:#000'

    const pc = new RTCPeerConnection({})
    this.pc = pc
    let remoteReady = false
    const pend: RTCIceCandidateInit[] = []

    pc.ontrack = (e) => {
      vid.srcObject = e.streams[0] || new MediaStream([e.track])
      try {
        ;(e.receiver as RTCRtpReceiver & { playoutDelayHint?: number }).playoutDelayHint = 0
      } catch {
        /* ignore */
      }
      this.canvas.style.display = 'none'
      if (!vid.parentElement) this.stage.appendChild(vid)
      this.dispEl = vid
      vid.play().catch(() => {})
      // Size the <video> to the stream's pixel size; applyOrient scales/rotates it
      // to fit (the canvas keeps the same width/height as the input-map reference).
      const fit = () => {
        if (vid.videoWidth) {
          this.canvas.width = vid.videoWidth
          this.canvas.height = vid.videoHeight
          this.applyOrient()
          this.frames++
          this.cb.onFrame?.()
        }
      }
      vid.addEventListener('loadedmetadata', fit)
      vid.addEventListener('resize', fit)
      fit()
    }

    pc.ondatachannel = (e) => {
      const ch = e.channel
      if (ch.label === 'control') {
        this.control = ch
        this.cb.onControlChannel?.(ch)
      } else if (ch.label === 'audio') {
        this.cb.onAudioChannel?.(ch)
      } else if (ch.label === 'files') {
        this.cb.onFilesChannel?.(ch)
      }
    }

    pc.onconnectionstatechange = () => {
      if (pc.connectionState === 'failed') this.status('webrtc failed')
    }

    const ws = new WebSocket(signalWS())
    this.ws = ws
    pc.onicecandidate = (e) => {
      if (e.candidate && ws.readyState === 1)
        ws.send(JSON.stringify({ kind: 'candidate', payload: { candidate: e.candidate.candidate, mid: e.candidate.sdpMid } }))
    }
    ws.onmessage = async (ev) => {
      let m: { kind?: string; payload?: unknown }
      try {
        m = JSON.parse(ev.data)
      } catch {
        return
      }
      if (m.kind === 'ready') {
        if (Array.isArray(m.payload) && m.payload.length) {
          try {
            pc.setConfiguration({ iceServers: m.payload as RTCIceServer[] })
          } catch {
            /* ignore */
          }
        }
      } else if (m.kind === 'offer') {
        try {
          const p = m.payload as { sdp: string }
          await pc.setRemoteDescription({ type: 'offer', sdp: p.sdp })
          remoteReady = true
          for (const c of pend.splice(0)) {
            try {
              await pc.addIceCandidate(c)
            } catch {
              /* ignore */
            }
          }
          const a = await pc.createAnswer()
          await pc.setLocalDescription(a)
          ws.send(JSON.stringify({ kind: 'answer', payload: { sdp: pc.localDescription!.sdp } }))
        } catch {
          this.status('negotiate err')
        }
      } else if (m.kind === 'candidate') {
        const p = m.payload as { candidate?: string; mid?: string }
        const ic = { candidate: (p.candidate || '').replace(/^a=/, ''), sdpMid: p.mid || '0' }
        if (remoteReady) {
          try {
            await pc.addIceCandidate(ic)
          } catch {
            /* ignore */
          }
        } else pend.push(ic)
      }
    }
    ws.onerror = () => this.status('signal err')

    // Orientation: poll /orient (through the proxy) and re-apply on change.
    this.orientTimer = window.setInterval(async () => {
      if (this.stopped) return
      try {
        const r = await api('/orient')
        const o = parseInt(await r.text(), 10)
        if (o >= 1 && o <= 4 && o !== this.orient) {
          this.orient = o
          this.applyOrient()
          if (this.manualOrient == null) this.cb.onOrient?.(o, false)
        }
      } catch {
        /* ignore */
      }
    }, 1500)
  }
}

export { RELAY_MODE }
