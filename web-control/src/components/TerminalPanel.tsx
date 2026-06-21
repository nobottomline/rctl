import { useEffect, useRef, useState, type ReactNode } from 'react'
import { Terminal } from '@xterm/xterm'
import { FitAddon } from '@xterm/addon-fit'
import '@xterm/xterm/css/xterm.css'
import { Eraser, Power, X } from 'lucide-react'
import { termWS } from '../lib/rctl'
import { cn } from '../lib/cn'

// Root terminal: xterm.js backed by rctld's PTY bridge over a WebSocket. Wire
// protocol (mirrors the vanilla page): client->device [1][utf8] = stdin,
// [2][cols hi][cols lo][rows hi][rows lo] = resize; device->client = raw output.
//
// Mobile-adapted: an accessory key bar (Esc/Tab/Ctrl combos/arrows/symbols the
// soft keyboard lacks), visualViewport sizing so the keyboard never hides the
// prompt, tap-to-focus to summon the keyboard, and safe-area insets. Mounted only
// while open, so xterm is created lazily on demand.
type State = 'disconnected' | 'connecting' | 'connected' | 'error'

const THEME = {
  background: '#050506', foreground: '#f2f2f7', cursor: '#ffffff', selectionBackground: '#3a5f9f',
  black: '#1c1c1e', red: '#ff453a', green: '#32d74b', yellow: '#ffd60a', blue: '#0a84ff',
  magenta: '#bf5af2', cyan: '#64d2ff', white: '#f2f2f7',
  brightBlack: '#636366', brightRed: '#ff6961', brightGreen: '#5ee677', brightYellow: '#ffe45e',
  brightBlue: '#409cff', brightMagenta: '#da8fff', brightCyan: '#8ee8ff', brightWhite: '#ffffff',
}

// Keys a phone keyboard can't reach; each sends the raw bytes a real terminal would.
const KEYS: { label: string; seq: string }[] = [
  { label: 'esc', seq: '\x1b' },
  { label: 'tab', seq: '\t' },
  { label: '^C', seq: '\x03' },
  { label: '^D', seq: '\x04' },
  { label: '^Z', seq: '\x1a' },
  { label: '^L', seq: '\x0c' },
  { label: '|', seq: '|' },
  { label: '~', seq: '~' },
  { label: '/', seq: '/' },
  { label: '-', seq: '-' },
  { label: '←', seq: '\x1b[D' },
  { label: '↑', seq: '\x1b[A' },
  { label: '↓', seq: '\x1b[B' },
  { label: '→', seq: '\x1b[C' },
]

const STATE_DOT: Record<State, string> = {
  connected: 'bg-green-400',
  connecting: 'bg-yellow-400',
  error: 'bg-red-400',
  disconnected: 'bg-white/30',
}

export default function TerminalPanel({ onClose }: { onClose: () => void }) {
  const wrapRef = useRef<HTMLDivElement>(null)
  const viewRef = useRef<HTMLDivElement>(null)
  const termRef = useRef<Terminal | null>(null)
  const fitRef = useRef<FitAddon | null>(null)
  const wsRef = useRef<WebSocket | null>(null)
  const decRef = useRef(new TextDecoder())
  const [state, setState] = useState<State>('disconnected')
  const [touch] = useState(() => typeof matchMedia === 'function' && matchMedia('(pointer: coarse)').matches)

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
  // Send stdin to the PTY and keep focus so the keyboard stays up on mobile.
  const sendInput = (data: string | Uint8Array) => {
    const ws = wsRef.current
    if (!ws || ws.readyState !== WebSocket.OPEN) return
    const raw = typeof data === 'string' ? new TextEncoder().encode(data) : data
    const pkt = new Uint8Array(raw.length + 1)
    pkt[0] = 1
    pkt.set(raw, 1)
    ws.send(pkt)
    termRef.current?.focus()
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
    term.onData((d) => sendInput(d))
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

    // Mobile: pin the panel to the *visible* viewport so the soft keyboard shrinks
    // the terminal instead of covering the prompt, and refit to the new rows.
    const vv = window.visualViewport
    const applyVV = () => {
      if (!vv || !wrapRef.current) return
      wrapRef.current.style.height = vv.height + 'px'
      fitNow()
    }
    vv?.addEventListener('resize', applyVV)
    vv?.addEventListener('scroll', applyVV)
    applyVV()

    return () => {
      clearTimeout(t)
      removeEventListener('resize', onResize)
      ro.disconnect()
      vv?.removeEventListener('resize', applyVV)
      vv?.removeEventListener('scroll', applyVV)
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

  const toggleConn = () =>
    wsRef.current && wsRef.current.readyState === WebSocket.OPEN ? disconnect() : connect()

  return (
    <div
      ref={wrapRef}
      className="fixed inset-x-0 top-0 z-40 flex flex-col bg-[#050506]"
      style={{ height: '100dvh', paddingTop: 'env(safe-area-inset-top)' }}
    >
      <div className="flex h-12 shrink-0 items-center gap-2.5 border-b border-line-2 px-3.5">
        <span className={cn('size-2 shrink-0 rounded-full', STATE_DOT[state])} />
        <div className="text-[13px] font-semibold text-white">Root Terminal</div>
        <span className="mr-auto font-mono text-[11px] text-muted">{state}</span>
        <TopBtn onClick={toggleConn} active={state === 'connected'} title="Connect">
          <Power className="size-4" />
        </TopBtn>
        <TopBtn onClick={() => termRef.current?.clear()} title="Clear">
          <Eraser className="size-4" />
        </TopBtn>
        <TopBtn onClick={onClose} title="Close">
          <X className="size-4" />
        </TopBtn>
      </div>

      <div
        ref={viewRef}
        onPointerDown={() => termRef.current?.focus()}
        className="min-h-0 flex-1 overflow-hidden px-2 py-1.5"
      />

      {touch && (
        <div
          className="flex shrink-0 gap-1 overflow-x-auto border-t border-line-2 bg-black/40 px-2 py-1.5"
          style={{ paddingBottom: 'calc(env(safe-area-inset-bottom) + 6px)' }}
        >
          {KEYS.map((k) => (
            <button
              key={k.label}
              // pointerdown (not click) so focus never leaves the terminal -> keyboard stays up
              onPointerDown={(e) => {
                e.preventDefault()
                sendInput(k.seq)
              }}
              className="grid h-9 min-w-9 shrink-0 place-items-center rounded-lg bg-white/10 px-2.5 font-mono text-[13px] text-white active:bg-white/25"
            >
              {k.label}
            </button>
          ))}
        </div>
      )}
    </div>
  )
}

function TopBtn({
  onClick,
  active,
  title,
  children,
}: {
  onClick: () => void
  active?: boolean
  title: string
  children: ReactNode
}) {
  return (
    <button
      onClick={onClick}
      title={title}
      aria-label={title}
      className={cn(
        'grid size-9 place-items-center rounded-lg transition-colors',
        active ? 'bg-signal text-on-signal' : 'bg-white/10 text-white active:bg-white/20',
      )}
    >
      {children}
    </button>
  )
}
