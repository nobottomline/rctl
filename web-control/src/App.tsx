import { useRef, useState, type ComponentType, type ReactNode } from 'react'
import {
  Activity,
  ChevronDown,
  FolderOpen,
  Gauge,
  Headphones,
  House,
  Lock,
  Moon,
  RotateCw,
  Settings2,
  SlidersHorizontal,
  Smartphone,
  SquareTerminal,
  Sun,
  Volume1,
  Volume2,
  VolumeX,
  type LucideProps,
} from 'lucide-react'
import { useControl } from './hooks/useControl'
import { cn } from './lib/cn'
import { applyTheme, getStoredTheme, type Theme } from './lib/theme'
import TerminalPanel from './components/TerminalPanel'
import FilesPanel from './components/FilesPanel'

// Encode presets the viewer can pick. The device runs ONE shared encoder, so a
// weak client (iPhone in Safari / a relayed path) dials the whole stream DOWN.
// Deliberately capped at the tuned default (0.5 scale) and below: the device's
// hardware encoder can't sustain full Retina -- its own code notes full-res is
// wasted and breaks the framerate -- so a higher preset just collapses fps and
// hammers mediaserverd. The only useful direction here is lower (for weak links).
const QUALITY: { id: string; label: string; scale: number; fps: number; bitrate: number }[] = [
  { id: 'smooth', label: 'Smooth', scale: 0.5, fps: 60, bitrate: 5_000_000 }, // the tuned default
  { id: 'phone', label: 'Phone', scale: 0.5, fps: 30, bitrate: 2_500_000 },   // relayed / weak Wi-Fi
  { id: 'lite', label: 'Lite', scale: 0.4, fps: 24, bitrate: 1_200_000 },     // minimal, survives bad links
]

export default function App() {
  const stageRef = useRef<HTMLDivElement>(null)
  const canvasRef = useRef<HTMLCanvasElement>(null)
  const ctl = useControl(stageRef, canvasRef)
  const [panelOpen, setPanelOpen] = useState(false)
  const [terminalOpen, setTerminalOpen] = useState(false)
  const [filesOpen, setFilesOpen] = useState(false)
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
        onPointerDown={() => panelOpen && setPanelOpen(false)}
      >
        <canvas ref={canvasRef} className="origin-center" />
      </div>

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

      <button
        onClick={() => setPanelOpen((o) => !o)}
        aria-label="controls"
        className={cn(
          'fixed bottom-3 right-3 z-30 grid size-11 place-items-center rounded-full text-white shadow-lg shadow-black/40 backdrop-blur-xl transition-colors',
          panelOpen ? 'bg-signal text-on-signal' : 'bg-white/10',
        )}
      >
        <Settings2 className="size-5" />
      </button>

      {panelOpen && (
        <Panel
          ctl={ctl}
          onTerminal={() => {
            setPanelOpen(false)
            setTerminalOpen(true)
          }}
          onFiles={() => {
            setPanelOpen(false)
            setFilesOpen(true)
          }}
          theme={theme}
          onTheme={toggleTheme}
        />
      )}

      {terminalOpen && <TerminalPanel onClose={() => setTerminalOpen(false)} />}
      {filesOpen && <FilesPanel transfer={ctl.filesTransfer} onClose={() => setFilesOpen(false)} />}
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
    <div className="pointer-events-none fixed left-2 top-9 z-20 rounded-lg bg-black/55 p-2 font-mono text-[10px] leading-tight text-white/75 backdrop-blur-md ring-1 ring-white/10">
      {rows.map(([k, v]) => (
        <div key={k} className="flex justify-between gap-3">
          <span className="text-white/45">{k}</span>
          <span>{v}</span>
        </div>
      ))}
    </div>
  )
}

