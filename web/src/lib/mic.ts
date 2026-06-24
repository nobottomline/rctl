// Browser microphone -> Opus -> the "mic-in" WebRTC DataChannel (browser->device).
// Phase B.5 intercom: the device decodes each Opus frame and plays it through the
// iPad speaker. The same path will later feed the virtual-mic injection.
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
  private stream: MediaStream | null = null
  private ctx: AudioContext | null = null
  private src: MediaStreamAudioSourceNode | null = null
  private node: ScriptProcessorNode | null = null
  private mute: GainNode | null = null
  private enc: AudioEncoder | null = null
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

  // Begin capturing + streaming the mic. Resolves false if unsupported, the channel
  // isn't open, permission is denied, or the browser won't give a 48kHz context
  // (Opus only accepts 48k here).
  async start(): Promise<boolean> {
    if (this.active) return true
    if (!this.ready() || !micSupported()) return false
    try {
      this.stream = await navigator.mediaDevices.getUserMedia({
        audio: { channelCount: 1, echoCancellation: true, noiseSuppression: true, autoGainControl: true },
      })
    } catch {
      return false
    }
    if (!this.stream.getAudioTracks()[0]) {
      this.stop()
      return false
    }
    const AC: AnyCtx = window.AudioContext || (window as unknown as { webkitAudioContext: AnyCtx }).webkitAudioContext
    try {
      this.ctx = new AC({ sampleRate: 48000 })
    } catch {
      this.stop()
      return false
    }
    if (this.ctx.sampleRate !== 48000) {
      // Opus needs a 48k stream; bail rather than ship a wrong-rate (chipmunk) feed.
      this.stop()
      return false
    }
    try {
      await this.ctx.resume()
    } catch {
      /* ignore */
    }
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
    this.active = true
    this.onState(true)
    this.src = this.ctx.createMediaStreamSource(this.stream)
    this.node = this.ctx.createScriptProcessor(2048, 1, 1)
    this.mute = this.ctx.createGain()
    this.mute.gain.value = 0 // process without routing the mic to the speakers
    this.node.onaudioprocess = (e) => {
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
    this.src.connect(this.node)
    this.node.connect(this.mute)
    this.mute.connect(this.ctx.destination)
    return true
  }

  stop() {
    this.active = false
    if (this.node) this.node.onaudioprocess = null
    try {
      this.src?.disconnect()
    } catch {
      /* ignore */
    }
    try {
      this.node?.disconnect()
    } catch {
      /* ignore */
    }
    try {
      this.mute?.disconnect()
    } catch {
      /* ignore */
    }
    try {
      if (this.enc && this.enc.state !== 'closed') this.enc.close()
    } catch {
      /* ignore */
    }
    try {
      this.ctx?.close()
    } catch {
      /* ignore */
    }
    try {
      this.stream?.getTracks().forEach((t) => t.stop())
    } catch {
      /* ignore */
    }
    this.src = null
    this.node = null
    this.mute = null
    this.enc = null
    this.ctx = null
    this.stream = null
    this.onState(false)
  }
}
