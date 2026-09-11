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
  private pending = false
  private generation = 0
  onState: (talking: boolean) => void = () => {}
  onPending: (pending: boolean) => void = () => {}
  onError: (message: string) => void = () => {}

  attach(ch: RTCDataChannel) {
    if (this.ch === ch) return
    if (this.active || this.pending) this.fail('Talk stopped because the device connection changed. Try again.')
    this.ch = ch
    ch.binaryType = 'arraybuffer'
    ch.onclose = () => {
      if (this.ch !== ch) return
      this.ch = null
      if (this.active || this.pending) this.fail('Talk stopped because the device connection closed. Reconnect and try again.')
    }
  }

  private fail(message: string): false {
    this.stop()
    this.onError(message)
    return false
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
        void ctx.close().catch(() => {})
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
      let ad: AudioData | null = null
      try {
        ad = new AudioData({
          format: 'f32-planar',
          sampleRate: 48000,
          numberOfFrames: f.length,
          numberOfChannels: 1,
          timestamp: this.ts,
          data: f,
        })
        this.ts += Math.round((f.length / 48000) * 1e6)
        this.enc.encode(ad)
      } catch {
        this.fail('Microphone audio encoding failed. Stop other microphone sessions and try again.')
      } finally {
        ad?.close()
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
    if (this.pending) return false
    if (!micSupported()) return this.fail('Talk requires HTTPS and browser support for microphone capture and Opus encoding.')
    if (!this.ready()) return this.fail('The microphone connection is not ready. Wait for the device to connect and try again.')
    const generation = ++this.generation
    const channel = this.ch!
    const current = () => generation === this.generation && this.ch === channel
    const fail = (message: string) => current() ? this.fail(message) : false
    this.pending = true
    this.onError('')
    this.onPending(true)
    // getUserMedia FIRST: Safari pins an AudioContext's sample rate to the active
    // audio session, so the mic must be live before we build the 48kHz context --
    // otherwise Safari hands back a 44.1kHz context and ensureGraph() would reject it.
    try {
      const stream = await navigator.mediaDevices.getUserMedia({
        // The destination calling app applies its own voice processing after
        // injection. Browser AEC/NS/AGC here would process the signal twice and
        // can erase non-speech audio before it ever reaches the iPad.
        audio: { channelCount: 1, echoCancellation: false, noiseSuppression: false, autoGainControl: false },
      })
      if (!current()) {
        stream.getTracks().forEach((track) => track.stop())
        return false
      }
      this.stream = stream
    } catch (error) {
      const name = error instanceof Error ? error.name : ''
      return fail(name === 'NotAllowedError'
        ? 'Microphone permission was denied. Allow microphone access for this site and try again.'
        : name === 'NotFoundError'
          ? 'No microphone is available on this computer.'
          : 'The browser could not open the microphone. Check its permissions and other audio applications.')
    }
    const track = this.stream.getAudioTracks()[0]
    if (!track || track.readyState === 'ended') {
      return fail('The browser microphone is no longer available.')
    }
    track.addEventListener('ended', () => {
      if (current()) fail('The browser microphone was disconnected or its permission was revoked.')
    }, { once: true })
    try {
      if (!this.ensureGraph()) return fail('This browser could not start microphone audio at 48 kHz. Check the audio input device and try again.')
      await this.ctx!.resume()
      if (!current()) {
        if (!this.active && !this.pending) void this.ctx!.suspend().catch(() => {})
        return false
      }
      if (this.ctx!.state !== 'running') return fail('Microphone audio is suspended by the browser. Click Talk again to resume.')
    } catch {
      return fail('The browser could not start microphone audio playback processing.')
    }
    // A fresh encoder per talk: configuring then closing then reusing one is fragile.
    try {
      const config = { codec: 'opus', sampleRate: 48000, numberOfChannels: 1, bitrate: 24000 }
      if (typeof AudioEncoder.isConfigSupported === 'function') {
        const support = await AudioEncoder.isConfigSupported(config)
        if (!current()) return false
        if (!support.supported) return fail('This browser does not support Opus microphone encoding. Try a browser with Opus encoding support.')
      }
      this.enc = new AudioEncoder({
        output: (chunk) => {
          if (!current() || !this.active || channel.readyState !== 'open') return
          const buf = new ArrayBuffer(chunk.byteLength)
          chunk.copyTo(buf)
          try {
            channel.send(buf)
          } catch {
            fail('Talk stopped because microphone audio could not be sent to the device.')
          }
        },
        error: () => { fail('Opus microphone encoding failed in this browser. Stop other microphone sessions and try again.') },
      })
      this.enc.configure(config)
      if (!current()) return false
      this.ts = 0
      this.src = this.ctx!.createMediaStreamSource(this.stream!)
      this.src.connect(this.node!)
    } catch {
      return fail('The browser could not configure microphone audio encoding.')
    }
    this.active = true
    this.pending = false
    this.onPending(false)
    this.onState(true)
    return true
  }

  stop() {
    ++this.generation
    this.active = false
    this.pending = false
    this.onPending(false)
    this.onError('')
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
      void this.ctx?.suspend().catch(() => {})
    } catch {
      /* ignore */
    }
    this.onState(false)
  }
}
