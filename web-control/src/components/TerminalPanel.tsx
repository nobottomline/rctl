import { useEffect, useRef, useState } from 'react'
import { Terminal } from '@xterm/xterm'
import { FitAddon } from '@xterm/addon-fit'
import '@xterm/xterm/css/xterm.css'
import { Eraser, Power, X, type LucideProps } from 'lucide-react'
import type { ComponentType, ReactNode } from 'react'
import { termWS } from '../lib/rctl'
import { cn } from '../lib/cn'

// Root terminal: xterm.js backed by rctld's PTY bridge over a WebSocket. The wire
// protocol mirrors the vanilla page: client->device [1][utf8 bytes] = stdin,
// [2][cols hi][cols lo][rows hi][rows lo] = resize; device->client = raw output
// bytes (TextDecoder, streaming). Mounted only while open, so xterm is never
// created until the user actually wants a shell.
type State = 'disconnected' | 'connecting' | 'connected' | 'error'

const THEME = {
  background: '#050506', foreground: '#f2f2f7', cursor: '#ffffff', selectionBackground: '#3a5f9f',
  black: '#1c1c1e', red: '#ff453a', green: '#32d74b', yellow: '#ffd60a', blue: '#0a84ff',
  magenta: '#bf5af2', cyan: '#64d2ff', white: '#f2f2f7',
  brightBlack: '#636366', brightRed: '#ff6961', brightGreen: '#5ee677', brightYellow: '#ffe45e',
  brightBlue: '#409cff', brightMagenta: '#da8fff', brightCyan: '#8ee8ff', brightWhite: '#ffffff',
}

export default function TerminalPanel({ onClose }: { onClose: () => void }) {
  const viewRef = useRef<HTMLDivElement>(null)
  const termRef = useRef<Terminal | null>(null)
  const fitRef = useRef<FitAddon | null>(null)
  const wsRef = useRef<WebSocket | null>(null)
  const decRef = useRef(new TextDecoder())
  const [state, setState] = useState<State>('disconnected')

  // refs to the helpers so the mount effect can call the latest without re-running
  const sendResize = (cols: number, rows: number) => {
    const ws = wsRef.current
    if (!ws || ws.readyState !== WebSocket.OPEN || !cols || !rows) return
    const pkt = new Uint8Array(5)
    pkt[0] = 2
    pkt[1] = (cols >> 8) & 255
    pkt[2] = cols & 255
    pkt[3] = (rows >> 8) & 255
    pkt[4] = rows & 255
    ws.send(pkt)
  }
  const fitNow = () => {
    const fit = fitRef.current
    const term = termRef.current
    if (!fit || !term) return
    try {
      fit.fit()
    } catch {
      /* ignore */
    }
    sendResize(term.cols, term.rows)
  }
  const connect = () => {
    const term = termRef.current
    if (!term) return
    if (wsRef.current && wsRef.current.readyState === WebSocket.OPEN) return
    const ws = new WebSocket(termWS(term.cols || 100, term.rows || 30))
    ws.binaryType = 'arraybuffer'
    wsRef.current = ws
    setState('connecting')
    ws.onopen = () => {
      setState('connected')
      term.focus()
      sendResize(term.cols, term.rows)
    }
    ws.onmessage = (e) => {
      if (e.data instanceof ArrayBuffer) term.write(decRef.current.decode(new Uint8Array(e.data), { stream: true }))
      else term.write(String(e.data))
    }
    ws.onclose = () => setState('disconnected')
    ws.onerror = () => setState('error')
  }
  const disconnect = () => {
    if (wsRef.current) {
      try {
        wsRef.current.close()
      } catch {
        /* ignore */
      }
    }
    wsRef.current = null
    setState('disconnected')
  }

  useEffect(() => {
    const term = new Terminal({
      cursorBlink: true,
      convertEol: true,
      fontFamily: 'ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace',
      fontSize: 13,
      lineHeight: 1.15,
      scrollback: 5000,
      theme: THEME,
    })
    const fit = new FitAddon()
    term.loadAddon(fit)
    term.open(viewRef.current!)
    term.onData((d) => {
      const ws = wsRef.current
      if (!ws || ws.readyState !== WebSocket.OPEN) return
      const raw = new TextEncoder().encode(d)
      const pkt = new Uint8Array(raw.length + 1)
      pkt[0] = 1
      pkt.set(raw, 1)
      ws.send(pkt)
    })
    term.onResize(({ cols, rows }) => sendResize(cols, rows))
    termRef.current = term
    fitRef.current = fit

    const t = window.setTimeout(() => {
      fitNow()
      connect()
    }, 40)
    const onResize = () => fitNow()
    addEventListener('resize', onResize)
    const ro = new ResizeObserver(() => fitNow())
    if (viewRef.current) ro.observe(viewRef.current)

    return () => {
      clearTimeout(t)
      removeEventListener('resize', onResize)
      ro.disconnect()
      disconnect()
      try {
        term.dispose()
      } catch {
        /* ignore */
      }
      termRef.current = null
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [])

  const ctrlC = () => {
    const ws = wsRef.current
    if (ws && ws.readyState === WebSocket.OPEN) {
      ws.send(new Uint8Array([1, 3]))
      termRef.current?.focus()
    }
  }
  const toggleConn = () =>
    wsRef.current && wsRef.current.readyState === WebSocket.OPEN ? disconnect() : connect()

  return (
    <div className="fixed inset-0 z-40 flex flex-col bg-[#050506]">
      <div className="flex h-11 shrink-0 items-center gap-2 border-b border-line-2 px-3">
        <div className="mr-auto text-[13px] font-semibold text-white">Root Terminal</div>
        <span
          className={cn(
            'font-mono text-[11px]',
            state === 'connected' ? 'text-green-400' : state === 'error' ? 'text-red-400' : 'text-muted',
          )}
        >
          {state}
        </span>
        <TBtn onClick={toggleConn} icon={Power} active={state === 'connected'} />
        <TBtn onClick={ctrlC} label="^C" />
        <TBtn onClick={() => termRef.current?.clear()} icon={Eraser} />
        <TBtn onClick={onClose} icon={X} />
      </div>
      <div ref={viewRef} className="min-h-0 flex-1 p-2" />
    </div>
  )
}

function TBtn({
  onClick,
  icon: Icon,
  label,
  active,
}: {
  onClick: () => void
  icon?: ComponentType<LucideProps>
  label?: string
  active?: boolean
}): ReactNode {
  return (
    <button
      onClick={onClick}
      className={cn(
        'grid h-8 min-w-8 place-items-center rounded-lg px-2 text-[12px] font-medium text-white transition-colors',
        active ? 'bg-signal text-on-signal' : 'bg-white/10 active:bg-white/20',
      )}
    >
      {Icon ? <Icon className="size-4" /> : label}
    </button>
  )
}
