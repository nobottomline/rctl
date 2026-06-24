import { useEffect, useMemo, useState, type ComponentType, type ReactNode } from 'react'
import {
  ChevronRight,
  Copy,
  Download,
  FileText,
  Library,
  MoreVertical,
  Package,
  Power,
  Puzzle,
  RotateCw,
  Search,
  Trash2,
  TriangleAlert,
  type LucideProps,
} from 'lucide-react'
import { api, apiDo, apiJSON } from '../lib/rctl'
import { saveBlobToFile, type FileTransfer } from '../lib/files'
import { Sheet } from './Sheet'
import { cn } from '../lib/cn'

// System Inspector + manager: browse dpkg packages, MobileSubstrate tweaks (with
// the bundles/processes they hook), and the dylibs mapped into rctld -- and act on
// them. A per-row ⋯ menu can toggle a tweak on/off, download a dylib, copy paths,
// uninstall the owning package (dpkg -r, behind a confirm) and list a package's
// files. Tweak toggles and removals take effect on the next respring, offered via
// a banner. Reads are pure; writes are explicit and confirmed.

type Tab = 'packages' | 'tweaks' | 'dylibs'
type Pkg = { id: string; name: string; version: string; section: string; author: string; desc: string; size: number }
type Tweak = {
  name: string
  path: string
  bundles: string[]
  executables: string[]
  size: number
  present: boolean
  enabled: boolean
}
type Dylib = { name: string; path: string; size: number; injected: boolean }
type Item = Pkg | Tweak | Dylib
type Menu = { key: string; x: number; y: number; item: Item }

const enc = encodeURIComponent

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

function baseName(p: string) {
  return p.split('/').pop() || p
}

// Clipboard over plain HTTP isn't a secure context, so navigator.clipboard may be
// absent -- fall back to a hidden textarea + execCommand.
function copyText(s: string) {
  if (navigator.clipboard?.writeText) {
    navigator.clipboard.writeText(s).catch(() => fallbackCopy(s))
    return
  }
  fallbackCopy(s)
}
function fallbackCopy(s: string) {
  const ta = document.createElement('textarea')
  ta.value = s
  ta.style.cssText = 'position:fixed;opacity:0'
  document.body.appendChild(ta)
  ta.focus()
  ta.select()
  try {
    document.execCommand('copy')
  } catch {
    /* ignore */
  }
  ta.remove()
}

