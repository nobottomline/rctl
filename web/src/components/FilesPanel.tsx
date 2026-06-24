import { useEffect, useRef, useState, type ReactNode } from 'react'
import { ChevronRight, Download, File as FileIcon, Folder, RefreshCw, Trash2, Upload } from 'lucide-react'
import { api, apiJSON } from '../lib/rctl'
import { fmtSize, saveBlobToFile, type FileTransfer, type TransferStatus } from '../lib/files'
import { Sheet } from './Sheet'
import { cn } from '../lib/cn'

// Filesystem browser backed by rctld (root): /v1/ls to list, /v1/rm to delete,
// and the P2P "files" DataChannel for transfers of any size (/v1/pull & /v1/push
// are small-file fallbacks). Presented as a Sheet (modal/bottom-sheet), themed.
type Entry = { name: string; dir: boolean; size: number }

const enc = encodeURIComponent
const join = (d: string, n: string) => (d.endsWith('/') ? d : d + '/') + n

export default function FilesPanel({ transfer, onClose }: { transfer: FileTransfer; onClose: () => void }) {
  const [path, setPath] = useState('/')
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
    try {
      // Fetch over P2P (any size) then save in this click's async continuation --
      // Safari only allows the download while the user gesture is still live.
      const blob = await transfer.fetch(p)
      saveBlobToFile(blob, e.name)
      return
    } catch {
      /* channel busy/unavailable -> small-file HTTP fallback */
    }
    try {
      const b = await (await api(`/v1/pull?path=${enc(p)}`)).blob()
      saveBlobToFile(b, e.name)
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

  const toolbar = (
    <div className="flex items-center gap-1.5">
      <Breadcrumb path={path} onNav={load} />
      <ToolBtn onClick={() => load(path)} title="Refresh" spin={busy}>
        <RefreshCw className="size-4" />
      </ToolBtn>
      <ToolBtn onClick={() => fileInput.current?.click()} title="Upload">
        <Upload className="size-4" />
      </ToolBtn>
      <input ref={fileInput} type="file" hidden onChange={onPick} />
    </div>
  )

  return (
    <Sheet title="Files" onClose={onClose} toolbar={toolbar}>
      {status.text && (
        <div
          className={cn(
            'border-b border-line px-3.5 py-1.5 font-mono text-[12px]',
            status.kind === 'err' ? 'text-danger' : 'text-signal',
          )}
        >
          {status.text}
        </div>
      )}
      {sorted === null ? (
        <Note>…</Note>
      ) : sorted.length === 0 ? (
        <Note>empty</Note>
      ) : (
        <div className="divide-y divide-line/60">
          {sorted.map((e) => (
            <div key={e.name} className="flex items-center gap-2.5 px-3 py-2.5 transition-colors active:bg-fg/5">
              <button
                onClick={() => e.dir && load(join(path, e.name))}
                disabled={!e.dir}
                className="flex min-w-0 flex-1 items-center gap-2.5 text-left"
              >
                {e.dir ? (
                  <Folder className="size-[18px] shrink-0 text-signal" />
                ) : (
                  <FileIcon className="size-[18px] shrink-0 text-faint" />
                )}
                <span className={cn('truncate text-[13px] text-fg', e.dir && 'font-medium')}>{e.name}</span>
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
          ))}
        </div>
      )}
    </Sheet>
  )
}

function Breadcrumb({ path, onNav }: { path: string; onNav: (p: string) => void }) {
  const parts = path.split('/').filter(Boolean)
  const crumbs = [{ name: '/', full: '/' }, ...parts.map((name, i) => ({ name, full: '/' + parts.slice(0, i + 1).join('/') }))]
  return (
    <div className="flex min-w-0 flex-1 items-center overflow-x-auto">
      {crumbs.map((c, i) => (
        <div key={c.full} className="flex shrink-0 items-center">
          {i > 0 && <ChevronRight className="size-3 shrink-0 text-faint" />}
          <button
            onClick={() => onNav(c.full)}
            className={cn(
              'rounded px-1.5 py-0.5 text-[12px] transition-colors',
              i === crumbs.length - 1 ? 'font-semibold text-fg' : 'text-muted active:bg-fg/10',
            )}
          >
            {c.name}
          </button>
        </div>
      ))}
    </div>
  )
}

function Note({ children }: { children: ReactNode }) {
  return <div className="px-3.5 py-8 text-center font-mono text-[12px] text-muted">{children}</div>
}

function ToolBtn({
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
      className="grid size-8 shrink-0 place-items-center rounded-lg bg-fg/8 text-fg-dim transition-colors active:bg-fg/15"
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
        danger ? 'text-danger active:bg-danger/15' : 'text-muted active:bg-fg/10',
      )}
    >
      {children}
    </button>
  )
}
