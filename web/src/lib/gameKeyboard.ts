export type GameKeyboardStatus = { mode: 'text' | 'connecting' | 'game' | 'error'; error?: string }
type Request = (body: Record<string, unknown>) => Promise<void>

export function validateKeyboardResponse(value: unknown, action: unknown): void {
  if (!value || typeof value !== 'object') throw new Error('keyboard_unavailable')
  const result = value as Record<string, unknown>
  if (typeof result.error === 'string') throw new Error(result.error)
  // Older devices may return a generic success for an unknown endpoint.
  if (result.ok !== true || result.active !== (action !== 'release') ||
      result.lease_ms !== 1500 || !Number.isSafeInteger(result.sequence) ||
      (result.sequence as number) < 0) throw new Error('keyboard_unavailable')
}

function newOwner(): string {
  return Array.from(crypto.getRandomValues(new Uint8Array(16)), b => b.toString(16).padStart(2, '0')).join('')
}

// The device owns expiry. Browser cleanup improves responsiveness but is not
// relied on for key-up after a closed tab, suspended computer or severed link.
export class GameKeyboard {
  status: GameKeyboardStatus = { mode: 'text' }
  private owner = ''
  private generation = 0
  private sequence = 0
  private held = new Set<number>()
  private pending: number[][] = []
  private sending = false
  private heartbeat: ReturnType<typeof setInterval> | undefined
  private request: Request
  private changed: (status: GameKeyboardStatus) => void
  private makeOwner: () => string

  constructor(request: Request, changed: (status: GameKeyboardStatus) => void, makeOwner = newOwner) {
    this.request = request
    this.changed = changed
    this.makeOwner = makeOwner
  }

  get enabled() { return this.status.mode !== 'text' }

  private update(status: GameKeyboardStatus) {
    this.status = status
    this.changed(status)
  }

  async start() {
    if (this.status.mode === 'game' || this.status.mode === 'connecting') return
    const generation = ++this.generation
    const owner = this.makeOwner()
    this.owner = owner
    this.sequence = 0
    this.update({ mode: 'connecting' })
    try {
      await this.request({ action: 'acquire', owner })
      if (generation !== this.generation) {
        await this.request({ action: 'release', owner }).catch(() => {})
        return
      }
      this.update({ mode: 'game' })
      this.heartbeat = setInterval(() => {
        if (!this.sending && !this.pending.length) this.enqueue()
      }, 400)
      this.enqueue()
    } catch (error) {
      if (generation === this.generation) this.stop(error instanceof Error ? error.message : 'keyboard_connection_failed')
    }
  }

  down(usage: number, repeat: boolean) {
    if (this.status.mode !== 'game' || repeat || this.held.has(usage)) return
    if (!Number.isInteger(usage) || usage < 4 || usage > 231 || (usage > 164 && usage < 224)) return
    if (this.held.size >= 32) { this.stop('keyboard_key_limit'); return }
    this.held.add(usage)
    this.enqueue()
  }

  up(usage: number) {
    if (!this.held.delete(usage)) return false
    this.enqueue()
    return true
  }

  releaseKeys() {
    if (!this.held.size) return
    this.held.clear()
    this.enqueue()
  }

  stop(error?: string) {
    const owner = this.owner
    ++this.generation
    this.owner = ''
    this.held.clear()
    this.pending = []
    this.sending = false
    clearInterval(this.heartbeat)
    this.heartbeat = undefined
    this.update(error ? { mode: 'error', error } : { mode: 'text' })
    if (owner) void this.request({ action: 'release', owner }).catch(() => {})
  }

  private enqueue() {
    if (this.status.mode !== 'game') return
    // Preserve short down/up transitions, not only the final held snapshot.
    if (this.pending.length >= 16) { this.stop('keyboard_connection_too_slow'); return }
    this.pending.push([...this.held].sort((a, b) => a - b))
    void this.flush()
  }

  private async flush() {
    if (this.sending || !this.pending.length || this.status.mode !== 'game') return
    const generation = this.generation
    this.sending = true
    try {
      while (generation === this.generation && this.pending.length) {
        const keys = this.pending.shift()!
        await this.request({ action: 'state', owner: this.owner, sequence: ++this.sequence, keys })
      }
    } catch (error) {
      if (generation === this.generation) this.stop(error instanceof Error ? error.message : 'keyboard_connection_failed')
    } finally {
      if (generation === this.generation) this.sending = false
    }
  }
}
