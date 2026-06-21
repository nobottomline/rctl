import { useState, type ComponentType, type ReactNode } from 'react'
import {
  Activity,
  ChevronDown,
  FolderOpen,
  Headphones,
  House,
  Lock,
  Moon,
  RotateCw,
  SlidersHorizontal,
  Smartphone,
  SquareTerminal,
  Sun,
  Volume1,
  Volume2,
  VolumeX,
  Wand2,
  type LucideProps,
} from 'lucide-react'
import type { useControl } from '../hooks/useControl'
import type { Theme } from '../lib/theme'
import { cn } from '../lib/cn'

// The control center: the compact quick-action popover (small, anchored above the
// FAB, never dims the video) -- but organized. Frequent actions are grouped
// (Device / Sound / Screen) with a segmented Quality control; the rich, occasional
// tooling is offloaded behind Tools (Terminal, Files, Console) so this stays
// scannable as features grow. Dismissed by the FAB toggle or a tap on the video.
type Ctl = ReturnType<typeof useControl>

const QUALITY = [
  { id: 'smooth', label: 'Smooth', scale: 0.5, fps: 60, bitrate: 5_000_000 },
  { id: 'phone', label: 'Phone', scale: 0.5, fps: 30, bitrate: 2_500_000 },
  { id: 'lite', label: 'Lite', scale: 0.4, fps: 24, bitrate: 1_200_000 },
]

export default function ControlCenter({
  ctl,
  theme,
  onTheme,
  onTerminal,
  onFiles,
  onConsole,
}: {
  ctl: Ctl
  theme: Theme
  onTheme: () => void
  onTerminal: () => void
  onFiles: () => void
  onConsole: () => void
}) {
  return (
    <div className="fixed bottom-16 right-3 z-30 max-h-[calc(100dvh-5rem)] w-60 space-y-1.5 overflow-y-auto rounded-2xl bg-elevated/90 p-2.5 text-fg shadow-2xl shadow-black/50 ring-1 ring-line-2 backdrop-blur-2xl">
      <Group title="Device">
        <Key icon={House} label="Home" onClick={() => ctl.sysPress('home')} />
        <Key icon={Lock} label="Lock" onClick={() => ctl.sysPress('lock')} />
        <Key icon={SlidersHorizontal} label="Control" onClick={() => ctl.springboard(1)} />
        <Key icon={ChevronDown} label="Shade" onClick={() => ctl.springboard(2)} />
      </Group>

      <Group title="Sound">
        <Key icon={Volume1} label="Vol −" onClick={() => ctl.sysPress('voldn')} />
        <Key icon={Volume2} label="Vol +" onClick={() => ctl.sysPress('volup')} />
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
      </Group>

      <Group title="Screen">
        <Key icon={Smartphone} label="Auto" active={!ctl.orient.manual} onClick={ctl.setAuto} />
        <Key icon={RotateCw} label="Rotate" onClick={ctl.rotate} />
        <Key icon={theme === 'dark' ? Sun : Moon} label={theme === 'dark' ? 'Light' : 'Dark'} onClick={onTheme} />
        <Key icon={Activity} label="Stats" active={ctl.statsOn} onClick={ctl.toggleStats} />
      </Group>

      <Quality ctl={ctl} />

      <Group title="Tools">
        <Key icon={SquareTerminal} label="Terminal" onClick={onTerminal} />
        <Key icon={FolderOpen} label="Files" onClick={onFiles} />
        <Key icon={Wand2} label="Console" onClick={onConsole} />
      </Group>
    </div>
  )
}

function Group({ title, children }: { title: string; children: ReactNode }) {
  return (
    <div>
      <Label>{title}</Label>
      <div className="grid grid-cols-2 gap-1.5">{children}</div>
    </div>
  )
}

function Label({ children }: { children: ReactNode }) {
  return (
    <div className="px-1 pb-1 pt-1.5 text-[9px] font-medium uppercase tracking-wider text-muted">{children}</div>
  )
}

function Key({
  icon: Icon,
  label,
  active,
  onClick,
}: {
  icon: ComponentType<LucideProps>
  label: string
  active?: boolean
  onClick: () => void
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

function Quality({ ctl }: { ctl: Ctl }) {
  const [sel, setSel] = useState('smooth')
  return (
    <div>
      <Label>Quality</Label>
      <div className="flex gap-1 rounded-lg bg-fg/6 p-1">
        {QUALITY.map((q) => (
          <button
            key={q.id}
            onClick={() => {
              setSel(q.id)
              ctl.setQuality(q.scale, q.fps, q.bitrate)
            }}
            className={cn(
              'flex-1 rounded-md py-1 text-[11px] font-medium transition-colors',
              sel === q.id ? 'bg-signal text-on-signal' : 'text-fg-dim active:bg-fg/10',
            )}
          >
            {q.label}
          </button>
        ))}
      </div>
    </div>
  )
}
