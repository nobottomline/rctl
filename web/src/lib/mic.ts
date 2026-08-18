// Browser microphone -> Opus -> the "mic-in" WebRTC DataChannel (browser->device).
// The device decodes each frame once and routes PCM to its speaker, the active
// calling app's microphone input, or both.
//
// Capture is done with WebAudio (getUserMedia -> ScriptProcessor -> Float32 PCM)
// rather than MediaStreamTrackProcessor, which is Chromium-only -- so Talk works in
// Safari/Firefox too. Each PCM chunk becomes an AudioData and is Opus-encoded with
// WebCodecs (Safari 16.4+ / Chrome). getUserMedia + WebCodecs need a secure context,
// so this runs over the relay's HTTPS.

type AnyCtx = typeof AudioContext

export function micSupported(): boolean {
  return (
    typeof AudioEncoder !== 'undefined' &&
    typeof AudioData !== 'undefined' &&
    !!navigator.mediaDevices?.getUserMedia
  )
}

export class MicTalk {
  private ch: RTCDataChannel | null = null
  private stream: MediaStream | null = null // per-talk mic capture
  private ctx: AudioContext | null = null // built once, reused across toggles
  private node: ScriptProcessorNode | null = null // persistent, lives with ctx (must stay referenced or it stops firing)
  private src: MediaStreamAudioSourceNode | null = null // per-talk
  private enc: AudioEncoder | null = null // per-talk
  private ts = 0 // running µs timestamp for the encoder
  private active = false
  onState: (talking: boolean) => void = () => {}

  attach(ch: RTCDataChannel) {
    this.ch = ch
    ch.binaryType = 'arraybuffer'
    ch.onclose = () => {
      if (this.ch === ch) this.ch = null
      this.stop()
    }
  }

  ready() {
    return !!this.ch && this.ch.readyState === 'open'
  }

  // Build the AudioContext + processing graph ONCE and keep it for the page's life.
  // Safari goes silent if you close() a context and spin up a fresh one for the next
  // talk, so we reuse a single context (suspend/resume) and only swap the mic source
  // per toggle. Returns false if the browser won't give a 48kHz context (Opus needs
  // 48k -- bail rather than ship a wrong-rate, chipmunk feed).
  private ensureGraph(): boolean {
    if (this.ctx) return true
    const AC: AnyCtx = window.AudioContext || (window as unknown as { webkitAudioContext: AnyCtx }).webkitAudioContext
    let ctx: AudioContext
    try {
      ctx = new AC({ sampleRate: 48000 })
    } catch {
      return false
    }
    if (ctx.sampleRate !== 48000) {
      try {
        ctx.close()
      } catch {
        /* ignore */
      }
      return false
    }
    const node = ctx.createScriptProcessor(2048, 1, 1)
    const mute = ctx.createGain()
    mute.gain.value = 0 // process without routing the mic to the local speakers
    node.onaudioprocess = (e) => {
      if (!this.active || !this.enc || this.enc.state !== 'configured') return
      const f = new Float32Array(e.inputBuffer.getChannelData(0)) // copy: the buffer is reused
      try {
        const ad = new AudioData({
          format: 'f32-planar',
          sampleRate: 48000,
          numberOfFrames: f.length,
          numberOfChannels: 1,
          timestamp: this.ts,
          data: f,
        })
        this.ts += Math.round((f.length / 48000) * 1e6)
        this.enc.encode(ad)
        ad.close()
      } catch {
        /* ignore a bad frame */
      }
    }
    node.connect(mute)
    mute.connect(ctx.destination)
    this.ctx = ctx
    this.node = node
    return true
  }

  // Begin capturing + streaming the mic. Resolves false if unsupported, the channel
  // isn't open, permission is denied, or no 48kHz context is available.
  async start(): Promise<boolean> {
    if (this.active) return true
    if (!this.ready() || !micSupported()) return false
    // getUserMedia FIRST: Safari pins an AudioContext's sample rate to the active
    // audio session, so the mic must be live before we build the 48kHz context --
    // otherwise Safari hands back a 44.1kHz context and ensureGraph() would reject it.
    try {
      this.stream = await navigator.mediaDevices.getUserMedia({
        audio: { channelCount: 1, echoCancellation: true, noiseSuppression: true, autoGainControl: true },
      })
    } catch {
      this.stop()
      return false
    }
    if (!this.stream.getAudioTracks()[0]) {
      this.stop()
      return false
    }
    if (!this.ensureGraph()) {
      this.stop()
      return false
    }
    try {
      await this.ctx!.resume()
    } catch {
      /* ignore */
    }
    // A fresh encoder per talk: configuring then closing then reusing one is fragile.
    try {
      this.enc = new AudioEncoder({
        output: (chunk) => {
          if (!this.ch || this.ch.readyState !== 'open') return
          const buf = new ArrayBuffer(chunk.byteLength)
          chunk.copyTo(buf)
          try {
            this.ch.send(buf)
          } catch {
            /* ignore */
          }
        },
        error: () => this.stop(),
      })
      this.enc.configure({ codec: 'opus', sampleRate: 48000, numberOfChannels: 1, bitrate: 24000 })
    } catch {
      this.stop()
      return false
    }
    this.ts = 0
    this.src = this.ctx!.createMediaStreamSource(this.stream)
    this.src.connect(this.node!)
    this.active = true
    this.onState(true)
    return true
  }

  stop() {
    this.active = false
    try {
      this.src?.disconnect()
    } catch {
      /* ignore */
    }
    this.src = null
    try {
      if (this.enc && this.enc.state !== 'closed') this.enc.close()
    } catch {
      /* ignore */
    }
    this.enc = null
    try {
      this.stream?.getTracks().forEach((t) => t.stop())
    } catch {
      /* ignore */
    }
    this.stream = null
    // Keep ctx/node/mute alive for the next talk; just idle the graph. Recreating the
    // context is what silences Safari, so we never close it here.
    try {
      this.ctx?.suspend()
    } catch {
      /* ignore */
    }
    this.onState(false)
  }
}
