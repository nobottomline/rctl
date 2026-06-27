// Browser-side playback of the iPad's captured audio. The device encodes its
// output as Opus and sends each frame over the WebRTC "audio" DataChannel as
// [1B channel count][Opus frame] (a DataChannel, NOT a media track -- a 2nd SRTP
// stream kills all media RTP on the iOS libsrtp backend). A ~180ms Web Audio jitter
// buffer schedules playback. The AudioContext runs at 48kHz to match Opus so buffers
// aren't per-frame resampled (that hissed).
//
// Decoding Opus: modern browsers use the built-in WebCodecs AudioDecoder. iOS Safari
// only shipped AudioDecoder in version 26 -- on 16.4..18.x it's undefined, so every
// frame was silently dropped (no sound on older iPhones). For those we fall back to a
// libopus WASM decoder (opus-decoder), whose WASM we embed ourselves as base64 and
// inject via OpusDecoder.module (its own dynEncode-string packaging can't survive the
// single-file HTML build -- see vite.config.ts).

import { OpusDecoder as OpusDecoderImpl } from 'opus-decoder'
import { OPUS_WASM_B64 } from './opus-wasm.b64'

type WebkitWindow = Window & { webkitAudioContext?: typeof AudioContext }

interface OpusWasmDecoder {
  ready: Promise<void>
  decodeFrame(frame: Uint8Array): { channelData: Float32Array[]; samplesDecoded: number; sampleRate: number }
  free(): void
}
type OpusDecoderCtor = new (opts?: { channels?: number }) => OpusWasmDecoder
const OpusDecoder = OpusDecoderImpl as unknown as OpusDecoderCtor & { module?: WebAssembly.Module }

// Compile the embedded Opus WASM once (shared across players) and hand it to
// opus-decoder as a precompiled module, so it never touches its own (stripped) string.
let ctorPromise: Promise<OpusDecoderCtor> | null = null
function loadOpusDecoder(): Promise<OpusDecoderCtor> {
  if (!ctorPromise) {
    ctorPromise = (async () => {
      if (!OpusDecoder.module) {
        const bin = Uint8Array.from(atob(OPUS_WASM_B64), (c) => c.charCodeAt(0))
        OpusDecoder.module = await WebAssembly.compile(bin)
      }
      return OpusDecoder
    })()
  }
  return ctorPromise
}

export class AudioPlayer {
  private ctx: AudioContext | null = null
  private gain: GainNode | null = null
  private enabled = false
  private dec: AudioDecoder | null = null // WebCodecs (Safari 26+, Chrome, etc.)
  private wdec: OpusWasmDecoder | null = null // WASM fallback (iOS Safari < 26)
  private wdecInit: Promise<void> | null = null
  private channels = 0
  private ts = 0 // synthetic 20ms-per-frame timestamp (Opus frames are 20ms)
  private playTime = 0
  // Decode via WebCodecs when present; otherwise the WASM fallback. Fixed per page.
  private readonly useWasm = typeof AudioDecoder === 'undefined'

  // gain lets the room-mic player run louder than the app-audio one (the daemon's
  // raw mic input is quiet without AGC).
  constructor(private gainValue = 0.75) {}

  // Wire the WebRTC audio DataChannel handed over by the engine on session open.
  attach(ch: RTCDataChannel) {
    ch.binaryType = 'arraybuffer'
    ch.onmessage = (ev) => this.onData(ev.data as ArrayBuffer)
    ch.onclose = () => this.closeDecoder()
  }

  private onData(buf: ArrayBuffer) {
    if (!this.enabled || !this.ctx) return // only decode while the user is listening
    const u = new Uint8Array(buf)
    const chn = u[0] || 1
    const opus = u.subarray(1)
    if (this.useWasm) {
      this.decodeWasm(chn, opus)
      return
    }
    if (this.dec && this.channels !== chn) this.closeDecoder() // mono<->stereo switch: rebuild
    if (!this.dec) {
      if (typeof AudioDecoder === 'undefined') return
      this.channels = chn
      try {
        this.dec = new AudioDecoder({
          output: (ad) => this.play(ad),
          error: () => this.closeDecoder(),
        })
        this.dec.configure({ codec: 'opus', sampleRate: 48000, numberOfChannels: chn })
        this.ts = 0
        this.playTime = 0
      } catch {
        this.dec = null
        return
      }
    }
    try {
      this.dec.decode(new EncodedAudioChunk({ type: 'key', timestamp: this.ts, data: opus }))
      this.ts += 20000
    } catch {
      /* ignore a bad frame */
    }
  }

