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
import { Sheet } from './Sheet'
import { cn } from '../lib/cn'

// The control center: an iOS-Control-Center-style command surface that replaces
// the cramped popover. Frequent device actions are grouped tiles (Device / Sound
// / Screen); the rich, occasional tooling lives behind Tools (Terminal, Files,
// Console) so this stays scannable as features grow. Presented as a non-dimming
// Sheet so the video stays visible while you toggle.
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
  onClose,
}: {
  ctl: Ctl
  theme: Theme
  onTheme: () => void
  onTerminal: () => void
  onFiles: () => void
  onConsole: () => void
  onClose: () => void
}) {
  return (
    <Sheet title="Control" onClose={onClose} dim={false}>
      <div className="space-y-4 p-3.5">
        <Group title="Device">
          <Tile icon={House} label="Home" onClick={() => ctl.sysPress('home')} />
          <Tile icon={Lock} label="Lock" onClick={() => ctl.sysPress('lock')} />
          <Tile icon={SlidersHorizontal} label="Control" onClick={() => ctl.springboard(1)} />
          <Tile icon={ChevronDown} label="Shade" onClick={() => ctl.springboard(2)} />
        </Group>

        <Group title="Sound">
          <Tile icon={Volume1} label="Vol −" onClick={() => ctl.sysPress('voldn')} />
          <Tile icon={Volume2} label="Vol +" onClick={() => ctl.sysPress('volup')} />
          <Tile
            icon={Headphones}
            label={ctl.audio.busy ? '…' : 'Listen'}
            active={ctl.audio.listening}
            onClick={ctl.audio.toggleListen}
          />
          <Tile
            icon={ctl.audio.deviceSpeaker ? Volume2 : VolumeX}
            label="iPad"
            active={ctl.audio.deviceSpeaker}
            onClick={ctl.audio.toggleSpeaker}
          />
        </Group>

        <Group title="Screen">
          <Tile icon={Smartphone} label="Auto" active={!ctl.orient.manual} onClick={ctl.setAuto} />
          <Tile icon={RotateCw} label="Rotate" onClick={ctl.rotate} />
          <Tile icon={theme === 'dark' ? Sun : Moon} label={theme === 'dark' ? 'Light' : 'Dark'} onClick={onTheme} />
          <Tile icon={Activity} label="Stats" active={ctl.statsOn} onClick={ctl.toggleStats} />
        </Group>

        <Quality ctl={ctl} />

        <Group title="Tools">
          <Tile icon={SquareTerminal} label="Terminal" onClick={onTerminal} />
          <Tile icon={FolderOpen} label="Files" onClick={onFiles} />
          <Tile icon={Wand2} label="Console" onClick={onConsole} />
        </Group>
      </div>
    </Sheet>
  )
}

function Group({ title, children }: { title: string; children: ReactNode }) {
  return (
    <div>
      <Label>{title}</Label>
      <div className="grid grid-cols-4 gap-2">{children}</div>
    </div>
  )
}

function Label({ children }: { children: ReactNode }) {
  return <div className="mb-2 px-0.5 text-[11px] font-semibold uppercase tracking-wide text-muted">{children}</div>
}

function Tile({
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
        'flex aspect-square flex-col items-center justify-center gap-1.5 rounded-2xl text-[10.5px] font-medium transition-colors',
        active ? 'bg-signal text-on-signal' : 'bg-fg/6 text-fg active:bg-fg/12',
      )}
    >
      <Icon className="size-5" />
      <span className="leading-none">{label}</span>
    </button>
  )
}

function Quality({ ctl }: { ctl: Ctl }) {
  const [sel, setSel] = useState('smooth')
  return (
    <div>
      <Label>Quality</Label>
      <div className="flex gap-1 rounded-xl bg-fg/6 p-1">
        {QUALITY.map((q) => (
          <button
            key={q.id}
            onClick={() => {
              setSel(q.id)
              ctl.setQuality(q.scale, q.fps, q.bitrate)
            }}
            className={cn(
              'flex-1 rounded-lg py-1.5 text-[12px] font-medium transition-colors',
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
