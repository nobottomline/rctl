export type GuestResult = Record<string, unknown>
export interface GuestTransfer { transfer: string; size: number; name: string }
export interface GuestWriter { write: (data: Uint8Array<ArrayBuffer>) => Promise<void>; close: () => Promise<void>; abort: () => Promise<void> }
export const guestEncode = (bytes: Uint8Array) => btoa(Array.from(bytes, (byte) => String.fromCharCode(byte)).join(''))
export const guestDecode = (value: string) => Uint8Array.from(atob(value), (character) => character.charCodeAt(0))

// Correlated, bounded requests over the session's own channel. Closing rejects
// every waiter and drops late replies; a replacement never inherits work.
export class GuestOperations {
  private channel: RTCDataChannel | null = null
  private sequence = 0
  private closed = false
  private queued = 0
  private queue: Promise<unknown> = Promise.resolve()
  private pending = new Map<number, { resolve: (value: never) => void; reject: (error: Error) => void; timer: number }>()
  onReady: (ready: boolean) => void = () => {}
  attach(channel: RTCDataChannel) {
    this.stop()
    this.closed = false
    this.channel = channel
    channel.onopen = () => { if (this.channel === channel) this.onReady(true) }
    channel.onmessage = (event) => {
      if (this.channel !== channel || this.closed || typeof event.data !== 'string' || event.data.length > 65536) return
      try {
        const message = JSON.parse(event.data) as { id: number; result?: never; error?: string }
        const pending = this.pending.get(message.id)
        if (!pending) return
        this.pending.delete(message.id); clearTimeout(pending.timer)
        if (message.error) pending.reject(new Error(message.error.replaceAll('_', ' ')))
        else pending.resolve(message.result!)
      } catch { this.stop() }
    }
    channel.onclose = () => { if (this.channel === channel) this.stop() }
    if (channel.readyState === 'open') this.onReady(true)
  }
  call<T = GuestResult>(op: string, args: Record<string, unknown> = {}): Promise<T> {
    if (this.queued >= 16) return Promise.reject(new Error('Connection is busy'))
    this.queued++
    const generation = this.channel
    const run = () => new Promise<T>((resolve, reject) => {
      if (this.closed || !generation || generation !== this.channel || generation.readyState !== 'open') { reject(new Error('Device connection is closed')); return }
      if (generation.bufferedAmount > 65536) { reject(new Error('Connection is busy')); return }
      const id = ++this.sequence
      const value = JSON.stringify({ id, op, args })
      if (new TextEncoder().encode(value).length > 49152) { reject(new Error('Request is too large')); return }
      const timer = window.setTimeout(() => { this.pending.delete(id); reject(new Error('Device did not respond')); }, 12000)
      this.pending.set(id, { resolve: resolve as (value: never) => void, reject, timer })
      try { generation.send(value) } catch { this.pending.delete(id); clearTimeout(timer); reject(new Error('Device connection is closed')) }
    })
    const result = this.queue.then(run, run).finally(() => { this.queued-- })
    this.queue = result.catch(() => {})
    return result
  }
  async confirmed<T = GuestResult>(operation: string, args: Record<string, unknown> = {}): Promise<T> {
    const result = await this.call<{ token: string }>('confirmation.issue', { operation, args })
    return this.call<T>(operation, { ...args, token: result.token })
  }
  stop() {
    this.closed = true
    this.channel = null
    for (const pending of this.pending.values()) { clearTimeout(pending.timer); pending.reject(new Error('Access ended')) }
    this.pending.clear(); this.onReady(false)
  }
  async read(transfer: GuestTransfer, maxBytes = 64 * 1024 * 1024, signal?: AbortSignal): Promise<Blob> {
    if (transfer.size > maxBytes) { await this.call('transfer.close', { transfer: transfer.transfer }); throw new Error('This preview exceeds the browser memory limit') }
    const chunks: Uint8Array<ArrayBuffer>[] = []
    let offset = 0
    try {
      while (offset < transfer.size) {
        signal?.throwIfAborted()
        const result = await this.call<{ data: string; offset: number; eof: boolean }>('transfer.read', { transfer: transfer.transfer, offset })
        signal?.throwIfAborted()
        const bytes = guestDecode(result.data)
        if (!bytes.length || result.offset !== offset || offset + bytes.length > transfer.size) throw new Error('Incomplete transfer')
        chunks.push(bytes); offset += bytes.length
      }
      return new Blob(chunks)
    } finally { await this.call('transfer.close', { transfer: transfer.transfer }).catch(() => {}) }
  }
  async save(transfer: GuestTransfer, destination: GuestWriter | (() => Promise<GuestWriter>), signal?: AbortSignal, progress?: (fraction: number) => void) {
    let offset = 0
    let writer: GuestWriter | undefined
    try {
      signal?.throwIfAborted()
      // Opening the destination is part of transfer ownership: a rejected
      // picker writer must still release the admitted device descriptor.
      writer = typeof destination === 'function' ? await destination() : destination
      while (offset < transfer.size) {
        signal?.throwIfAborted()
        const result = await this.call<{ data: string; offset: number }>('transfer.read', { transfer: transfer.transfer, offset })
        signal?.throwIfAborted()
        const bytes = guestDecode(result.data)
        if (!bytes.length || result.offset !== offset || offset + bytes.length > transfer.size) throw new Error('Incomplete transfer')
        await writer.write(bytes); offset += bytes.length; progress?.(transfer.size ? offset / transfer.size : 1)
      }
      signal?.throwIfAborted(); await writer.close()
    } catch (error) { await writer?.abort().catch(() => {}); throw error }
    finally { await this.call('transfer.close', { transfer: transfer.transfer }).catch(() => {}) }
  }
  async upload(file: File, path: string, overwrite: boolean, signal?: AbortSignal, progress?: (fraction: number) => void) {
    await this.call('files.upload.begin', { path, size: file.size, overwrite })
    try {
      for (let offset = 0; offset < file.size; offset += 24576) {
        signal?.throwIfAborted()
        const bytes = new Uint8Array(await file.slice(offset, offset + 24576).arrayBuffer())
        await this.call('files.upload.chunk', { offset, data: guestEncode(bytes) })
        progress?.(Math.min(1, (offset + bytes.length) / file.size))
      }
      signal?.throwIfAborted(); await this.call('files.upload.commit')
    } catch (error) { await this.call('files.upload.cancel').catch(() => {}); throw error }
  }
}
