// Browser microphone -> Opus -> the "mic-in" WebRTC DataChannel (browser->device).
// Phase B.5 intercom: the device decodes each Opus frame and plays it through the
// iPad speaker. The same path will later feed the virtual-mic injection.
//
// Capture pipeline: getUserMedia -> MediaStreamTrackProcessor (AudioData frames) ->
// WebCodecs AudioEncoder (Opus, mono 48k) -> send each encoded frame on the channel.
// getUserMedia needs a secure context, so this works over the relay (HTTPS); local
// plain-HTTP needs the device-HTTPS phase.

type TrackProcCtor = new (init: { track: MediaStreamTrack }) => { readable: ReadableStream<AudioData> }

export function micSupported(): boolean {
  return (
    typeof AudioEncoder !== 'undefined' &&
    typeof (globalThis as { MediaStreamTrackProcessor?: unknown }).MediaStreamTrackProcessor !== 'undefined' &&
    !!navigator.mediaDevices?.getUserMedia
  )
}

export class MicTalk {
  private ch: RTCDataChannel | null = null
  private stream: MediaStream | null = null
  private enc: AudioEncoder | null = null
  private reader: ReadableStreamDefaultReader<AudioData> | null = null
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
  // isn't open, or permission is denied.
  async start(): Promise<boolean> {
    if (this.active) return true
    if (!this.ready() || !micSupported()) return false
    try {
      this.stream = await navigator.mediaDevices.getUserMedia({
        audio: { channelCount: 1, sampleRate: 48000, echoCancellation: true, noiseSuppression: true, autoGainControl: true },
      })
    } catch {
      return false
    }
    const track = this.stream.getAudioTracks()[0]
    if (!track) {
      this.stop()
      return false
    }
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
    this.active = true
    this.onState(true)
    const Proc = (globalThis as unknown as { MediaStreamTrackProcessor: TrackProcCtor }).MediaStreamTrackProcessor
    this.reader = new Proc({ track }).readable.getReader()
    this.pump()
    return true
  }

  private async pump() {
    while (this.active && this.reader) {
      let res: ReadableStreamReadResult<AudioData>
      try {
        res = await this.reader.read()
      } catch {
        break
      }
      if (res.done) break
      const data = res.value
      if (this.enc && this.enc.state === 'configured') {
        try {
          this.enc.encode(data)
        } catch {
          /* ignore */
        }
      }
      data.close()
    }
  }

  stop() {
    if (!this.active && !this.stream) return
    this.active = false
    try {
      this.reader?.cancel()
    } catch {
      /* ignore */
    }
    this.reader = null
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
    this.onState(false)
  }
}