function Panel({
  ctl,
  onTerminal,
  onFiles,
  theme,
  onTheme,
}: {
  ctl: ReturnType<typeof useControl>
  onTerminal: () => void
  onFiles: () => void
  theme: Theme
  onTheme: () => void
}) {
  const [quality, setQuality] = useState<string | null>(null)
  return (
    <div className="fixed bottom-16 right-3 z-30 w-60 rounded-2xl bg-elevated/80 p-2.5 shadow-2xl shadow-black/50 ring-1 ring-line-2 backdrop-blur-2xl">
      <Section title="Quality">
        <div className="grid grid-cols-2 gap-1.5">
          {QUALITY.map((q) => (
            <Key
              key={q.id}
              icon={Gauge}
              label={q.label}
              active={quality === q.id}
              onClick={() => {
                setQuality(q.id)
                ctl.setQuality(q.scale, q.fps, q.bitrate)
              }}
            />
          ))}
        </div>
      </Section>
      <Section title="System">
        <div className="grid grid-cols-2 gap-1.5">
          <Key icon={House} label="Home" onClick={() => ctl.sysPress('home')} />
          <Key icon={Lock} label="Lock" onClick={() => ctl.sysPress('lock')} />
          <Key icon={SlidersHorizontal} label="Control" onClick={() => ctl.springboard(1)} />
          <Key icon={ChevronDown} label="Shade" onClick={() => ctl.springboard(2)} />
        </div>
      </Section>
      <Section title="Audio">
        <div className="grid grid-cols-2 gap-1.5">
          <Key
            icon={Headphones}
            label={ctl.audio.busy ? '…' : 'Listen'}
            active={ctl.audio.listening}
            onClick={ctl.audio.toggleListen}
          />
          <Key
            icon={ctl.audio.deviceSpeaker ? Volume2 : VolumeX}
            label="iPad"
            active={ctl.audio.deviceSpeaker}
            onClick={ctl.audio.toggleSpeaker}
          />
        </div>
      </Section>
      <Section title="Volume">
        <div className="grid grid-cols-2 gap-1.5">
          <Key icon={Volume1} label="Vol −" onClick={() => ctl.sysPress('voldn')} />
          <Key icon={Volume2} label="Vol +" onClick={() => ctl.sysPress('volup')} />
        </div>
      </Section>
      <Section title="Display">
        <div className="grid grid-cols-2 gap-1.5">
          <Key icon={Smartphone} label="Auto" active={!ctl.orient.manual} onClick={() => ctl.setAuto()} />
          <Key icon={RotateCw} label="Rotate" onClick={() => ctl.rotate()} />
          <Key icon={Activity} label="Stats" active={ctl.statsOn} onClick={() => ctl.toggleStats()} />
          <Key icon={theme === 'dark' ? Sun : Moon} label={theme === 'dark' ? 'Light' : 'Dark'} onClick={onTheme} />
        </div>
      </Section>
      <Section title="Tools">
        <div className="grid grid-cols-2 gap-1.5">
          <Key icon={SquareTerminal} label="Terminal" onClick={onTerminal} />
          <Key icon={FolderOpen} label="Files" onClick={onFiles} />
        </div>
      </Section>
    </div>
  )
}

function Section({ title, children }: { title: string; children: ReactNode }) {
  return (
    <div className="mb-1 last:mb-0">
      <div className="px-1 pb-1 pt-1.5 text-[9px] font-medium uppercase tracking-wider text-muted">
        {title}
      </div>
      {children}
    </div>
  )
}

function Key({
  icon: Icon,
  label,
  onClick,
  active,
}: {
  icon: ComponentType<LucideProps>
  label: string
  onClick: () => void
  active?: boolean
}) {
  return (
    <button
      onClick={onClick}
      className={cn(
        'flex items-center justify-center gap-1.5 rounded-lg px-2 py-2 text-[12px] font-medium text-fg transition-colors active:bg-signal active:text-on-signal',
        active ? 'bg-signal text-on-signal' : 'bg-fg/8',
      )}
    >
      <Icon className="size-3.5 shrink-0" />
      {label}
    </button>
  )
}
