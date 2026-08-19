import { useEffect, useMemo, useRef, useState, type ReactNode } from 'react'
import {
  Copy,
  Download,
  Film,
  Image as ImageIcon,
  LoaderCircle,
  MoreVertical,
  Play,
  RefreshCw,
  Search,
  Share2,
  Trash2,
  X,
  type LucideIcon,
} from 'lucide-react'
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
  animated?: boolean
  live?: boolean
  motion_path?: string
  motion_name?: string
  motion_size?: number
  deletable?: boolean
}
type Page = { items: Asset[]; total: number; next: number | null }
type Menu = { asset: Asset; x: number; y: number }

const PAGE_SIZE = 60
const MAX_VIDEO_PREVIEW = 250 * 1024 * 1024
const MAX_ANIMATED_PREVIEW = 50 * 1024 * 1024
const MAX_SHARE_SIZE = 100 * 1024 * 1024

function fmtDuration(seconds = 0) {
  const value = Math.max(0, Math.round(seconds))
  const hours = Math.floor(value / 3600)
  const minutes = Math.floor((value % 3600) / 60)
  const tail = String(value % 60).padStart(2, '0')
  return hours ? `${hours}:${String(minutes).padStart(2, '0')}:${tail}` : `${minutes}:${tail}`
}

function mediaType(name: string) {
  const ext = name.split('.').pop()?.toLowerCase()
  if (ext === 'gif') return 'image/gif'
  if (ext === 'png') return 'image/png'
  if (ext === 'jpg' || ext === 'jpeg') return 'image/jpeg'
  if (ext === 'heic' || ext === 'heif') return 'image/heic'
  if (ext === 'mp4' || ext === 'm4v') return 'video/mp4'
  if (ext === 'mov') return 'video/quicktime'
  return 'application/octet-stream'
}

