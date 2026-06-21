import { useRef, useState } from 'react'
import { Settings2 } from 'lucide-react'
import { useControl } from './hooks/useControl'
import { cn } from './lib/cn'
import { applyTheme, getStoredTheme, type Theme } from './lib/theme'
import ControlCenter from './components/ControlCenter'
import TerminalPanel from './components/TerminalPanel'
import FilesPanel from './components/FilesPanel'
import ConsolePanel from './components/ConsolePanel'

type View = null | 'cc' | 'terminal' | 'files' | 'console'

export default function App() {
  const stageRef = useRef<HTMLDivElement>(null)
  const canvasRef = useRef<HTMLCanvasElement>(null)
  const ctl = useControl(stageRef, canvasRef)
  const [view, setView] = useState<View>(null)
  const [theme, setTheme] = useState<Theme>(() => getStoredTheme())
  const toggleTheme = () => {
    const next: Theme = theme === 'dark' ? 'warm' : 'dark'
    applyTheme(next)
    setTheme(next)
  }

  return (
    <div className="fixed inset-0 select-none overflow-hidden bg-black text-white">
      <div
        ref={stageRef}
        className="fixed inset-0 grid place-items-center"
        style={{ touchAction: 'none' }}
        onPointerDown={() => view === 'cc' && setView(null)}
      >
        <canvas ref={canvasRef} className="origin-center" />
      </div>

      {/* HUD / diagnostics — sits over the (always-dark) video, so it stays light */}
      <button
        onClick={ctl.toggleStats}
        className={cn(
          'fixed left-2 top-1.5 z-20 rounded-md px-1.5 py-0.5 font-mono text-[11px] transition-colors',
          ctl.statsOn ? 'bg-white/10 text-white/80' : 'text-white/45',
        )}
      >
        {ctl.statsOn && ctl.stats ? `${ctl.stats.fps}fps · ${ctl.stats.res}` : ctl.status}
      </button>
      {ctl.statsOn && ctl.stats && <StatsOverlay s={ctl.stats} />}

      {(view === null || view === 'cc') && (
        <button
          onClick={() => setView(view === 'cc' ? null : 'cc')}
          aria-label="controls"
          className={cn(
            'fixed bottom-3 right-3 z-40 grid size-11 place-items-center rounded-full shadow-lg shadow-black/40 backdrop-blur-xl transition-colors',
            view === 'cc' ? 'bg-signal text-on-signal' : 'bg-white/10 text-white active:bg-white/20',
          )}
        >
          <Settings2 className="size-5" />
        </button>
      )}

      {view === 'cc' && (
        <ControlCenter
          ctl={ctl}
          theme={theme}
          onTheme={toggleTheme}
          onTerminal={() => setView('terminal')}
          onFiles={() => setView('files')}
          onConsole={() => setView('console')}
        />
      )}
      {view === 'terminal' && <TerminalPanel onClose={() => setView(null)} />}
      {view === 'files' && <FilesPanel transfer={ctl.filesTransfer} onClose={() => setView(null)} />}
      {view === 'console' && <ConsolePanel onClose={() => setView(null)} onScreenshot={ctl.screenshot} />}
    </div>
  )
}

function StatsOverlay({ s }: { s: ReturnType<typeof useControl>['stats'] }) {
  if (!s) return null
  const rows: [string, string | number][] = [
    ['decode', `${s.decodeMs} ms/f`],
    ['jitter buf', `${s.jitterMs} ms`],
    ['rtt', `${s.rttMs} ms`],
    ['dropped', s.dropped],
    ['freezes', `${s.freezes} (${s.freezeS}s)`],
    ['pli', s.pli],
    ['ice', s.path],
  ]
  return (
    <div className="pointer-events-none fixed left-2 top-9 z-20 rounded-lg bg-black/55 p-2 font-mono text-[10px] leading-tight text-white/75 ring-1 ring-white/10 backdrop-blur-md">
      {rows.map(([k, v]) => (
        <div key={k} className="flex justify-between gap-3">
          <span className="text-white/45">{k}</span>
          <span>{v}</span>
        </div>
      ))}
    </div>
  )
}
