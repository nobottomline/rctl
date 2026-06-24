// Live-control engine: a faithful port of the vanilla page's WebRTC video +
// input core. It owns the imperative, delicate bits (the hardware-overlay <video>
// sizing, the orientation math, the input coordinate mapping, the control
// DataChannel vs HTTP input fallback) operating on DOM elements React hands it,
// so the hard-won behavior moves over unchanged instead of being re-derived.
//
// Two transports share this engine: WebRTC (relay or direct LAN) and the
// /stream WebCodecs fallback path. Audio playback and the files DataChannel are
// exposed via callbacks so those layers attach on top.

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

// Big-endian 64-bit µs PTS from the 8-byte /stream payload header.
function ptsFromPayload(d: Uint8Array): number {
  const hi = d[0] * 16777216 + (d[1] << 16) + (d[2] << 8) + d[3]
  const lo = ((d[4] << 24) >>> 0) + (d[5] << 16) + (d[6] << 8) + d[7]
  return hi * 4294967296 + lo
}

// WebCodecs codec string from an Annex-B SPS NAL (type 7): avc1.PPCCLL.
function codecFromAU(au: Uint8Array): string | null {
  for (let i = 0; i + 8 < au.length; i++) {
    if (au[i] === 0 && au[i + 1] === 0 && au[i + 2] === 0 && au[i + 3] === 1 && (au[i + 4] & 0x1f) === 7) {
      return 'avc1.' + [au[i + 5], au[i + 6], au[i + 7]].map((x) => x.toString(16).padStart(2, '0')).join('')
    }
  }
  return null
}

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
  onMicChannel?: (ch: RTCDataChannel) => void
  onRoomMicChannel?: (ch: RTCDataChannel) => void
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

  // ---- local /stream (WebCodecs) decode state -----------------------------
  private dec: VideoDecoder | null = null
  private streamStarted = false
  private codec = 'avc1.640033'
  private vq: VideoFrame[] = [] // decoded frames awaiting paced presentation
  private rafId = 0
  private ctx2d: CanvasRenderingContext2D | null = null
  private localMode = false // device-local P2P (no relay): signal over /ws/signal
  private fellBack = false // local WebRTC failed -> using the /stream fallback
  private rtcFallbackTimer = 0
  private wsUrl = '' // remembered so we can re-dial the same signaling socket
  private reconnectTimer = 0
  private rtcAttempts = 0 // consecutive failed WebRTC connects (reset on first frame)
  private disconnectGrace = 0 // pending "is this blip going to self-heal?" timer

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
    if (WEBRTC_MODE) {
      this.startWebRTC(signalWS())
    } else if (RELAY_MODE) {
      // Relay with WebRTC disabled: use the authenticated stream tunnel as a
      // compatibility/debug fallback. Do not try local /ws/signal from a relay
      // origin; that endpoint exists only on rctld itself.
      this.startStream()
    } else if (typeof RTCPeerConnection !== 'undefined') {
      // Device-local P2P: signal over the device's own /ws/signal with host-only
      // ICE -> direct-LAN WebRTC (relay-grade video, no relay, no TURN). Falls
      // back to the WebCodecs /stream path if WebRTC can't connect (e.g. iOS
      // Safari over plain HTTP, which gates it).
      this.localMode = true
      // Full-res 60fps is wasteful for remote control and overloads the single
      // shared encoder (a fresh rctld defaults to it) -- with a 2nd viewer it can
      // CPU-kill the daemon. Start local at a smooth, light profile; the user can
      // raise it from the quality menu.
      this.setQuality(0.7, 30, 10000000)
      const proto = location.protocol === 'https:' ? 'wss' : 'ws'
      this.startWebRTC(`${proto}://${location.host}/ws/signal`)
    } else {
      this.startStream()
    }
  }

  // Local WebRTC couldn't connect: fall back to the WebCodecs /stream path
  // (itself guarded if WebCodecs is unavailable). Idempotent.
  private fallbackToStream() {
    if (this.fellBack) return
    this.fellBack = true
    if (this.rtcFallbackTimer) {
      clearTimeout(this.rtcFallbackTimer)
      this.rtcFallbackTimer = 0
    }
    if (this.reconnectTimer) {
      clearTimeout(this.reconnectTimer)
      this.reconnectTimer = 0
    }
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
    this.pc = null
    try {
      this.video.style.display = 'none'
    } catch {
      /* ignore */
    }
    this.startStream()
  }

  // The WebRTC link dropped (peer 'failed', or no video within the grace window).
  // Tear the dead session down and re-dial the signaling socket with a capped
  // backoff -- this is what makes a tab heal itself instead of needing a manual
  // reload after the daemon was briefly busy (e.g. a second viewer churning). On
  // the relay path, after a few WebRTC misses we drop to the stream tunnel; the
  // local path has no usable stream fallback, so it keeps re-dialing.
  private scheduleReconnect() {
    if (this.stopped || this.fellBack || this.reconnectTimer) return
    if (this.rtcFallbackTimer) {
      clearTimeout(this.rtcFallbackTimer)
      this.rtcFallbackTimer = 0
    }
    if (this.disconnectGrace) {
      clearTimeout(this.disconnectGrace)
      this.disconnectGrace = 0
    }
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
    this.pc = null
    this.ws = null
    if (!this.localMode && this.rtcAttempts >= 5) {
      this.fallbackToStream()
      return
    }
    const backoff = Math.min(5000, 600 * 2 ** this.rtcAttempts) + Math.floor(Math.random() * 250)
    this.rtcAttempts++
    this.status('reconnecting…')
    this.reconnectTimer = window.setTimeout(() => {
      this.reconnectTimer = 0
      if (this.stopped || this.fellBack) return
      this.startWebRTC(this.wsUrl)
    }, backoff)
  }

  stop() {
    this.stopped = true
    if (this.orientTimer) clearInterval(this.orientTimer)
    if (this.reconnectTimer) clearTimeout(this.reconnectTimer)
    if (this.disconnectGrace) clearTimeout(this.disconnectGrace)
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
    if (this.rafId) cancelAnimationFrame(this.rafId)
    this.resetStream()
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
    // Absolute-center like the WebRTC <video> path (grid centering drifted the
    // large intrinsic-size canvas downward on some layouts).
    el.style.position = 'absolute'
    el.style.left = '50%'
    el.style.top = '50%'
    el.style.transform = `translate(-50%,-50%) rotate(${deg}deg) scale(${sc})`
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

  // Download a captured frame as a PNG, rotated to the current orientation so it's
  // upright. Both sources (the <video> overlay and the device's framebuffer PNG)
  // are the raw native-portrait surface; only the browser knows how the screen is
  // held, so it does the rotation here -- the same DEG[effOrient] the live overlay
  // uses for display.
  private downloadRotated(src: CanvasImageSource, sw: number, sh: number) {
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
    x.drawImage(src, -sw / 2, -sh / 2)
    this.downloadHref(t.toDataURL('image/png'))
  }

  private downloadHref(href: string) {
    const a = document.createElement('a')
    a.download = `rctl-${Date.now()}.png`
    a.href = href
    a.click()
  }

  // Local fallback: save the current <video> frame (stream quality, but upright).
  screenshot() {
    const v = this.video
    if (v.videoWidth && v.videoHeight) this.downloadRotated(v, v.videoWidth, v.videoHeight)
  }

  // Full-res device PNG (the raw native-portrait framebuffer): save it rotated to
  // the current orientation. When already upright (portrait) keep the original
  // bytes untouched; otherwise rotate through a canvas so a landscape screen isn't
  // saved sideways.
  async saveOrientedBlob(blob: Blob) {
    if (!(DEG[this.effOrient()] || 0)) {
      const u = URL.createObjectURL(blob)
      this.downloadHref(u)
      setTimeout(() => URL.revokeObjectURL(u), 1500)
      return
    }
    const url = URL.createObjectURL(blob)
    try {
      const img = await new Promise<HTMLImageElement>((res, rej) => {
        const i = new Image()
        i.onload = () => res(i)
        i.onerror = rej
        i.src = url
      })
      this.downloadRotated(img, img.naturalWidth, img.naturalHeight)
    } catch {
      /* ignore */
    } finally {
      URL.revokeObjectURL(url)
    }
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

  // ---- local /stream (WebCodecs) path -------------------------------------
  // Device-direct mode (no relay): pull the H.264 elementary stream over the
  // chunked HTTP body, decode with WebCodecs, and present through a small
  // PTS-paced jitter buffer aligned to the display refresh. The vanilla page
  // drew each frame the instant it decoded, so network jitter showed as
  // micro-stutter; buffering ~60ms and releasing on a playout clock makes it
  // as smooth as the WebRTC path while staying fully device-local.
  private async startStream() {
    if (typeof VideoDecoder === 'undefined') {
      // WebCodecs is a secure-context API: over plain HTTP on a LAN IP it's gated
      // off in standard Chromium (and others), so the decoder is unavailable.
      // Fail gracefully with a clear status instead of throwing a ReferenceError
      // that would leave the page looking dead.
      this.status('video unavailable here (WebCodecs needs a secure context)')
      return
    }
    this.status('connecting')
    this.dispEl = this.canvas
    this.canvas.style.display = ''
    if (!this.rafId) this.rafId = requestAnimationFrame(this.present)
    let resp: Response
    try {
      resp = await api('/stream')
    } catch {
      this.status('stream failed')
      return
    }
    if (!resp.body) {
      this.status('no stream')
      return
    }
    const reader = resp.body.getReader()
    let buf = new Uint8Array(0)
    this.status('')
    for (;;) {
      if (this.stopped) {
        try {
          await reader.cancel()
        } catch {
          /* ignore */
        }
        return
      }
      let chunk: ReadableStreamReadResult<Uint8Array>
      try {
        chunk = await reader.read()
      } catch {
        this.status('stream error')
        break
      }
      if (chunk.done) {
        this.status('stream ended')
        break
      }
      const v = chunk.value!
      const nb = new Uint8Array(buf.length + v.length)
      nb.set(buf, 0)
      nb.set(v, buf.length)
      buf = nb
      for (;;) {
        if (buf.length < 5) break
        const type = buf[0]
        const len = ((buf[1] << 24) >>> 0) + (buf[2] << 16) + (buf[3] << 8) + buf[4]
        if (buf.length < 5 + len) break
        const data = buf.slice(5, 5 + len)
        buf = buf.subarray(5 + len)
        if (type === 2) {
          if (data.length >= 1 && data[0] !== this.orient) {
            this.orient = data[0]
            this.applyOrient()
            if (this.manualOrient == null) this.cb.onOrient?.(this.orient, false)
          }
          continue
        }
        if (type === 3) {
          this.resetStream()
          continue
        }
        if (type === 4) continue // local PCM audio — follow-up
        if (type !== 0 && type !== 1) continue
        if (data.length < 8) continue
        const pts = ptsFromPayload(data)
        const au = data.slice(8)
        const key = type === 1
        if (!this.streamStarted) {
          if (!key) continue // wait for a keyframe to start decoding
          const cs = codecFromAU(au)
          if (cs) this.codec = cs
          this.mkdec()
          this.streamStarted = true
        }
        try {
          this.dec!.decode(new EncodedVideoChunk({ type: key ? 'key' : 'delta', timestamp: pts, data: au }))
        } catch {
          /* decode error -> resync at the next keyframe */
        }
      }
    }
  }

  private mkdec() {
    if (this.dec) {
      try {
        this.dec.close()
      } catch {
        /* ignore */
      }
    }
    this.dec = new VideoDecoder({
      output: (f) => {
        this.vq.push(f)
        if (this.vq.length > 24) this.vq.shift()?.close() // hard cap (decoder has finite output buffers)
        this.frames++
        this.cb.onFrame?.()
      },
      error: () => this.resetStream(),
    })
    this.dec.configure({ codec: this.codec, optimizeForLatency: true } as VideoDecoderConfig)
  }

  // Present the freshest decoded frame and drop any older queued ones, aligned to
  // the display refresh. Vsync pacing removes the vanilla's draw-on-decode judder
  // while keeping latency at ~one frame (LAN jitter is low, so a playout buffer
  // would only add lag).
  private present = () => {
    if (this.stopped) return
    this.rafId = requestAnimationFrame(this.present)
    const q = this.vq
    if (!q.length) return
    const f = q.pop()!
    while (q.length) {
      try {
        q.shift()?.close()
      } catch {
        /* ignore */
      }
    }
    this.drawFrame(f)
    try {
      f.close()
    } catch {
      /* ignore */
    }
  }

  private drawFrame(f: VideoFrame) {
    const ctx = this.ctx2d ?? (this.ctx2d = this.canvas.getContext('2d'))
    if (!ctx) return
    if (this.canvas.width !== f.displayWidth || this.canvas.height !== f.displayHeight) {
      this.canvas.width = f.displayWidth
      this.canvas.height = f.displayHeight
      this.applyOrient()
    }
    ctx.drawImage(f, 0, 0)
  }

  private resetStream() {
    this.streamStarted = false
    if (this.dec) {
      try {
        this.dec.close()
      } catch {
        /* ignore */
      }
      this.dec = null
    }
    for (const f of this.vq) {
      try {
        f.close()
      } catch {
        /* ignore */
      }
    }
    this.vq = []
  }

  // ---- WebRTC -------------------------------------------------------------
  // wsUrl is the signaling socket: the relay's /signal for internet sessions, or
  // the device's own /ws/signal for device-local P2P.
  private startWebRTC(wsUrl: string) {
    this.wsUrl = wsUrl
    // Re-entrant: a reconnect calls this again, so clear timers from the prior dial
    // (the orient poll re-arms below) to avoid stacking intervals/timeouts.
    if (this.orientTimer) {
      clearInterval(this.orientTimer)
      this.orientTimer = undefined
    }
    if (this.rtcFallbackTimer) {
      clearTimeout(this.rtcFallbackTimer)
      this.rtcFallbackTimer = 0
    }
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
        // Direct-LAN local sessions need a small playout buffer (~50ms) to ride out
        // bursty delivery; the relay path stays at 0 (its RTT already buffers).
        ;(e.receiver as RTCRtpReceiver & { playoutDelayHint?: number }).playoutDelayHint = this.localMode ? 0.05 : 0
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
          if (this.rtcFallbackTimer) {
            clearTimeout(this.rtcFallbackTimer)
            this.rtcFallbackTimer = 0
          }
          this.rtcAttempts = 0 // a healthy link; let the next drop retry from scratch
          this.status('')
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
      } else if (ch.label === 'mic-in') {
        this.cb.onMicChannel?.(ch)
      } else if (ch.label === 'room-mic') {
        this.cb.onRoomMicChannel?.(ch)
      }
    }

    pc.onconnectionstatechange = () => {
      const st = pc.connectionState
      if (st === 'failed') {
        this.scheduleReconnect()
      } else if (st === 'disconnected') {
        // A 'disconnected' is often a transient blip that recovers on its own;
        // only re-dial if it hasn't healed within a short grace.
        if (!this.disconnectGrace)
          this.disconnectGrace = window.setTimeout(() => {
            this.disconnectGrace = 0
            if (this.pc === pc && (pc.connectionState === 'disconnected' || pc.connectionState === 'failed'))
              this.scheduleReconnect()
          }, 4000)
      } else if (st === 'connected') {
        if (this.disconnectGrace) {
          clearTimeout(this.disconnectGrace)
          this.disconnectGrace = 0
        }
      }
    }

    const ws = new WebSocket(wsUrl)
    this.ws = ws
    // If no video renders within the grace window the link is wedged (daemon busy,
    // a peer churning, ICE lost a race) -- re-dial rather than sit on a dead view.
    // Baseline the frame count so this also catches a reconnect that re-establishes
    // signaling but never delivers a new frame.
    const framesAtDial = this.frames
    this.rtcFallbackTimer = window.setTimeout(() => {
      if (this.frames === framesAtDial) this.scheduleReconnect()
    }, 7000)
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