async function clipboardPNG(asset: Asset) {
  if (!window.isSecureContext || !navigator.clipboard?.write || typeof ClipboardItem === 'undefined')
    throw new Error('Copy image requires HTTPS. Use Download or Share on a local HTTP connection.')
  const response = await fetch(rctlPath(`/v1/media_preview?id=${encodeURIComponent(asset.id)}`))
  if (!response.ok) throw new Error('Could not load the image preview.')
  const source = await response.blob()
  const url = URL.createObjectURL(source)
  try {
    const image = await new Promise<HTMLImageElement>((resolve, reject) => {
      const element = new Image()
      element.onload = () => resolve(element)
      element.onerror = () => reject(new Error('Could not decode the image preview.'))
      element.src = url
    })
    const canvas = document.createElement('canvas')
    canvas.width = image.naturalWidth
    canvas.height = image.naturalHeight
    const context = canvas.getContext('2d')
    if (!context) throw new Error('Image clipboard is unavailable in this browser.')
    context.drawImage(image, 0, 0)
    const png = await new Promise<Blob>((resolve, reject) =>
      canvas.toBlob((blob) => (blob ? resolve(blob) : reject(new Error('Could not encode the clipboard image.'))), 'image/png'),
    )
    await navigator.clipboard.write([new ClipboardItem({ 'image/png': png })])
  } finally {
    URL.revokeObjectURL(url)
  }
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
  const [menu, setMenu] = useState<Menu | null>(null)
  const [note, setNote] = useState('')
  const [confirmDelete, setConfirmDelete] = useState<Asset | null>(null)
  const [deleting, setDeleting] = useState(false)
  const requestSequence = useRef(0)

  const notify = (message: string) => {
    setNote(message)
    window.setTimeout(() => setNote(''), 2400)
  }

  const download = (asset: Asset) => {
    setMenu(null)
    if (!transfer.download(asset.path, asset.name)) notify('The P2P file channel is unavailable or busy.')
  }

  const copy = async (asset: Asset) => {
    setMenu(null)
    try {
      await clipboardPNG(asset)
      notify('Image copied')
    } catch (error) {
      notify(error instanceof Error ? error.message : 'Could not copy the image.')
    }
  }

  const share = async (asset: Asset) => {
    setMenu(null)
    if (!navigator.share) {
      notify('Sharing is unavailable in this browser.')
      return
    }
    if (asset.size > MAX_SHARE_SIZE) {
      notify(`Use Download for files larger than ${fmtSize(MAX_SHARE_SIZE)}.`)
      return
    }
    try {
      notify(`Preparing ${asset.name}…`)
      const source = await transfer.fetch(asset.path)
      const file = new File([source], asset.name, { type: mediaType(asset.name) })
      if (navigator.canShare && !navigator.canShare({ files: [file] }))
        throw new Error('This browser cannot share the original file type.')
      await navigator.share({ files: [file], title: asset.name })
      setNote('')
    } catch (error) {
      if (error instanceof DOMException && error.name === 'AbortError') setNote('')
      else notify(error instanceof Error ? error.message : 'Could not share the original.')
    }
  }

  const openMenu = (asset: Asset, x: number, y: number) => setMenu({ asset, x, y })

  const askDelete = (asset: Asset) => {
    setMenu(null)
    if (asset.deletable) setConfirmDelete(asset)
  }

  const remove = async () => {
    if (!confirmDelete || deleting) return
    setDeleting(true)
    const id = encodeURIComponent(confirmDelete.id)
    const request = { method: 'POST', headers: { 'Content-Type': 'application/json' } }
    const authorization = await apiJSON<{ token: string }>(`/v1/media_delete_token?id=${id}`, {
      ...request,
      body: '{}',
    })
    const result = authorization?.token
      ? await apiJSON<{ ok: boolean }>(`/v1/media_delete?id=${id}`, {
          ...request,
          body: JSON.stringify({ token: authorization.token }),
        })
      : null
    setDeleting(false)
    if (!result?.ok) {
      notify('The item could not be moved to Recently Deleted.')
      return
    }
    const removedID = confirmDelete.id
    setConfirmDelete(null)
    if (selected?.id === removedID) setSelected(null)
    notify('Moved to Recently Deleted')
    await load(0, true)
  }

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
              <div
                key={asset.id}
                className="group relative aspect-square min-w-0 overflow-hidden bg-surface"
                onContextMenu={(event) => {
                  event.preventDefault()
                  openMenu(asset, event.clientX, event.clientY)
                }}
              >
                <button
                  onClick={() => setSelected(asset)}
                  className="absolute inset-0 size-full text-left"
                  aria-label={`Open ${asset.name}`}
                >
                  <img
                    src={rctlPath(`/v1/media_thumb?id=${encodeURIComponent(asset.id)}&v=${generation}`)}
                    alt=""
                    loading="lazy"
                    className="size-full object-cover transition duration-200 group-active:scale-[0.98] group-active:opacity-80"
                  />
                </button>
                <button
                  onClick={(event) => {
                    event.stopPropagation()
                    const rect = event.currentTarget.getBoundingClientRect()
                    openMenu(asset, rect.right, rect.bottom + 4)
                  }}
                  aria-label={`Actions for ${asset.name}`}
                  title="Actions"
                  className="absolute right-1 top-1 z-10 grid size-7 place-items-center rounded-md bg-black/65 text-white opacity-100 ring-1 ring-white/15 transition sm:opacity-0 sm:group-hover:opacity-100 sm:focus:opacity-100"
                >
                  <MoreVertical className="size-4" />
                </button>
                {asset.live && (
                  <span className="pointer-events-none absolute bottom-1 left-1 rounded-md bg-black/70 px-1.5 py-1 text-[10px] font-semibold text-white ring-1 ring-white/15">
                    LIVE
                  </span>
                )}
                {asset.type === 'video' && (
                  <span className="pointer-events-none absolute bottom-1 right-1 flex h-6 items-center gap-1 rounded-md bg-black/70 px-1.5 text-[10px] font-medium text-white ring-1 ring-white/15">
                    <Play className="size-2.5 fill-current" />
                    {asset.duration && asset.duration > 0 ? fmtDuration(asset.duration) : 'Video'}
                  </span>
                )}
              </div>
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
      {menu && (
        <MediaMenu
          menu={menu}
          onClose={() => setMenu(null)}
          onDownload={download}
          onCopy={copy}
          onShare={share}
          onDelete={askDelete}
        />
      )}
      {selected && (
        <MediaViewer
          asset={selected}
          transfer={transfer}
          onClose={() => setSelected(null)}
          onDownload={download}
          onCopy={copy}
          onShare={share}
          onDelete={askDelete}
        />
      )}
      {confirmDelete && (
        <ConfirmMediaDelete
          asset={confirmDelete}
          busy={deleting}
          onCancel={() => setConfirmDelete(null)}
          onConfirm={remove}
        />
      )}
      {note && (
        <div className="pointer-events-none fixed inset-x-0 bottom-6 z-[70] flex justify-center px-4">
          <div className="max-w-md rounded-lg bg-black/85 px-3 py-2 text-center text-[12px] font-medium text-white shadow-xl ring-1 ring-white/10">
            {note}
          </div>
        </div>
      )}
    </>
  )
}

