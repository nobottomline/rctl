// Browser-side playback of the iPad's captured audio. The device encodes its
// output as Opus and sends each frame over the WebRTC "audio" DataChannel as
// [1B channel count][Opus frame] (a DataChannel, NOT a media track -- a 2nd SRTP
// stream kills all media RTP on the iOS libsrtp backend). WebCodecs decodes the
// Opus; a ~180ms Web Audio jitter buffer schedules playback. The AudioContext
// runs at 48kHz to match Opus so buffers aren't per-frame resampled (that hissed).
//
// Faithful port of the vanilla page's setupAudioChannel/playRtcAudio/ensureAudio.

type WebkitWindow = Window & { webkitAudioContext?: typeof AudioContext }

export class AudioPlayer {
  private ctx: AudioContext | null = null
  private gain: GainNode | null = null
  private enabled = false
  private dec: AudioDecoder | null = null
  private channels = 0
  private ts = 0 // synthetic 20ms-per-frame timestamp (Opus frames are 20ms)
  private playTime = 0

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

  private play(ad: AudioData) {
    const ctx = this.ctx
    if (!ctx) {
      ad.close()
      return
    }
    const n = ad.numberOfFrames
    const chn = ad.numberOfChannels
    const ab = ctx.createBuffer(chn, n, ad.sampleRate)
    for (let c = 0; c < chn; c++) {
      const f = new Float32Array(n)
      try {
        ad.copyTo(f, { planeIndex: c, format: 'f32-planar' })
      } catch {
        /* ignore */
      }
      ab.getChannelData(c).set(f)
    }
    ad.close()
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
      this.gain.gain.value = 0.75
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
  }
}
