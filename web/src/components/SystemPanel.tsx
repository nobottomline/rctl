import { useEffect, useMemo, useState, type ComponentType, type ReactNode } from 'react'
import { ChevronRight, Library, Package, Puzzle, RotateCw, Search, type LucideProps } from 'lucide-react'
import { apiJSON } from '../lib/rctl'
import { Sheet } from './Sheet'
import { cn } from '../lib/cn'

// System Inspector: a read-only look at what's installed and loaded on the device
// -- dpkg packages, MobileSubstrate tweaks (with the bundles/processes they hook),
// and the dylibs mapped into rctld. Each tab lazy-loads its /v1 endpoint, is
// searchable, and expands a row for detail. Pure data; no device state changes.

type Tab = 'packages' | 'tweaks' | 'dylibs'
type Pkg = { id: string; name: string; version: string; section: string; author: string; desc: string; size: number }
type Tweak = { name: string; path: string; bundles: string[]; executables: string[]; size: number; present: boolean }
type Dylib = { name: string; path: string; size: number; injected: boolean }

const TABS: { id: Tab; label: string; icon: ComponentType<LucideProps> }[] = [
  { id: 'packages', label: 'Packages', icon: Package },
  { id: 'tweaks', label: 'Tweaks', icon: Puzzle },
  { id: 'dylibs', label: 'Dylibs', icon: Library },
]

function fmtSize(b: number) {
  if (!b) return ''
  if (b < 1024) return `${b} B`
  if (b < 1048576) return `${Math.round(b / 1024)} KB`
  return `${(b / 1048576).toFixed(1)} MB`
}

export default function SystemPanel({ onClose }: { onClose: () => void }) {
  const [tab, setTab] = useState<Tab>('packages')
  const [q, setQ] = useState('')
  const [expanded, setExpanded] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)
  const [pkgs, setPkgs] = useState<Pkg[] | null>(null)
  const [tweaks, setTweaks] = useState<Tweak[] | null>(null)
  const [dylibs, setDylibs] = useState<Dylib[] | null>(null)

  const load = async (t: Tab, force = false) => {
    if (!force && ((t === 'packages' && pkgs) || (t === 'tweaks' && tweaks) || (t === 'dylibs' && dylibs))) return
    setBusy(true)
    if (t === 'packages') {
      const j = await apiJSON<{ packages: Pkg[] }>('/v1/packages')
      setPkgs(j?.packages ?? [])
    } else if (t === 'tweaks') {
      const j = await apiJSON<{ tweaks: Tweak[] }>('/v1/tweaks')
      setTweaks(j?.tweaks ?? [])
    } else {
      const j = await apiJSON<{ dylibs: Dylib[] }>('/v1/dylibs')
      setDylibs(j?.dylibs ?? [])
    }
    setBusy(false)
  }

  // Lazy-load the active tab the first time it's shown.
  useEffect(() => {
    load(tab)
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [tab])

  const data = tab === 'packages' ? pkgs : tab === 'tweaks' ? tweaks : dylibs
  const counts = { packages: pkgs?.length, tweaks: tweaks?.length, dylibs: dylibs?.length }

  const filtered = useMemo(() => {
    if (!data) return null
    const needle = q.trim().toLowerCase()
    if (!needle) return data as (Pkg | Tweak | Dylib)[]
    return (data as (Pkg | Tweak | Dylib)[]).filter((it) => haystack(tab, it).includes(needle))
  }, [data, q, tab])

  const toolbar = (
    <div className="space-y-2">
      <div className="flex gap-1 rounded-lg bg-fg/6 p-1">
        {TABS.map((t) => (
          <button
            key={t.id}
            onClick={() => {
              setTab(t.id)
              setExpanded(null)
              setQ('') // each tab is a different dataset; a stale query would mislead
            }}
            className={cn(
              'flex flex-1 items-center justify-center gap-1.5 rounded-md py-1.5 text-[12px] font-medium transition-colors',
              tab === t.id ? 'bg-signal text-on-signal' : 'text-fg-dim active:bg-fg/10',
            )}
          >
            <t.icon className="size-3.5" />
            {t.label}
            {counts[t.id] != null && (
              <span className={cn('text-[10px] tabular-nums', tab === t.id ? 'text-on-signal/70' : 'text-faint')}>
                {counts[t.id]}
              </span>
            )}
          </button>
        ))}
      </div>
      <div className="flex items-center gap-2">
        <div className="relative flex-1">
          <Search className="pointer-events-none absolute left-2.5 top-1/2 size-3.5 -translate-y-1/2 text-faint" />
          <input
            value={q}
            onChange={(e) => {
              setQ(e.target.value)
              setExpanded(null)
            }}
            placeholder={`Search ${tab}…`}
            className="h-9 w-full min-w-0 rounded-lg bg-fg/[0.06] pl-8 pr-2.5 text-[13px] text-fg outline-none ring-1 ring-line/70 transition placeholder:text-faint focus:ring-2 focus:ring-signal/70"
          />
        </div>
        <button
          onClick={() => load(tab, true)}
          aria-label="Refresh"
          className="grid size-9 shrink-0 place-items-center rounded-lg bg-fg/8 text-fg-dim transition-colors active:bg-fg/15"
        >
          <RotateCw className={cn('size-4', busy && 'animate-spin')} />
        </button>
      </div>
    </div>
  )

  return (
    <Sheet title="System" onClose={onClose} wide toolbar={toolbar}>
      <div className="p-2">
        {filtered == null ? (
          <Hint>{busy ? 'Loading…' : ''}</Hint>
        ) : filtered.length === 0 ? (
          <Hint>{q ? 'No matches' : 'Nothing here'}</Hint>
        ) : (
          <ul className="space-y-1">
            {filtered.map((it) => {
              const k = rowKey(tab, it)
              return (
                <Row
                  key={k}
                  tab={tab}
                  item={it}
                  open={expanded === k}
                  onToggle={() => setExpanded(expanded === k ? null : k)}
                />
              )
            })}
          </ul>
        )}
      </div>
    </Sheet>
  )
}