function MediaMenu({
  menu,
  onClose,
  onDownload,
  onCopy,
  onShare,
  onDelete,
}: {
  menu: Menu
  onClose: () => void
  onDownload: (asset: Asset) => void
  onCopy: (asset: Asset) => void
  onShare: (asset: Asset) => void
  onDelete: (asset: Asset) => void
}) {
  const width = 216
  const left = Math.max(8, Math.min(menu.x - width, window.innerWidth - width - 8))
  const top = Math.max(8, Math.min(menu.y, window.innerHeight - 172))
  return (
    <>
      <button className="fixed inset-0 z-[55] cursor-default" aria-label="Close actions" onClick={onClose} />
      <div
        className="fixed z-[56] w-[13.5rem] overflow-hidden rounded-lg bg-elevated p-1 text-fg shadow-2xl shadow-black/50 ring-1 ring-line-2"
        style={{ left, top }}
      >
        <MediaMenuItem icon={Download} label="Download original" onClick={() => onDownload(menu.asset)} />
        {menu.asset.type === 'photo' && <MediaMenuItem icon={Copy} label="Copy image" onClick={() => onCopy(menu.asset)} />}
        <MediaMenuItem icon={Share2} label="Share…" onClick={() => onShare(menu.asset)} />
        {menu.asset.deletable && (
          <MediaMenuItem icon={Trash2} label="Delete…" danger onClick={() => onDelete(menu.asset)} />
        )}
      </div>
    </>
  )
}

function MediaMenuItem({
  icon: Icon,
  label,
  onClick,
  danger = false,
}: {
  icon: LucideIcon
  label: string
  onClick: () => void
  danger?: boolean
}) {
  return (
    <button
      onClick={onClick}
      className={cn(
        'flex w-full items-center gap-2.5 rounded-md px-2.5 py-2 text-left text-[13px] transition-colors',
        danger ? 'text-red-500 hover:bg-red-500/10 active:bg-red-500/15' : 'text-fg hover:bg-fg/8 active:bg-fg/12',
      )}
    >
      <Icon className="size-4 shrink-0" />
      {label}
    </button>
  )
}

function MediaViewer({
  asset,
  transfer,
  onClose,
  onDownload,
  onCopy,
  onShare,
  onDelete,
}: {
  asset: Asset
  transfer: FileTransfer
  onClose: () => void
  onDownload: (asset: Asset) => void
  onCopy: (asset: Asset) => void
  onShare: (asset: Asset) => void
  onDelete: (asset: Asset) => void
}) {
  const [loaded, setLoaded] = useState<{ url: string; kind: 'image' | 'video' } | null>(null)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')
  const date = useMemo(() => new Date(asset.created * 1000), [asset.created])
  const previewTooLarge = asset.type === 'video' && asset.size > MAX_VIDEO_PREVIEW
  const animationTooLarge = asset.animated && asset.size > MAX_ANIMATED_PREVIEW

  const loadResource = async (path: string, name: string, kind: 'image' | 'video') => {
    if (busy || loaded) return
    setBusy(true)
    setError('')
    try {
      const source = await transfer.fetch(path)
      const blob = new Blob([source], { type: mediaType(name) })
      setLoaded({ url: URL.createObjectURL(blob), kind })
    } catch {
      setError('The P2P file channel is unavailable or busy.')
    } finally {
      setBusy(false)
    }
  }

  useEffect(() => () => { if (loaded) URL.revokeObjectURL(loaded.url) }, [loaded])

  const preview = rctlPath(`/v1/media_preview?id=${encodeURIComponent(asset.id)}`)
  const thumb = rctlPath(`/v1/media_thumb?id=${encodeURIComponent(asset.id)}`)
  const playableLabel = asset.live ? 'Play Live Photo' : asset.animated ? 'Play GIF' : 'Play'
  const playableSize = asset.live ? asset.motion_size ?? 0 : asset.size
  const cannotLoad = previewTooLarge || animationTooLarge || (asset.live && playableSize > MAX_VIDEO_PREVIEW)

  return (
    <div className="fixed inset-0 z-50 flex flex-col bg-black text-white">
      <header className="flex h-12 shrink-0 items-center gap-2 border-b border-white/10 bg-black/85 px-3 backdrop-blur-xl">
        <div className="min-w-0 flex-1">
          <div className="truncate text-[13px] font-medium">{asset.name}</div>
          <div className="truncate font-mono text-[10px] text-white/45">
            {date.toLocaleString()} · {fmtSize(asset.size)}{asset.live ? ' · Live Photo' : asset.animated ? ' · GIF' : ''}
          </div>
        </div>
        {asset.type === 'photo' && (
          <button onClick={() => onCopy(asset)} title="Copy image" aria-label="Copy image" className="grid size-8 place-items-center rounded-lg bg-white/10 text-white/80 active:bg-white/20">
            <Copy className="size-4" />
          </button>
        )}
        <button onClick={() => onShare(asset)} title="Share original" aria-label="Share original" className="grid size-8 place-items-center rounded-lg bg-white/10 text-white/80 active:bg-white/20">
          <Share2 className="size-4" />
        </button>
        <button onClick={() => onDownload(asset)} title="Download original" aria-label="Download original" className="grid size-8 place-items-center rounded-lg bg-white/10 text-white/80 active:bg-white/20">
          <Download className="size-4" />
        </button>
        {asset.deletable && (
          <button onClick={() => onDelete(asset)} title="Delete" aria-label="Delete" className="grid size-8 place-items-center rounded-lg bg-red-500/15 text-red-400 active:bg-red-500/25">
            <Trash2 className="size-4" />
          </button>
        )}
        <button onClick={onClose} aria-label="Close preview" className="grid size-8 place-items-center rounded-lg bg-white/10 text-white/80 active:bg-white/20">
          <X className="size-4" />
        </button>
      </header>
      <div className="relative flex min-h-0 flex-1 items-center justify-center overflow-hidden bg-black">
        {loaded?.kind === 'image' && <img src={loaded.url} alt={asset.name} className="max-h-full max-w-full object-contain" />}
        {loaded?.kind === 'video' && (
          <video
            src={loaded.url}
            controls
            autoPlay
            playsInline
            className="max-h-full max-w-full"
            onError={() => setError('This browser cannot decode the original video codec. Download the original to keep it intact.')}
          />
        )}
        {!loaded && asset.type === 'photo' && (
          <img src={preview} alt={asset.name} className="max-h-full max-w-full object-contain" />
        )}
        {!loaded && asset.type === 'video' && (
          <img src={thumb} alt="" className="size-full object-contain opacity-55" />
        )}
        {!loaded && (asset.type === 'video' || asset.animated || asset.live) && (
          <div className="absolute inset-0 grid place-items-center bg-black/25">
            {cannotLoad ? (
              <div className="max-w-sm rounded-lg bg-black/75 px-4 py-3 text-center text-[12px] text-white/75">
                Download the {fmtSize(playableSize)} original to view it without exhausting browser memory.
              </div>
            ) : (
              <button
                onClick={() => {
                  if (asset.live && asset.motion_path)
                    loadResource(asset.motion_path, asset.motion_name || 'live.mov', 'video')
                  else loadResource(asset.path, asset.name, asset.animated ? 'image' : 'video')
                }}
                disabled={busy}
                className="flex items-center gap-2 rounded-full bg-white px-5 py-2.5 text-[13px] font-semibold text-black shadow-xl disabled:opacity-60"
              >
                {busy ? <LoaderCircle className="size-4 animate-spin" /> : asset.animated ? <ImageIcon className="size-4" /> : <Film className="size-4" />}
                {busy ? 'Loading original…' : `${playableLabel} · ${fmtSize(playableSize)}`}
              </button>
            )}
          </div>
        )}
        {error && <div className="absolute bottom-5 max-w-md rounded-lg bg-danger/90 px-3 py-2 text-center text-[12px] text-white">{error}</div>}
      </div>
    </div>
  )
}