export default function SystemPanel({ onClose, transfer }: { onClose: () => void; transfer: FileTransfer }) {
  const [tab, setTab] = useState<Tab>('packages')
  const [q, setQ] = useState('')
  const [expanded, setExpanded] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)
  const [pkgs, setPkgs] = useState<Pkg[] | null>(null)
  const [tweaks, setTweaks] = useState<Tweak[] | null>(null)
  const [dylibs, setDylibs] = useState<Dylib[] | null>(null)

  const [menu, setMenu] = useState<Menu | null>(null)
  const [confirm, setConfirm] = useState<{ id: string; name: string } | null>(null)
  const [removing, setRemoving] = useState(false)
  const [needRespring, setNeedRespring] = useState(false)
  const [filesFor, setFilesFor] = useState<{ id: string; name: string } | null>(null)
  const [note, setNote] = useState<string | null>(null)

  const load = async (t: Tab, force = false) => {
    if (!force && ((t === 'packages' && pkgs) || (t === 'tweaks' && tweaks) || (t === 'dylibs' && dylibs))) return
    setBusy(true)
    if (t === 'packages') setPkgs((await apiJSON<{ packages: Pkg[] }>('/v1/packages'))?.packages ?? [])
    else if (t === 'tweaks') setTweaks((await apiJSON<{ tweaks: Tweak[] }>('/v1/tweaks'))?.tweaks ?? [])
    else setDylibs((await apiJSON<{ dylibs: Dylib[] }>('/v1/dylibs'))?.dylibs ?? [])
    setBusy(false)
  }

  useEffect(() => {
    load(tab)
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [tab])

  const data = tab === 'packages' ? pkgs : tab === 'tweaks' ? tweaks : dylibs
  const counts = { packages: pkgs?.length, tweaks: tweaks?.length, dylibs: dylibs?.length }

  const filtered = useMemo(() => {
    if (!data) return null
    const needle = q.trim().toLowerCase()
    if (!needle) return data as Item[]
    return (data as Item[]).filter((it) => haystack(tab, it).includes(needle))
  }, [data, q, tab])

  // ---- actions ----
  const toggleTweak = async (t: Tweak) => {
    setMenu(null)
    await api(`/v1/tweak_toggle?path=${enc(t.path)}&on=${t.enabled ? 0 : 1}`).catch(() => {})
    await load('tweaks', true)
    setNeedRespring(true)
  }
  const download = async (path: string) => {
    setMenu(null)
    const name = baseName(path).trim() || 'file'
    setNote(`Preparing ${name}…`)
    try {
      // Fetch over the P2P channel, then save in this click's async continuation so
      // Safari (which blocks downloads outside a live user gesture) accepts it.
      const blob = await transfer.fetch(path)
      saveBlobToFile(blob, name)
      setNote(`Saved ${name}`)
    } catch {
      setNote(`Couldn’t download ${name}`)
    }
    window.setTimeout(() => setNote(null), 2200)
  }
  const copy = (text: string) => {
    setMenu(null)
    copyText(text)
    setNote('Copied')
    window.setTimeout(() => setNote(null), 1500)
  }
  const askUninstallTweak = async (t: Tweak) => {
    setMenu(null)
    setNote('Finding owning package…')
    const j = await apiJSON<{ package: string }>(`/v1/owner?path=${enc(t.path)}`)
    setNote(null)
    if (j?.package) setConfirm({ id: j.package, name: j.package })
    else setNote(`No package owns ${t.name.trim()}`)
  }
  const doUninstall = async () => {
    if (!confirm) return
    setRemoving(true)
    const j = await apiJSON<{ ok: boolean; output: string }>(`/v1/pkg_remove?id=${enc(confirm.id)}`)
    setRemoving(false)
    const target = confirm
    setConfirm(null)
    await Promise.all([load('packages', true), load('tweaks', true)])
    if (j && !j.ok) setNote(j.output?.trim() || `Could not remove ${target.name}`)
    else setNeedRespring(true)
  }
  const doRespring = () => {
    setNeedRespring(false)
    setNote('Respringing…')
    apiDo('/v1/respring')
    window.setTimeout(() => setNote(null), 3000)
  }

  const openMenu = (e: React.MouseEvent, key: string, item: Item) => {
    e.stopPropagation()
    const r = (e.currentTarget as HTMLElement).getBoundingClientRect()
    setMenu({ key, x: r.right, y: r.bottom + 4, item })
  }

  const toolbar = (
    <div className="space-y-2">
      <div className="flex gap-1 rounded-lg bg-fg/6 p-1">
        {TABS.map((t) => (
          <button
            key={t.id}
            onClick={() => {
              setTab(t.id)
              setExpanded(null)
              setQ('')
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
      {needRespring && (
        <div className="sticky top-0 z-10 flex items-center gap-2 border-b border-amber-500/20 bg-amber-500/10 px-3 py-2 backdrop-blur">
          <TriangleAlert className="size-3.5 shrink-0 text-amber-500" />
          <span className="flex-1 text-[11.5px] text-fg-dim">Changes apply after a respring.</span>
          <button
            onClick={doRespring}
            className="rounded-md bg-amber-500 px-2.5 py-1 text-[11px] font-semibold text-black transition active:opacity-80"
          >
            Respring
          </button>
          <button onClick={() => setNeedRespring(false)} className="px-1 text-[11px] text-muted active:text-fg">
            Later
          </button>
        </div>
      )}
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
                  onMenu={(e) => openMenu(e, k, it)}
                />
              )
            })}
          </ul>
        )}
      </div>

      {menu && (
        <RowMenu
          tab={tab}
          menu={menu}
          onClose={() => setMenu(null)}
          onToggleTweak={toggleTweak}
          onDownload={download}
          onCopy={copy}
          onUninstallPkg={(id, name) => {
            setMenu(null)
            setConfirm({ id, name })
          }}
          onUninstallTweak={askUninstallTweak}
          onShowFiles={(id, name) => {
            setMenu(null)
            setFilesFor({ id, name })
          }}
        />
      )}
      {confirm && (
        <ConfirmUninstall
          name={confirm.name}
          busy={removing}
          onCancel={() => setConfirm(null)}
          onConfirm={doUninstall}
        />
      )}
      {filesFor && <FilesOverlay pkg={filesFor} onClose={() => setFilesFor(null)} />}
      {note && (
        <div className="pointer-events-none fixed inset-x-0 bottom-6 z-[60] flex justify-center px-4">
          <div className="rounded-lg bg-black/80 px-3 py-1.5 text-[12px] font-medium text-white shadow-lg ring-1 ring-white/10">
            {note}
          </div>
        </div>
      )}
    </Sheet>
  )
}

