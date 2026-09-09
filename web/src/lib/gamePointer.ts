export type PointerStatus = { mode: 'idle' | 'connecting' | 'active' | 'error'; available: boolean; error?: string }
export function pointerCaptureUnavailable(recording: boolean, keyboard: string, available: boolean, supported: boolean): string | undefined {
  if (!supported) return 'Mouse capture is not supported by this browser.'
  if (recording) return 'Mouse capture is unavailable during touch recording or playback.'
  if (keyboard === 'connecting') return 'Game keyboard is connecting.'
  if (keyboard === 'error') return 'Game keyboard is unavailable.'
  if (keyboard !== 'game') return 'Select Game keyboard first.'
  if (!available) return 'WebRTC mouse channel is unavailable.'
}
type State = { dx: number; dy: number; wheel: number; buttons: number; time: number }
type Pending = { resolve: (value: Record<string, unknown>) => void; reject: (error: Error) => void; timer: ReturnType<typeof setTimeout> }

// Movement is relative and never replayed after a reconnect. Button transitions
// keep their order, while movement between transitions is summed at 60 Hz.
export class GamePointer {
  status: PointerStatus = { mode: 'idle', available: false }
  private channel: RTCDataChannel | null = null
  private motionChannel: RTCDataChannel | null = null
  private motionSequence = 0
  private id = 0
  private requests = new Map<number, Pending>()
  private owner = ''
  private generation = 0
  private sequence = 0
  private buttons = 0
  private dx = 0
  private dy = 0
  private wheel = 0
  private motionAt = 0
  private queue: State[] = []
  private inFlight = 0
  private lastSent = 0
  private timer: ReturnType<typeof setInterval> | undefined
  private changed: (status: PointerStatus) => void

