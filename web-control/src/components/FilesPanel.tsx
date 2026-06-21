import { useEffect, useRef, useState, type ReactNode } from 'react'
import { ArrowUp, Download, File as FileIcon, Folder, RefreshCw, Trash2, Upload, X } from 'lucide-react'
import { api, apiJSON } from '../lib/rctl'
import { fmtSize, type FileTransfer, type TransferStatus } from '../lib/files'
import { cn } from '../lib/cn'

// Filesystem browser backed by rctld (root): /v1/ls to list, /v1/rm to delete,
// and the P2P "files" DataChannel for transfers of any size (with /v1/pull and
// /v1/push as small-file fallbacks when the channel isn't open). Mobile-adapted:
// fullscreen, safe-area insets, touch-sized rows.
type Entry = { name: string; dir: boolean; size: number }

const enc = encodeURIComponent
const join = (d: string, n: string) => (d.endsWith('/') ? d : d + '/') + n
const parent = (d: string) => {
  const c = d.replace(/\/+$/, '')
  const i = c.lastIndexOf('/')
  return i <= 0 ? '/' : c.slice(0, i)
}

export default function FilesPanel({ transfer, onClose }: { transfer: FileTransfer; onClose: () => void }) {
  const [path, setPath] = useState('/')
  const [draft, setDraft] = useState('/')
  const [entries, setEntries] = useState<Entry[] | null>(null)
  const [busy, setBusy] = useState(false)
  const [status, setStatus] = useState<TransferStatus>({ text: '', kind: 'idle' })
  const pathRef = useRef('/')
  const fileInput = useRef<HTMLInputElement>(null)

  const load = async (dir: string) => {
    setBusy(true)
    const j = await apiJSON<{ path?: string; entries?: Entry[]; error?: string }>(`/v1/ls?path=${enc(dir)}`)
    setBusy(false)
    if (!j || j.error) {
      setEntries([])
      return
    }
    const resolved = j.path || dir
    pathRef.current = resolved
    setPath(resolved)
    setDraft(resolved)
    setEntries(j.entries || [])
  }

  useEffect(() => {
    transfer.onStatus = setStatus
    transfer.onDone = () => load(pathRef.current)
    load('/')
    return () => {
      transfer.onStatus = () => {}
      transfer.onDone = () => {}
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [])

  const download = async (e: Entry) => {
    const p = join(path, e.name)
    if (transfer.download(p, e.name)) return // P2P, any size
    try {
      const b = await (await api(`/v1/pull?path=${enc(p)}`)).blob()
      const u = URL.createObjectURL(b)
      const a = document.createElement('a')
      a.href = u
      a.download = e.name
      a.click()
      URL.revokeObjectURL(u)
    } catch {
      /* ignore */
    }
  }

  const del = async (e: Entry) => {
    await api(`/v1/rm?path=${enc(join(path, e.name))}`).catch(() => {})
    load(path)
  }

  const onPick = async () => {
    const f = fileInput.current?.files?.[0]
    if (!f) return
    const dest = join(path, f.name)
    if (fileInput.current) fileInput.current.value = ''
    if (await transfer.upload(f, dest)) return // P2P; onDone reloads
    try {
      await api(`/v1/push?path=${enc(dest)}`, { method: 'POST', body: await f.arrayBuffer() })
    } catch {
      /* ignore */
    }
    load(path)
  }

  const sorted = entries
    ? [...entries].sort((a, b) => (a.dir !== b.dir ? (a.dir ? -1 : 1) : a.name.localeCompare(b.name)))
    : null

  return (
    <div
      className="fixed inset-x-0 top-0 z-40 flex flex-col bg-bg text-white"
      style={{ height: '100dvh', paddingTop: 'env(safe-area-inset-top)' }}
    >
      <div className="flex h-12 shrink-0 items-center gap-1.5 border-b border-line-2 px-2.5">
        <input
          value={draft}
          onChange={(e) => setDraft(e.target.value)}
          onKeyDown={(e) => e.key === 'Enter' && load(draft)}
          spellCheck={false}
          autoCapitalize="off"
          autoCorrect="off"
          className="mr-auto min-w-0 flex-1 rounded-lg bg-white/8 px-2.5 py-1.5 font-mono text-[12px] text-white outline-none ring-1 ring-line-2 focus:ring-signal"
        />
        <IconBtn onClick={() => load(parent(path))} title="Up">
          <ArrowUp className="size-4" />
        </IconBtn>
        <IconBtn onClick={() => load(path)} title="Refresh" spin={busy}>
          <RefreshCw className="size-4" />
        </IconBtn>
        <IconBtn onClick={() => fileInput.current?.click()} title="Upload">
          <Upload className="size-4" />
        </IconBtn>
        <IconBtn onClick={onClose} title="Close">
          <X className="size-4" />
        </IconBtn>
        <input ref={fileInput} type="file" hidden onChange={onPick} />
      </div>

      {status.text && (
        <div
          className={cn(
            'shrink-0 px-3.5 py-1.5 font-mono text-[12px]',
            status.kind === 'err' ? 'text-red-400' : 'text-signal',
          )}
        >
          {status.text}
        </div>
      )}

      <div
        className="min-h-0 flex-1 overflow-y-auto"
        style={{ paddingBottom: 'env(safe-area-inset-bottom)' }}
      >
        {sorted === null ? (
          <Note>…</Note>
        ) : sorted.length === 0 ? (
          <Note>(empty)</Note>
        ) : (
          sorted.map((e) => (
            <div
              key={e.name}
              className="flex items-center gap-2.5 border-b border-line/60 px-3.5 py-2.5"
            >
              <button
                onClick={() => e.dir && load(join(path, e.name))}
                className="flex min-w-0 flex-1 items-center gap-2.5 text-left"
              >
                {e.dir ? (
                  <Folder className="size-4 shrink-0 text-signal" />
                ) : (
                  <FileIcon className="size-4 shrink-0 text-muted" />
                )}
                <span className={cn('truncate text-[13px]', e.dir && 'font-medium')}>{e.name}</span>
              </button>
              {!e.dir && <span className="shrink-0 font-mono text-[11px] text-muted">{fmtSize(e.size)}</span>}
              {!e.dir && (
                <RowBtn onClick={() => download(e)} title="Download">
                  <Download className="size-4" />
                </RowBtn>
              )}
              <RowBtn onClick={() => del(e)} title="Delete" danger>
                <Trash2 className="size-4" />
              </RowBtn>
            </div>
          ))
        )}
      </div>
    </div>
  )
}

function Note({ children }: { children: React.ReactNode }) {
  return <div className="px-3.5 py-6 text-center text-[12px] text-muted">{children}</div>
}

function IconBtn({
  onClick,
  title,
  spin,
  children,
}: {
  onClick: () => void
  title: string
  spin?: boolean
  children: ReactNode
}) {
  return (
    <button
      onClick={onClick}
      title={title}
      aria-label={title}
      className="grid size-9 shrink-0 place-items-center rounded-lg bg-white/10 text-white transition-colors active:bg-white/20"
    >
      <span className={cn(spin && 'animate-spin')}>{children}</span>
    </button>
  )
}

function RowBtn({
  onClick,
  title,
  danger,
  children,
}: {
  onClick: () => void
  title: string
  danger?: boolean
  children: ReactNode
}) {
  return (
    <button
      onClick={onClick}
      title={title}
      aria-label={title}
      className={cn(
        'grid size-8 shrink-0 place-items-center rounded-lg transition-colors',
        danger ? 'text-red-400 active:bg-red-500/15' : 'text-muted active:bg-white/15',
      )}
    >
      {children}
    </button>
  )
}
