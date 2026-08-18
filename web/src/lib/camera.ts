import { RELAY_MODE, signalWS } from './rctl'

type CameraTransportCallbacks = {
  onState?: (state: string) => void
}

export class CameraTransport {
  private video: HTMLVideoElement
  private callbacks: CameraTransportCallbacks
  private pc: RTCPeerConnection | null = null
  private ws: WebSocket | null = null
  private stopped = true
  private retry = 0
  private disconnectGrace = 0
  private generation = 0

  constructor(video: HTMLVideoElement, callbacks: CameraTransportCallbacks = {}) {
    this.video = video
    this.callbacks = callbacks
  }

  start() {
    this.stopped = false
    this.retry = 0
    this.connect()
  }

  stop() {
    this.stopped = true
    this.generation++
    if (this.retry) window.clearTimeout(this.retry)
    if (this.disconnectGrace) window.clearTimeout(this.disconnectGrace)
    this.retry = 0
    this.disconnectGrace = 0
    this.ws?.close()
    this.pc?.close()
    this.ws = null
    this.pc = null
    this.video.srcObject = null
  }

  private scheduleReconnect() {
    if (this.stopped || this.retry) return
    this.callbacks.onState?.('reconnecting')
    this.retry = window.setTimeout(() => {
      this.retry = 0
      this.connect()
    }, 1200)
  }

  private connect() {
    if (this.stopped) return
    const generation = ++this.generation
    if (this.disconnectGrace) window.clearTimeout(this.disconnectGrace)
    this.disconnectGrace = 0
    this.ws?.close()
    this.pc?.close()
    this.callbacks.onState?.('connecting')

    const pc = new RTCPeerConnection({})
    this.pc = pc
    let remoteReady = false
    const pending: RTCIceCandidateInit[] = []
    const proto = location.protocol === 'https:' ? 'wss' : 'ws'
    const url = RELAY_MODE ? signalWS('camera') : `${proto}://${location.host}/ws/signal?media=camera`
    const ws = new WebSocket(url)
    this.ws = ws

    pc.ontrack = (event) => {
      if (generation !== this.generation) return
      this.video.srcObject = event.streams[0] || new MediaStream([event.track])
      this.video.play().catch(() => {})
      this.callbacks.onState?.('live')
    }
    pc.onicecandidate = (event) => {
      if (event.candidate && ws.readyState === WebSocket.OPEN)
        ws.send(JSON.stringify({
          kind: 'candidate',
          payload: { candidate: event.candidate.candidate, mid: event.candidate.sdpMid },
        }))
    }
    pc.onconnectionstatechange = () => {
      if (generation !== this.generation) return
      if (pc.connectionState === 'failed' || pc.connectionState === 'closed') {
        if (this.disconnectGrace) window.clearTimeout(this.disconnectGrace)
        this.disconnectGrace = 0
        this.scheduleReconnect()
      } else if (pc.connectionState === 'disconnected') {
        if (!this.disconnectGrace) {
          this.callbacks.onState?.('reconnecting')
          this.disconnectGrace = window.setTimeout(() => {
            this.disconnectGrace = 0
            if (generation === this.generation && pc.connectionState === 'disconnected')
              this.scheduleReconnect()
          }, 4000)
        }
      } else if (pc.connectionState === 'connected') {
        if (this.disconnectGrace) window.clearTimeout(this.disconnectGrace)
        this.disconnectGrace = 0
        this.callbacks.onState?.('connected')
      }
    }

    ws.onmessage = async (event) => {
      if (generation !== this.generation) return
      let message: { kind?: string; payload?: unknown }
      try {
        message = JSON.parse(event.data)
      } catch {
        return
      }
      if (message.kind === 'ready') {
        if (Array.isArray(message.payload) && message.payload.length) {
          try {
            pc.setConfiguration({ iceServers: message.payload as RTCIceServer[] })
          } catch {
            // Host candidates remain available.
          }
        }
      } else if (message.kind === 'offer') {
        try {
          const payload = message.payload as { sdp: string }
          await pc.setRemoteDescription({ type: 'offer', sdp: payload.sdp })
          remoteReady = true
          for (const candidate of pending.splice(0)) await pc.addIceCandidate(candidate).catch(() => {})
          const answer = await pc.createAnswer()
          await pc.setLocalDescription(answer)
          ws.send(JSON.stringify({ kind: 'answer', payload: { sdp: pc.localDescription?.sdp || '' } }))
        } catch {
          this.scheduleReconnect()
        }
      } else if (message.kind === 'candidate') {
        const payload = message.payload as { candidate?: string; mid?: string }
        const candidate = {
          candidate: (payload.candidate || '').replace(/^a=/, ''),
          sdpMid: payload.mid || '0',
        }
        if (remoteReady) await pc.addIceCandidate(candidate).catch(() => {})
        else pending.push(candidate)
      }
    }
    ws.onerror = () => this.scheduleReconnect()
    ws.onclose = () => {
      if (generation === this.generation) this.scheduleReconnect()
    }
  }
}
