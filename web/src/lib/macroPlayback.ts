export type MacroEvent = { t: number; k: 't' | 'k'; p?: number; i?: number; x?: number; y?: number; u?: number; d?: number }
export type PlaybackState = 'playing' | 'pausing' | 'play-paused' | 'idle'

export function macroScript(events: MacroEvent[]) {
  const actions: Record<string, number | string>[] = []
  const held = new Map<string, MacroEvent>()
  let last = 0
  for (const e of events) {
    const at = Math.max(last, Math.round(e.t))
    if (at > last) actions.push({ type: 'wait', ms: at - last })
    if (e.k === 't') actions.push({ type: 'input', phase: e.p ?? 1, id: e.i ?? 0, x: e.x ?? 0, y: e.y ?? 0 })
    else actions.push({ type: 'input_key', p: 7, u: e.u ?? 0, d: e.d ?? 0 })
    const key = e.k === 't' ? `t${e.i ?? 0}` : `k${e.u ?? 0}`
    if (e.k === 't' ? e.p === 2 : e.d === 0 || e.d === 2) held.delete(key)
    else held.set(key, e)
    last = at
  }
  for (const e of held.values()) {
    if (e.k === 't') actions.push({ type: 'input', phase: 2, id: e.i ?? 0, x: e.x ?? 0, y: e.y ?? 0 })
    else actions.push({ type: 'input_key', p: 7, u: e.u ?? 0, d: 0 })
  }
  return { actions }
}

// Pause at a neutral input boundary, never leaving a synthetic finger or modifier
// held for an unbounded time. Stop releases everything immediately.
export class MacroPlayback {
  private cancel: (() => void) | null = null
  private pauseRequested = false

  pause() { this.pauseRequested = true }
  resume() { this.pauseRequested = false }
  stop() { this.cancel?.(); this.cancel = null; this.pauseRequested = false }

  async play(events: MacroEvent[], send: (event: MacroEvent) => void, state: (state: PlaybackState) => void) {
    this.stop()
    let stopped = false
    const held = new Map<string, MacroEvent>()
    const release = () => {
      for (const e of held.values()) send(e.k === 't' ? { ...e, p: 2 } : { ...e, d: 0 })
      held.clear()
    }
    const cancel = () => { stopped = true; release() }
    this.cancel = cancel
    let start = performance.now()
    let lastState: PlaybackState | null = null
    const notify = (value: PlaybackState) => { if (value !== lastState) { lastState = value; state(value) } }
    notify('playing')
    try {
      for (const event of events) {
        while (!stopped) {
          if (this.pauseRequested && held.size === 0) {
            notify('play-paused')
            const before = performance.now()
            await new Promise((resolve) => setTimeout(resolve, 25))
            start += performance.now() - before
            continue
          }
          notify(this.pauseRequested ? 'pausing' : 'playing')
          const wait = event.t - (performance.now() - start)
          if (wait <= 0) break
          await new Promise((resolve) => setTimeout(resolve, Math.min(wait, 25)))
        }
        if (stopped) return
        send(event)
        const key = event.k === 't' ? `t${event.i ?? 0}` : `k${event.u ?? 0}`
        if (event.k === 't' ? event.p === 2 : event.d === 0 || event.d === 2) held.delete(key)
        else held.set(key, event)
      }
    } finally {
      release()
      if (this.cancel === cancel) { this.cancel = null; notify('idle') }
    }
  }
}
