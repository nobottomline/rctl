import { useEffect, useRef, useState, type RefObject } from 'react'
import { ControlEngine, codeToUsage, MOD_USAGES } from '../lib/engine'

// Wires the imperative ControlEngine to React: creates it against the stage +
// canvas elements, attaches pointer/keyboard input + window resize, and surfaces
// status/orientation + action callbacks. All the delicate behavior lives in the
// engine; this hook is just the React lifecycle + DOM event plumbing.
export function useControl(
  stageRef: RefObject<HTMLDivElement | null>,
  canvasRef: RefObject<HTMLCanvasElement | null>,
) {
  const [status, setStatus] = useState('connecting…')
  const [orient, setOrient] = useState<{ o: number; manual: boolean }>({ o: 1, manual: false })
  const engineRef = useRef<ControlEngine | null>(null)

  useEffect(() => {
    const stage = stageRef.current
    const canvas = canvasRef.current
    if (!stage || !canvas) return

    const video = document.createElement('video')
    const engine = new ControlEngine(stage, canvas, video, {
      onStatus: setStatus,
      onOrient: (o, manual) => setOrient({ o, manual }),
    })
    engineRef.current = engine
    engine.start()

    // ---- multitouch: each active pointer (finger) gets its own index 0..10 ----
    const ptrs = new Map<number, { finger: number; lastMove: number }>()
    const allocFinger = () => {
      const used = new Set<number>()
      ptrs.forEach((p) => used.add(p.finger))
      for (let i = 0; i < 11; i++) if (!used.has(i)) return i
      return 0
    }
    const onDown = (e: PointerEvent) => {
      const f = allocFinger()
      ptrs.set(e.pointerId, { finger: f, lastMove: 0 })
      try {
        stage.setPointerCapture(e.pointerId)
      } catch {
        /* ignore */
      }
      engine.sendTouchAt(0, e.clientX, e.clientY, f)
      e.preventDefault()
    }
    const onMove = (e: PointerEvent) => {
      const p = ptrs.get(e.pointerId)
      if (!p) return
      const now = performance.now()
      if (now - p.lastMove < 16) return // ~60fps cap, mirrors the vanilla page
      p.lastMove = now
      engine.sendTouchAt(1, e.clientX, e.clientY, p.finger)
      e.preventDefault()
    }
    const onUp = (e: PointerEvent) => {
      const p = ptrs.get(e.pointerId)
      if (!p) return
      ptrs.delete(e.pointerId)
      engine.sendTouchAt(2, e.clientX, e.clientY, p.finger)
      e.preventDefault()
    }
    stage.addEventListener('pointerdown', onDown)
    stage.addEventListener('pointermove', onMove)
    stage.addEventListener('pointerup', onUp)
    stage.addEventListener('pointercancel', onUp)

    // ---- keyboard: forward physical keystrokes (skip Console form fields) ----
    const inField = (t: EventTarget | null) => {
      const tag = (t as HTMLElement | null)?.tagName
      return tag === 'INPUT' || tag === 'TEXTAREA'
    }
    const onKeyDown = (e: KeyboardEvent) => {
      if (inField(e.target)) return
      const u = codeToUsage(e.code)
      if (!u) return
      e.preventDefault()
      // Modifiers held; regular keys as one atomic tap (d=2) so a lost release
      // can't trigger iOS auto-repeat.
      if (MOD_USAGES.has(u)) {
        if (!e.repeat) engine.key(u, 1)
      } else engine.key(u, 2)
    }
    const onKeyUp = (e: KeyboardEvent) => {
      if (inField(e.target)) return
      const u = codeToUsage(e.code)
      if (!u) return
      e.preventDefault()
      if (MOD_USAGES.has(u)) engine.key(u, 0)
    }
    addEventListener('keydown', onKeyDown)
    addEventListener('keyup', onKeyUp)

    const onResize = () => engine.applyOrient()
    addEventListener('resize', onResize)

    return () => {
      engine.stop()
      stage.removeEventListener('pointerdown', onDown)
      stage.removeEventListener('pointermove', onMove)
      stage.removeEventListener('pointerup', onUp)
      stage.removeEventListener('pointercancel', onUp)
      removeEventListener('keydown', onKeyDown)
      removeEventListener('keyup', onKeyUp)
      removeEventListener('resize', onResize)
      try {
        video.remove()
      } catch {
        /* ignore */
      }
      engineRef.current = null
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [])

  return {
    status,
    orient,
    sysPress: (n: string) => engineRef.current?.sysPress(n),
    springboard: (u: number) => engineRef.current?.springboard(u),
    rotate: () => engineRef.current?.rotate(),
    setAuto: () => engineRef.current?.setAutoOrient(),
  }
}
