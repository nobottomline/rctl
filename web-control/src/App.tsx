import { useRef, useState, type ComponentType, type ReactNode } from 'react'
import {
  ChevronDown,
  House,
  Lock,
  RotateCw,
  Settings2,
  SlidersHorizontal,
  Smartphone,
  Volume1,
  Volume2,
  type LucideProps,
} from 'lucide-react'
import { useControl } from './hooks/useControl'
import { cn } from './lib/cn'

export default function App() {
  const stageRef = useRef<HTMLDivElement>(null)
  const canvasRef = useRef<HTMLCanvasElement>(null)
  const ctl = useControl(stageRef, canvasRef)
  const [panelOpen, setPanelOpen] = useState(false)

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

      <div className="pointer-events-none fixed left-2 top-1.5 z-10 font-mono text-[11px] text-white/45">
        {ctl.status}
      </div>

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

      {panelOpen && <Panel ctl={ctl} />}
    </div>
  )
}

function Panel({ ctl }: { ctl: ReturnType<typeof useControl> }) {
  return (
    <div className="fixed bottom-16 right-3 z-30 w-56 rounded-2xl bg-elevated/80 p-2.5 shadow-2xl shadow-black/50 ring-1 ring-line-2 backdrop-blur-2xl">
      <Section title="System">
        <div className="grid grid-cols-2 gap-1.5">
          <Key icon={House} label="Home" onClick={() => ctl.sysPress('home')} />
          <Key icon={Lock} label="Lock" onClick={() => ctl.sysPress('lock')} />
          <Key icon={SlidersHorizontal} label="Control" onClick={() => ctl.springboard(1)} />
          <Key icon={ChevronDown} label="Shade" onClick={() => ctl.springboard(2)} />
        </div>
      </Section>
      <Section title="Volume">
        <div className="grid grid-cols-2 gap-1.5">
          <Key icon={Volume1} label="Vol −" onClick={() => ctl.sysPress('voldn')} />
          <Key icon={Volume2} label="Vol +" onClick={() => ctl.sysPress('volup')} />
        </div>
      </Section>
      <Section title="Orientation">
        <div className="grid grid-cols-2 gap-1.5">
          <Key icon={Smartphone} label="Auto" active={!ctl.orient.manual} onClick={() => ctl.setAuto()} />
          <Key icon={RotateCw} label="Rotate" onClick={() => ctl.rotate()} />
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
        'flex items-center justify-center gap-1.5 rounded-lg px-2 py-2 text-[12px] font-medium text-white transition-colors active:bg-signal active:text-on-signal',
        active ? 'bg-signal text-on-signal' : 'bg-white/8',
      )}
    >
      <Icon className="size-3.5 shrink-0" />
      {label}
    </button>
  )
}