function ConfirmMediaDelete({
  asset,
  busy,
  onCancel,
  onConfirm,
}: {
  asset: Asset
  busy: boolean
  onCancel: () => void
  onConfirm: () => void
}) {
  return (
    <div className="fixed inset-0 z-[65] flex items-center justify-center p-5">
      <button className="absolute inset-0 cursor-default bg-black/60 backdrop-blur-sm" aria-label="Cancel delete" onClick={onCancel} />
      <div className="relative z-10 w-full max-w-sm rounded-lg bg-elevated p-4 text-fg shadow-2xl shadow-black/50 ring-1 ring-line-2">
        <div className="mb-1 flex items-center gap-2">
          <Trash2 className="size-4 text-red-500" />
          <h2 className="min-w-0 truncate text-[14px] font-semibold">Delete {asset.name}?</h2>
        </div>
        <p className="mb-4 text-[12px] leading-relaxed text-muted">
          This moves the {asset.live ? 'Live Photo and its motion resource' : asset.type === 'video' ? 'video' : 'photo'} to Recently Deleted on the iPad. It can be recovered there until Photos removes it permanently.
        </p>
        <div className="flex justify-end gap-2">
          <button
            onClick={onCancel}
            disabled={busy}
            className="rounded-lg bg-fg/8 px-3 py-1.5 text-[12px] font-medium text-fg-dim active:bg-fg/15 disabled:opacity-50"
          >
            Cancel
          </button>
          <button
            onClick={onConfirm}
            disabled={busy}
            className="rounded-lg bg-red-500 px-3 py-1.5 text-[12px] font-semibold text-white active:opacity-80 disabled:opacity-60"
          >
            {busy ? 'Deleting…' : 'Delete'}
          </button>
        </div>
      </div>
    </div>
  )
}

function Empty({ children }: { children: ReactNode }) {
  return <div className="flex min-h-56 flex-col items-center justify-center gap-2 text-[12px] text-muted">{children}</div>
}