  constructor(changed: (status: PointerStatus) => void) { this.changed = changed }
  get active() { return this.status.mode === 'active' }
  private update(mode: PointerStatus['mode'], error?: string) {
    this.status = { mode, error, available: this.channel?.readyState === 'open' && this.motionChannel?.readyState === 'open' }
    this.changed(this.status)
  }
  private onOpen = () => this.update('idle')
  private onClose = () => {
    this.stop('Pointer connection lost')
    for (const p of this.requests.values()) { clearTimeout(p.timer); p.reject(new Error('Pointer connection lost')) }
    this.requests.clear()
  }
  private onMessage = (event: MessageEvent) => {
    if (typeof event.data !== 'string' || event.data.length > 2048) return
    try {
      const value = JSON.parse(event.data)
      if (!value || typeof value !== 'object') return
      const pending = this.requests.get(value.id)
      if (!pending) return
      this.requests.delete(value.id); clearTimeout(pending.timer)
      if (typeof value.error === 'string') pending.reject(new Error(value.error))
      else pending.resolve(value)
    } catch { /* malformed messages never acknowledge an input */ }
  }
  attach(channel: RTCDataChannel) {
    if (channel.label === 'pointer-motion') {
      if (this.motionChannel) { this.stop(); this.detachMotion() }
      this.motionChannel = channel
      channel.addEventListener('open', this.onOpen)
      channel.addEventListener('close', this.onClose)
      channel.addEventListener('error', this.onClose)
      this.update('idle')
      return
    }
    this.detachControl()
    this.channel = channel
    channel.addEventListener('open', this.onOpen)
    channel.addEventListener('close', this.onClose)
    channel.addEventListener('error', this.onClose)
    channel.addEventListener('message', this.onMessage)
    this.update('idle')
  }
  detach() {
    this.detachControl()
    this.detachMotion()
    this.update('idle')
  }
  private detachMotion() {
    const ch = this.motionChannel
    if (ch) {
      ch.removeEventListener('open', this.onOpen)
      ch.removeEventListener('close', this.onClose)
      ch.removeEventListener('error', this.onClose)
    }
    this.motionChannel = null
  }
  private detachControl() {
    this.stop()
    const ch = this.channel
    if (ch) {
      ch.removeEventListener('open', this.onOpen)
      ch.removeEventListener('close', this.onClose)
      ch.removeEventListener('error', this.onClose)
      ch.removeEventListener('message', this.onMessage)
    }
    this.channel = null
    for (const p of this.requests.values()) { clearTimeout(p.timer); p.reject(new Error('Pointer connection closed')) }
    this.requests.clear()
    this.update('idle')
  }
  private async request(body: Record<string, unknown>) {
    const ch = this.channel
    if (!ch || ch.readyState !== 'open') throw new Error('Pointer requires an active WebRTC connection')
    if (ch.bufferedAmount > 2048 || this.requests.size >= 4 || this.id >= 0xffffffff) throw new Error('Pointer connection is too slow')
    const id = ++this.id
    const value = await new Promise<Record<string, unknown>>((resolve, reject) => {
      const timer = setTimeout(() => { this.requests.delete(id); reject(new Error('Pointer response timed out')) }, 1400)
      this.requests.set(id, { resolve, reject, timer })
      try { ch.send(JSON.stringify({ ...body, id })) }
      catch (error) { clearTimeout(timer); this.requests.delete(id); reject(error) }
    })
    if (value.ok !== true || value.pointer_version !== 1 || value.lease_ms !== 1500 ||
        value.active !== (body.action !== 'release') || !Number.isSafeInteger(value.sequence) ||
        (body.action === 'state' && value.sequence !== body.sequence)) throw new Error('Invalid pointer response')
  }
  async start() {
    if (this.active || this.status.mode === 'connecting') return
    const generation = ++this.generation
    const owner = Array.from(crypto.getRandomValues(new Uint8Array(16)), b => b.toString(16).padStart(2, '0')).join('')
    this.owner = owner; this.sequence = this.motionSequence = 0
    this.update('connecting')
    try {
      if (!this.status.available) throw new Error('WebRTC mouse channels are unavailable')
      await this.request({ action: 'acquire', owner })
      if (generation !== this.generation) { void this.request({ action: 'release', owner }).catch(() => {}); return }
      this.lastSent = performance.now()
      this.update('active')
      this.timer = setInterval(() => {
        this.flushMotion()
        if (this.inFlight >= 2) return
        if (!this.queue.length && performance.now() - this.lastSent >= 300) this.enqueue(0, 0, 0)
        void this.flush()
      }, 16)
    } catch (e) {
      if (generation === this.generation) this.stop(e instanceof Error ? e.message : 'Pointer unavailable')
    }
  }
  move(dx: number, dy: number, wheel = 0) {
    if (!this.active) return
    if (![dx, dy, wheel].every(Number.isFinite)) return
    if (!this.motionAt) this.motionAt = performance.now()
    this.dx += dx; this.dy += dy; this.wheel += wheel
    if (Math.abs(this.dx) > 2048 || Math.abs(this.dy) > 2048 || Math.abs(this.wheel) > 120) this.stop('Pointer input exceeded the safe buffer')
  }
  button(button: number, down: boolean) {
    if (!this.active || !Number.isInteger(button) || button < 0 || button > 4) return
    // DOM: left/middle/right; HID: left/right/middle.
    const mask = [1, 4, 2, 8, 16][button]
    const next = down ? this.buttons | mask : this.buttons & ~mask
    if (next === this.buttons) return
    this.flushMotion()
    if (!this.active) return
    this.buttons = next
    this.enqueue(0, 0, 0)
    void this.flush()
  }
  stop(error?: string) {
    const owner = this.owner
    this.owner = ''; ++this.generation
    clearInterval(this.timer); this.timer = undefined
    this.queue = []; this.dx = this.dy = this.wheel = this.motionAt = this.buttons = 0
    this.inFlight = 0
    this.update(error ? 'error' : 'idle', error)
    if (owner) void this.request({ action: 'release', owner }).catch(() => {})
  }
  private enqueue(dx: number, dy: number, wheel: number, time = performance.now()) {
    if (this.queue.length >= 16) { this.stop('Pointer connection is too slow'); return }
    this.queue.push({ dx, dy, wheel, buttons: this.buttons, time })
  }
  private flushMotion() {
    if (!this.active || !(this.dx || this.dy || this.wheel)) return
    const ch = this.motionChannel
    // A lost delta is preferable to a delayed camera jump. Motion never waits
    // for an acknowledgement and cannot change held buttons or renew the lease.
    if (ch?.readyState === 'open' && ch.bufferedAmount <= 2048 && performance.now() - this.motionAt <= 150) {
      if (this.motionSequence >= 0xffffffff) { this.stop('Pointer sequence exhausted'); return }
      const sequence = ++this.motionSequence
      try {
        ch.send(JSON.stringify({ action: 'move', owner: this.owner, id: sequence, sequence,
          dx: this.dx, dy: this.dy, wheel: this.wheel }))
      } catch { this.stop('Pointer connection lost') }
    }
    this.dx = this.dy = this.wheel = this.motionAt = 0
  }
  private flush() {
    if (!this.active) return
    const generation = this.generation
    while (this.inFlight < 2 && this.queue.length && this.active) {
      const state = this.queue.shift()!
      // Network jitter may outlive a motion sample. Drop its deltas, but keep
      // the held-button snapshot so a queued release cannot get lost.
      if (performance.now() - state.time > 150) state.dx = state.dy = state.wheel = 0
      const { time: _, ...input } = state
      this.lastSent = performance.now()
      ++this.inFlight
      void this.request({ action: 'state', owner: this.owner, sequence: ++this.sequence, ...input })
        .catch(e => {
          if (generation === this.generation) this.stop(e instanceof Error ? e.message : 'Pointer unavailable')
        })
        .finally(() => {
          if (generation === this.generation) { --this.inFlight; this.flush() }
        })
    }
  }
}