function haystack(tab: Tab, it: Item): string {
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

function rowKey(tab: Tab, it: Item): string {
  if (tab === 'packages') return 'p:' + (it as Pkg).id
  if (tab === 'tweaks') return 't:' + (it as Tweak).path
  return 'd:' + (it as Dylib).path
}

function Row({
  tab,
  item,
  open,
  onToggle,
  onMenu,
}: {
  tab: Tab
  item: Item
  open: boolean
  onToggle: () => void
  onMenu: (e: React.MouseEvent) => void
}) {
  const disabledTweak = tab === 'tweaks' && !(item as Tweak).enabled
  const title = (item as { name: string }).name
  const size = (item as { size: number }).size
  const sub =
    tab === 'packages'
      ? `${(item as Pkg).version}${(item as Pkg).section ? ' · ' + (item as Pkg).section : ''}`
      : tab === 'tweaks'
        ? targetSummary(item as Tweak)
        : (item as Dylib).path
  return (
    <li className={cn('overflow-hidden rounded-lg bg-fg/[0.04] ring-1 ring-line/40', disabledTweak && 'opacity-55')}>
      <div className="flex items-center transition-colors hover:bg-fg/[0.05] active:bg-fg/[0.07]">
        <button onClick={onToggle} className="flex min-w-0 flex-1 items-center gap-2.5 px-2.5 py-2 text-left">
          <ChevronRight className={cn('size-3.5 shrink-0 text-faint transition-transform', open && 'rotate-90')} />
          <div className="min-w-0 flex-1">
            <div className="flex items-center gap-1.5">
              <span className="truncate text-[13px] font-medium text-fg">{title.trim()}</span>
              {disabledTweak && (
                <span className="shrink-0 rounded bg-fg/10 px-1 py-px text-[9px] font-semibold uppercase tracking-wide text-muted">
                  off
                </span>
              )}
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
        </button>
        {size > 0 && <span className="shrink-0 text-[11px] tabular-nums text-faint">{fmtSize(size)}</span>}
        <button
          onClick={onMenu}
          aria-label="Actions"
          className="ml-1 mr-1.5 grid size-7 shrink-0 place-items-center rounded-md text-fg-dim transition-colors hover:bg-fg/10 hover:text-fg active:bg-fg/15"
        >
          <MoreVertical className="size-4" />
        </button>
      </div>
      {open && <Detail tab={tab} item={item} />}
    </li>
  )
}

function RowMenu({
  tab,
  menu,
  onClose,
  onToggleTweak,
  onDownload,
  onCopy,
  onUninstallPkg,
  onUninstallTweak,
  onShowFiles,
}: {
  tab: Tab
  menu: Menu
  onClose: () => void
  onToggleTweak: (t: Tweak) => void
  onDownload: (path: string) => void
  onCopy: (text: string) => void
  onUninstallPkg: (id: string, name: string) => void
  onUninstallTweak: (t: Tweak) => void
  onShowFiles: (id: string, name: string) => void
}) {
  const W = 208
  const left = Math.max(8, Math.min(menu.x - W, window.innerWidth - W - 8))
  const top = Math.min(menu.y, window.innerHeight - 220)
  return (
    <>
      <button className="fixed inset-0 z-50 cursor-default" aria-label="Close menu" onClick={onClose} />
      <div
        className="fixed z-50 w-52 overflow-hidden rounded-xl bg-elevated p-1 shadow-2xl shadow-black/50 ring-1 ring-line-2"
        style={{ left, top }}
      >
        {tab === 'tweaks' &&
          (() => {
            const t = menu.item as Tweak
            return (
              <>
                <MenuItem icon={Power} label={t.enabled ? 'Disable' : 'Enable'} onClick={() => onToggleTweak(t)} />
                {t.present && <MenuItem icon={Download} label="Download .dylib" onClick={() => onDownload(t.path)} />}
                <MenuItem icon={Copy} label="Copy path" onClick={() => onCopy(t.path)} />
                <MenuItem icon={Trash2} label="Uninstall package…" danger onClick={() => onUninstallTweak(t)} />
              </>
            )
          })()}
        {tab === 'packages' &&
          (() => {
            const p = menu.item as Pkg
            return (
              <>
                <MenuItem icon={FileText} label="Show files" onClick={() => onShowFiles(p.id, p.name)} />
                <MenuItem icon={Copy} label="Copy identifier" onClick={() => onCopy(p.id)} />
                <MenuItem icon={Trash2} label="Uninstall…" danger onClick={() => onUninstallPkg(p.id, p.name)} />
              </>
            )
          })()}
        {tab === 'dylibs' &&
          (() => {
            const d = menu.item as Dylib
            return (
              <>
                <MenuItem icon={Download} label="Download" onClick={() => onDownload(d.path)} />
                <MenuItem icon={Copy} label="Copy path" onClick={() => onCopy(d.path)} />
              </>
            )
          })()}
      </div>
    </>
  )
}

function MenuItem({
  icon: Icon,
  label,
  onClick,
  danger,
}: {
  icon: ComponentType<LucideProps>
  label: string
  onClick: () => void
  danger?: boolean
}) {
  return (
    <button
      onClick={onClick}
      className={cn(
        'flex w-full items-center gap-2.5 rounded-lg px-2.5 py-2 text-left text-[13px] transition-colors',
        danger ? 'text-red-500 hover:bg-red-500/10 active:bg-red-500/15' : 'text-fg hover:bg-fg/8 active:bg-fg/12',
      )}
    >
      <Icon className="size-4 shrink-0" />
      {label}
    </button>
  )
}

function ConfirmUninstall({
  name,
  busy,
  onCancel,
  onConfirm,
}: {
  name: string
  busy: boolean
  onCancel: () => void
  onConfirm: () => void
}) {
  return (
    <div className="fixed inset-0 z-[55] flex items-center justify-center p-5">
      <button className="absolute inset-0 cursor-default bg-black/60 backdrop-blur-sm" aria-label="Cancel" onClick={onCancel} />
      <div className="relative z-10 w-full max-w-sm rounded-2xl bg-elevated p-4 text-fg shadow-2xl shadow-black/50 ring-1 ring-line-2">
        <div className="mb-1 flex items-center gap-2">
          <Trash2 className="size-4 text-red-500" />
          <h2 className="text-[14px] font-semibold">Uninstall {name}?</h2>
        </div>
        <p className="mb-4 text-[12px] leading-relaxed text-muted">
          Runs <span className="font-mono text-fg-dim">dpkg -r {name}</span> on the device. This removes the package and
          takes effect after a respring. It can’t be undone from here.
        </p>
        <div className="flex justify-end gap-2">
          <button
            onClick={onCancel}
            disabled={busy}
            className="rounded-lg bg-fg/8 px-3 py-1.5 text-[12px] font-medium text-fg-dim transition active:bg-fg/15 disabled:opacity-50"
          >
            Cancel
          </button>
          <button
            onClick={onConfirm}
            disabled={busy}
            className="rounded-lg bg-red-500 px-3 py-1.5 text-[12px] font-semibold text-white transition active:opacity-80 disabled:opacity-60"
          >
            {busy ? 'Removing…' : 'Uninstall'}
          </button>
        </div>
      </div>
    </div>
  )
}

function FilesOverlay({ pkg, onClose }: { pkg: { id: string; name: string }; onClose: () => void }) {
  const [files, setFiles] = useState<string[] | null>(null)
  useEffect(() => {
    apiJSON<{ files: string[] }>(`/v1/pkg_files?id=${enc(pkg.id)}`).then((j) => setFiles(j?.files ?? []))
  }, [pkg.id])
  return (
    <div className="fixed inset-0 z-[55] flex items-center justify-center p-5">
      <button className="absolute inset-0 cursor-default bg-black/60 backdrop-blur-sm" aria-label="Close" onClick={onClose} />
      <div className="relative z-10 flex max-h-[70dvh] w-full max-w-lg flex-col rounded-2xl bg-elevated text-fg shadow-2xl shadow-black/50 ring-1 ring-line-2">
        <header className="flex items-center gap-2 border-b border-line px-3.5 py-2.5">
          <FileText className="size-4 text-fg-dim" />
          <span className="mr-auto truncate text-[13px] font-semibold">{pkg.name}</span>
          <span className="text-[11px] tabular-nums text-faint">{files?.length ?? ''}</span>
        </header>
        <div className="min-h-0 flex-1 overflow-y-auto p-2">
          {files == null ? (
            <Hint>Loading…</Hint>
          ) : (
            <ul className="space-y-px font-mono text-[11px] text-fg-dim">
              {files.map((f) => (
                <li key={f} className="truncate rounded px-2 py-1 hover:bg-fg/[0.05]">
                  {f}
                </li>
              ))}
            </ul>
          )}
        </div>
      </div>
    </div>
  )
}

function targetSummary(t: Tweak): string {
  const n = t.bundles.length + t.executables.length
  if (n === 0) return 'global / no filter'
  if (t.bundles.length && !t.executables.length) return `${t.bundles.length} app${t.bundles.length > 1 ? 's' : ''}`
  return `${n} target${n > 1 ? 's' : ''}`
}

function Detail({ tab, item }: { tab: Tab; item: Item }) {
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