  // WASM fallback: decode the Opus frame to deinterleaved PCM and schedule it. The
  // decoder is created lazily (compiling the WASM is async); frames are dropped until
  // it's ready, and rebuilt on a mono<->stereo switch.
  private decodeWasm(chn: number, opus: Uint8Array) {
    if (this.wdec && this.channels !== chn) {
      try {
        this.wdec.free()
      } catch {
        /* ignore */
      }
      this.wdec = null
      this.wdecInit = null
    }
    this.channels = chn
    if (!this.wdec) {
      if (!this.wdecInit) {
        this.wdecInit = loadOpusDecoder()
          .then(async (Ctor) => {
            const d = new Ctor({ channels: chn })
            await d.ready
            this.wdec = d
            this.playTime = 0
          })
          .catch(() => {
            this.wdecInit = null
          })
      }
      return // not ready yet -- drop this frame
    }
    let r
    try {
      r = this.wdec.decodeFrame(new Uint8Array(opus)) // own buffer, not a subarray view
    } catch {
      return
    }
    if (r.samplesDecoded > 0) this.schedule(r.channelData, r.sampleRate, r.samplesDecoded)
  }

  private play(ad: AudioData) {
    const n = ad.numberOfFrames
    const chn = ad.numberOfChannels
    const channels: Float32Array[] = []
    for (let c = 0; c < chn; c++) {
      const f = new Float32Array(n)
      try {
        ad.copyTo(f, { planeIndex: c, format: 'f32-planar' })
      } catch {
        /* ignore */
      }
      channels.push(f)
    }
    const rate = ad.sampleRate
    ad.close()
    this.schedule(channels, rate, n)
  }

  // Build an AudioBuffer from deinterleaved channels and schedule it on the jitter
  // buffer. Shared by both decode paths.
  private schedule(channels: Float32Array[], sampleRate: number, n: number) {
    const ctx = this.ctx
    if (!ctx || n <= 0 || channels.length === 0) return
    const ab = ctx.createBuffer(channels.length, n, sampleRate)
    for (let c = 0; c < channels.length; c++) ab.getChannelData(c).set(channels[c].subarray(0, n))
    const src = ctx.createBufferSource()
    src.buffer = ab
    src.connect(this.gain || ctx.destination)
    const now = ctx.currentTime
    if (this.playTime < now + 0.02) this.playTime = now + 0.18 // ~180ms jitter buffer (re)prime on underrun
    src.start(this.playTime)
    this.playTime += ab.duration
  }

  // Create/resume the AudioContext and start playing. Must be called from a user
  // gesture (browsers block autoplay). Returns whether playback is live.
  async resume(): Promise<boolean> {
    // iOS Safari silences Web Audio when the phone's ring/silent switch is on unless
    // the page claims a 'playback' audio session. No-op on browsers without the API.
    try {
      const session = (navigator as unknown as { audioSession?: { type: string } }).audioSession
      if (session) session.type = 'playback'
    } catch {
      /* ignore */
    }
    const AC = window.AudioContext || (window as WebkitWindow).webkitAudioContext
    if (!AC) return false
    if (!this.ctx) {
      try {
        this.ctx = new AC({ sampleRate: 48000 })
      } catch {
        this.ctx = new AC()
      }
    }
    if (!this.gain) {
      this.gain = this.ctx.createGain()
      this.gain.gain.value = this.gainValue
      this.gain.connect(this.ctx.destination)
    }
    try {
      await this.ctx.resume()
    } catch {
      /* ignore */
    }
    this.enabled = this.ctx.state === 'running' || (this.ctx.state as string) === 'interrupted'
    return this.enabled
  }

  // Stop playing (keeps the context for a fast re-enable).
  mute() {
    this.enabled = false
    this.closeDecoder()
  }

  private closeDecoder() {
    try {
      this.dec?.close()
    } catch {
      /* ignore */
    }
    this.dec = null
    // Keep the WASM decoder instance across mute/attach for fast re-enable; it's only
    // rebuilt on a channel-count change (see decodeWasm).
  }
}
