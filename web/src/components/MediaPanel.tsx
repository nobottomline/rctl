import { useEffect, useMemo, useRef, useState, type ReactNode } from 'react'
import { Download, Film, Image as ImageIcon, LoaderCircle, Play, RefreshCw, Search, X } from 'lucide-react'
import { apiJSON, rctlPath } from '../lib/rctl'
import { fmtSize, type FileTransfer } from '../lib/files'
import { cn } from '../lib/cn'
import { Sheet } from './Sheet'

type Kind = 'all' | 'photo' | 'video'
type Asset = {
  id: string
  name: string
  path: string
  type: 'photo' | 'video'
  size: number
  created: number
  width?: number
  height?: number
  duration?: number
}
type Page = { items: Asset[]; total: number; next: number | null }

const PAGE_SIZE = 60
const MAX_VIDEO_PREVIEW = 250 * 1024 * 1024

function fmtDuration(seconds = 0) {
  const value = Math.max(0, Math.round(seconds))
  const hours = Math.floor(value / 3600)
  const minutes = Math.floor((value % 3600) / 60)
  const tail = String(value % 60).padStart(2, '0')
  return hours ? `${hours}:${String(minutes).padStart(2, '0')}:${tail}` : `${minutes}:${tail}`
}

export default function MediaPanel({ transfer, onClose }: { transfer: FileTransfer; onClose: () => void }) {
  const [kind, setKind] = useState<Kind>('all')
  const [query, setQuery] = useState('')
  const [items, setItems] = useState<Asset[]>([])
  const [total, setTotal] = useState(0)
  const [next, setNext] = useState<number | null>(null)
  const [busy, setBusy] = useState(false)
  const [selected, setSelected] = useState<Asset | null>(null)
  const [generation, setGeneration] = useState(0)
  const requestSequence = useRef(0)

  const load = async (cursor = 0, refresh = false) => {
    const request = ++requestSequence.current
    setBusy(true)
    const params = new URLSearchParams({ type: kind, cursor: String(cursor), limit: String(PAGE_SIZE) })
    if (query.trim()) params.set('q', query.trim())
    if (refresh) params.set('refresh', '1')
    const page = await apiJSON<Page>(`/v1/media?${params}`)
    if (request !== requestSequence.current) return
    if (page) {
      setItems((old) => (cursor ? [...old, ...page.items] : page.items))
      setTotal(page.total)
      setNext(page.next)
      if (refresh) setGeneration((v) => v + 1)
    } else if (!cursor) {
      setItems([])
      setTotal(0)
      setNext(null)
    }
    setBusy(false)
  }

  useEffect(() => {
    const timer = window.setTimeout(() => load(0), query ? 250 : 0)
    return () => {
      clearTimeout(timer)
      requestSequence.current += 1
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [kind, query])

  const title = kind === 'all' ? 'Media' : kind === 'photo' ? 'Photos' : 'Videos'
  const emptyLabel = kind === 'photo' ? 'No photos found' : kind === 'video' ? 'No videos found' : 'No media found'

  const toolbar = (
    <div className="flex items-center gap-2">
      <div className="flex rounded-lg bg-fg/6 p-1">
        {(['all', 'photo', 'video'] as const).map((value) => (
          <button
            key={value}
            onClick={() => setKind(value)}
            className={cn(
              'rounded-md px-2.5 py-1 text-[11px] font-medium transition-colors',
              kind === value ? 'bg-signal text-on-signal' : 'text-fg-dim active:bg-fg/10',
            )}
          >
            {value === 'all' ? 'All' : value === 'photo' ? 'Photos' : 'Videos'}
          </button>
        ))}
      </div>
      <div className="relative min-w-0 flex-1">
        <Search className="pointer-events-none absolute left-2 top-1/2 size-3.5 -translate-y-1/2 text-faint" />
        <input
          value={query}
          onChange={(event) => setQuery(event.target.value)}
          placeholder="Search"
          className="h-8 w-full rounded-lg bg-fg/6 pl-7 pr-2 text-[12px] text-fg outline-none placeholder:text-faint"
        />
      </div>
      <button
        onClick={() => load(0, true)}
        aria-label="Refresh library"
        title="Refresh library"
        className="grid size-8 shrink-0 place-items-center rounded-lg bg-fg/8 text-fg-dim active:bg-fg/15"
      >
        <RefreshCw className={cn('size-4', busy && 'animate-spin')} />
      </button>
    </div>
  )

  return (
    <>
      <Sheet title={<span>{title} <span className="ml-1 font-mono text-[11px] font-normal text-muted">{total}</span></span>} onClose={onClose} toolbar={toolbar} wide>
        {busy && items.length === 0 ? (
          <Empty><LoaderCircle className="size-5 animate-spin" />Loading library</Empty>
        ) : items.length === 0 ? (
          <Empty><ImageIcon className="size-5" />{emptyLabel}</Empty>
        ) : (
          <div className="grid grid-cols-3 gap-px bg-line p-px sm:grid-cols-5 md:grid-cols-6">
            {items.map((asset) => (
              <button
                key={asset.id}
                onClick={() => setSelected(asset)}
                className="group relative aspect-square min-w-0 overflow-hidden bg-surface text-left"
                aria-label={`Open ${asset.name}`}
              >
                <img
                  src={rctlPath(`/v1/media_thumb?id=${encodeURIComponent(asset.id)}&v=${generation}`)}
                  alt=""
                  loading="lazy"
                  className="size-full object-cover transition duration-200 group-active:scale-[0.98] group-active:opacity-80"
                />
                {asset.type === 'video' && (
                  <span className="absolute bottom-1 right-1 flex h-6 items-center gap-1 rounded-md bg-black/70 px-1.5 text-[10px] font-medium text-white ring-1 ring-white/15">
                    <Play className="size-2.5 fill-current" />
                    {asset.duration && asset.duration > 0 ? fmtDuration(asset.duration) : 'Video'}
                  </span>
                )}
              </button>
            ))}
          </div>
        )}
        {next !== null && (
          <div className="flex justify-center border-t border-line p-3">
            <button
              disabled={busy}
              onClick={() => load(next)}
              className="rounded-lg bg-fg/8 px-4 py-2 text-[12px] font-medium text-fg disabled:opacity-50"
            >
              {busy ? 'Loading…' : `Load more · ${items.length} of ${total}`}
            </button>
          </div>
        )}
      </Sheet>
      {selected && <MediaViewer asset={selected} transfer={transfer} onClose={() => setSelected(null)} />}
    </>
  )
}

function MediaViewer({ asset, transfer, onClose }: { asset: Asset; transfer: FileTransfer; onClose: () => void }) {
  const [url, setURL] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')
  const date = useMemo(() => new Date(asset.created * 1000), [asset.created])
  const previewTooLarge = asset.type === 'video' && asset.size > MAX_VIDEO_PREVIEW

  const loadOriginal = async () => {
    if (busy || url) return
    setBusy(true)
    setError('')
    try {
      const blob = await transfer.fetch(asset.path)
      setURL(URL.createObjectURL(blob))
    } catch {
      setError('The P2P file channel is unavailable or busy.')
    } finally {
      setBusy(false)
    }
  }

  useEffect(() => () => { if (url) URL.revokeObjectURL(url) }, [url])

  const download = () => {
    if (!transfer.download(asset.path, asset.name)) setError('The P2P file channel is unavailable or busy.')
  }

  return (
    <div className="fixed inset-0 z-50 flex flex-col bg-black text-white">
      <header className="flex h-12 shrink-0 items-center gap-3 border-b border-white/10 bg-black/85 px-3 backdrop-blur-xl">
        <div className="min-w-0 flex-1">
          <div className="truncate text-[13px] font-medium">{asset.name}</div>
          <div className="truncate font-mono text-[10px] text-white/45">{date.toLocaleString()} · {fmtSize(asset.size)}</div>
        </div>
        <button onClick={download} title="Download original" aria-label="Download original" className="grid size-8 place-items-center rounded-lg bg-white/10 text-white/80 active:bg-white/20">
          <Download className="size-4" />
        </button>
        <button onClick={onClose} aria-label="Close preview" className="grid size-8 place-items-center rounded-lg bg-white/10 text-white/80 active:bg-white/20">
          <X className="size-4" />
        </button>
      </header>
      <div className="relative flex min-h-0 flex-1 items-center justify-center overflow-hidden bg-black">
        {asset.type === 'photo' && (
          <img
            src={rctlPath(`/v1/media_preview?id=${encodeURIComponent(asset.id)}`)}
            alt={asset.name}
            className="max-h-full max-w-full object-contain"
          />
        )}
        {url && asset.type === 'video' && <video src={url} controls autoPlay playsInline className="max-h-full max-w-full" />}
        {!url && asset.type === 'video' && (
          <div className="absolute inset-0">
            <img src={rctlPath(`/v1/media_thumb?id=${encodeURIComponent(asset.id)}`)} alt="" className="size-full object-contain opacity-55" />
            <div className="absolute inset-0 grid place-items-center bg-black/25">
              {previewTooLarge ? (
                <div className="rounded-lg bg-black/75 px-4 py-3 text-center text-[12px] text-white/75">
                  Download the {fmtSize(asset.size)} original to view it without exhausting browser memory.
                </div>
              ) : (
                <button onClick={loadOriginal} disabled={busy} className="flex items-center gap-2 rounded-full bg-white px-5 py-2.5 text-[13px] font-semibold text-black shadow-xl disabled:opacity-60">
                  {busy ? <LoaderCircle className="size-4 animate-spin" /> : <Film className="size-4" />}
                  {busy ? 'Loading original…' : `Play · ${fmtSize(asset.size)}`}
                </button>
              )}
            </div>
          </div>
        )}
        {error && <div className="absolute bottom-5 rounded-lg bg-danger/90 px-3 py-2 text-[12px] text-white">{error}</div>}
      </div>
    </div>
  )
}

function Empty({ children }: { children: ReactNode }) {
  return <div className="flex min-h-56 flex-col items-center justify-center gap-2 text-[12px] text-muted">{children}</div>
}