function haystack(tab: Tab, it: Pkg | Tweak | Dylib): string {
  if (tab === 'packages') {
    const p = it as Pkg
    return `${p.name} ${p.id} ${p.section} ${p.author} ${p.desc}`.toLowerCase()
  }
  if (tab === 'tweaks') {
    const t = it as Tweak
    return `${t.name} ${t.bundles.join(' ')} ${t.executables.join(' ')}`.toLowerCase()
  }
  const d = it as Dylib
  return `${d.name} ${d.path}`.toLowerCase()
}

function rowKey(tab: Tab, it: Pkg | Tweak | Dylib): string {
  if (tab === 'packages') return 'p:' + (it as Pkg).id
  if (tab === 'tweaks') return 't:' + (it as Tweak).path
  return 'd:' + (it as Dylib).path
}

function Row({
  tab,
  item,
  open,
  onToggle,
}: {
  tab: Tab
  item: Pkg | Tweak | Dylib
  open: boolean
  onToggle: () => void
}) {
  const title = tab === 'packages' ? (item as Pkg).name : (item as Pkg).name
  const size = (item as { size: number }).size
  const sub =
    tab === 'packages'
      ? `${(item as Pkg).version}${(item as Pkg).section ? ' · ' + (item as Pkg).section : ''}`
      : tab === 'tweaks'
        ? targetSummary(item as Tweak)
        : (item as Dylib).path
  return (
    <li className="overflow-hidden rounded-lg bg-fg/[0.04] ring-1 ring-line/40">
      <button onClick={onToggle} className="flex w-full items-center gap-2.5 px-2.5 py-2 text-left active:bg-fg/[0.06]">
        <ChevronRight className={cn('size-3.5 shrink-0 text-faint transition-transform', open && 'rotate-90')} />
        <div className="min-w-0 flex-1">
          <div className="flex items-center gap-1.5">
            <span className="truncate text-[13px] font-medium text-fg">{title}</span>
            {tab === 'dylibs' && (item as Dylib).injected && (
              <span className="shrink-0 rounded bg-amber-500/15 px-1 py-px text-[9px] font-semibold uppercase tracking-wide text-amber-500">
                injected
              </span>
            )}
            {tab === 'tweaks' && !(item as Tweak).present && (
              <span className="shrink-0 rounded bg-fg/10 px-1 py-px text-[9px] font-semibold uppercase tracking-wide text-muted">
                no dylib
              </span>
            )}
          </div>
          <div className="truncate text-[11px] text-muted">{sub}</div>
        </div>
        {size > 0 && <span className="shrink-0 text-[11px] tabular-nums text-faint">{fmtSize(size)}</span>}
      </button>
      {open && <Detail tab={tab} item={item} />}
    </li>
  )
}

function targetSummary(t: Tweak): string {
  const n = t.bundles.length + t.executables.length
  if (n === 0) return 'global / no filter'
  if (t.bundles.length && !t.executables.length) return `${t.bundles.length} app${t.bundles.length > 1 ? 's' : ''}`
  return `${n} target${n > 1 ? 's' : ''}`
}

function Detail({ tab, item }: { tab: Tab; item: Pkg | Tweak | Dylib }) {
  return (
    <div className="border-t border-line/40 bg-fg/[0.02] px-3 py-2.5 text-[11.5px]">
      {tab === 'packages' && <PkgDetail p={item as Pkg} />}
      {tab === 'tweaks' && <TweakDetail t={item as Tweak} />}
      {tab === 'dylibs' && <KV label="Path" value={(item as Dylib).path} mono />}
    </div>
  )
}

function PkgDetail({ p }: { p: Pkg }) {
  return (
    <div className="space-y-1">
      <KV label="Identifier" value={p.id} mono />
      <KV label="Version" value={p.version} mono />
      {p.author && <KV label="Author" value={p.author} />}
      {p.desc && <KV label="Description" value={p.desc} />}
    </div>
  )
}

function TweakDetail({ t }: { t: Tweak }) {
  return (
    <div className="space-y-2">
      <KV label="Path" value={t.path} mono />
      {t.bundles.length > 0 && <Chips label="Bundles" items={t.bundles} />}
      {t.executables.length > 0 && <Chips label="Executables" items={t.executables} />}
      {t.bundles.length === 0 && t.executables.length === 0 && (
        <div className="text-muted">No filter — loads into every process.</div>
      )}
    </div>
  )
}

function Chips({ label, items }: { label: string; items: string[] }) {
  return (
    <div>
      <div className="mb-1 text-[9px] font-medium uppercase tracking-wider text-faint">{label}</div>
      <div className="flex flex-wrap gap-1">
        {items.map((s) => (
          <span key={s} className="rounded bg-fg/8 px-1.5 py-0.5 font-mono text-[10px] text-fg-dim">
            {s}
          </span>
        ))}
      </div>
    </div>
  )
}

function KV({ label, value, mono }: { label: string; value: string; mono?: boolean }) {
  return (
    <div className="flex gap-2">
      <span className="w-20 shrink-0 text-[9px] font-medium uppercase tracking-wider text-faint" style={{ paddingTop: 2 }}>
        {label}
      </span>
      <span className={cn('min-w-0 flex-1 break-words text-fg-dim', mono && 'font-mono text-[11px]')}>{value}</span>
    </div>
  )
}

function Hint({ children }: { children: ReactNode }) {
  return <div className="grid h-32 place-items-center text-[12px] text-muted">{children}</div>
}
