// Text input keeps atomic taps. Only modifiers need a tracked release; this
// does not pretend to be a hardware-keyboard backend for games.
export class KeyboardState {
  private held = new Set<number>()
  private send: (usage: number, down: number) => void

  constructor(send: (usage: number, down: number) => void) {
    this.send = send
  }

  down(usage: number, repeat: boolean) {
    if (usage >= 0xe0 && usage <= 0xe7) {
      if (repeat || this.held.has(usage)) return
      this.held.add(usage)
      this.send(usage, 1)
    } else this.send(usage, 2)
  }

  up(usage: number): boolean {
    if (!this.held.delete(usage)) return false
    this.send(usage, 0)
    return true
  }

  release() {
    for (const usage of [...this.held]) this.up(usage)
  }
}
