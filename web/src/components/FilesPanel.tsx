import { useEffect, useRef, useState, type ReactNode } from 'react'
import { ChevronRight, Download, File as FileIcon, Folder, RefreshCw, Trash2, Upload } from 'lucide-react'
import { api, apiJSON, destructivePost, downloadFile } from '../lib/rctl'
import { fmtSize, type FileTransfer, type TransferStatus } from '../lib/files'
import { Sheet, DialogOverlay } from './Sheet'
import { cn } from '../lib/cn'

// Filesystem browser backed by rctld (root): /v1/ls to list, /v1/rm to delete,
// bounded HTTP streaming for downloads, and the P2P "files" DataChannel for
// uploads. Presented as a Sheet (modal/bottom-sheet), themed.
type Entry = { name: string; dir: boolean; size: number }

const enc = encodeURIComponent
const join = (d: string, n: string) => (d.endsWith('/') ? d : d + '/') + n

export default function FilesPanel({ transfer, onClose }: { transfer: FileTransfer; onClose: () => void }) {
  const [path, setPath] = useState('/')
  const [entries, setEntries] = useState<Entry[] | null>(null)
  const [busy, setBusy] = useState(false)
  const [status, setStatus] = useState<TransferStatus>({ text: '', kind: 'idle' })
  const [loadError, setLoadError] = useState(false)
  const [failedPath, setFailedPath] = useState('/') // the listing Retry should re-request
  const [deleteTarget, setDeleteTarget] = useState<string | null>(null)
  const [deleting, setDeleting] = useState(false)
  const [deleteError, setDeleteError] = useState('')
  const pathRef = useRef('/')
  const fileInput = useRef<HTMLInputElement>(null)
  const loadSequence = useRef(0)
  // The folder the user last asked for, plus the busy mirror and a pending
  // flag for background refreshes that must not outrun a navigation.
  const viewedRef = useRef('/')
  const busyRef = useRef(false)
  const pendingRefresh = useRef(false)

  // A background refresh (transfer completion, finished delete or upload)
  // must never outrun the user's navigation: while a listing is in flight the
  // request is queued behind it and re-targets the folder being viewed then.
  const refreshInBackground = () => {
    if (busyRef.current) pendingRefresh.current = true
    else void load(viewedRef.current)
  }

  const load = async (dir: string) => {
    const request = ++loadSequence.current
    viewedRef.current = dir
    busyRef.current = true
    setBusy(true)
    const j = await apiJSON<{ path?: string; entries?: Entry[]; error?: string }>(`/v1/ls?path=${enc(dir)}`)
    if (request !== loadSequence.current) return // a newer listing superseded this one
    busyRef.current = false
    setBusy(false)
    // A failed listing used to render as an empty folder; say so and offer a
    // retry of the exact folder that failed (path only advances on success).
    if (!j || j.error) {
      setLoadError(true)
      setFailedPath(dir)
      setEntries([])
    } else {
      setLoadError(false)
      const resolved = j.path || dir
      pathRef.current = resolved
      setPath(resolved)
      setEntries(j.entries || [])
    }
    // A file transfer finished while this listing ran: refresh the folder the
    // user is viewing now, never the one the transfer happened to target.
    if (pendingRefresh.current) {
      pendingRefresh.current = false
      void load(viewedRef.current)
    }
  }

  useEffect(() => {
    transfer.onStatus = setStatus
    transfer.onDone = refreshInBackground
    load('/')
    return () => {
      transfer.onStatus = () => {}
      transfer.onDone = () => {}
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [])

  const download = (e: Entry) => downloadFile(join(path, e.name), e.name)

  const del = async () => {
    if (!deleteTarget) return
    setDeleting(true)
    setDeleteError('')
    try {
      await destructivePost<{ ok?: boolean }>('/v1/rm', 'file_delete', deleteTarget, { path: deleteTarget })
      setDeleteTarget(null)
      refreshInBackground()
    } catch (error) {
      setDeleteError(error instanceof Error ? error.message : 'delete_failed')
    } finally {
      setDeleting(false)
    }
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
    // The upload target was captured at pick time; refresh whatever folder
    // the user is viewing now.
    refreshInBackground()
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
      {loadError ? (
        <Note>
          Couldn't load the folder. <button className="underline" onClick={() => load(failedPath)}>Retry</button>
        </Note>
      ) : sorted === null ? (
        <Note>…</Note>
      ) : sorted.length === 0 ? (
        <Note>empty</Note>
      ) : (
        <div className="divide-y divide-line/60">
          {sorted.map((e) => (
            <div key={e.name} className="flex items-center gap-2.5 px-3 py-2.5 transition-colors hover:bg-fg/[0.05] active:bg-fg/[0.07]">
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
              <RowBtn
                onClick={() => {
                  setDeleteError('')
                  setDeleteTarget(join(path, e.name))
                }}
                title="Delete"
                danger
              >
                <Trash2 className="size-4" />
              </RowBtn>
            </div>
          ))}
        </div>
      )}
      {deleteTarget && (
        <DeleteDialog
          path={deleteTarget}
          busy={deleting}
          error={deleteError}
          onCancel={() => !deleting && setDeleteTarget(null)}
          onConfirm={del}
        />
      )}
    </Sheet>
  )
}

function DeleteDialog({
  path,
  busy,
  error,
  onCancel,
  onConfirm,
}: {
  path: string
  busy: boolean
  error: string
  onCancel: () => void
  onConfirm: () => void
}) {
  return (
    <DialogOverlay onClose={onCancel} guardClose={() => !busy} className="fixed inset-0 z-[70] flex items-center justify-center p-5" aria-label="Delete confirmation">
      <button tabIndex={-1} className="absolute inset-0 cursor-default bg-black/60 backdrop-blur-sm" aria-label="Cancel" onClick={onCancel} />
      <div className="relative z-10 w-full max-w-md rounded-lg bg-elevated p-4 text-fg shadow-2xl ring-1 ring-line-2">
        <div className="mb-2 flex items-center gap-2">
          <Trash2 className="size-4 shrink-0 text-danger" />
          <h2 className="text-[14px] font-semibold">Delete this item?</h2>
        </div>
        <p className="text-[12px] leading-relaxed text-muted">This permanently removes the selected item from the device.</p>
        <code className="my-3 block max-h-28 overflow-auto break-all rounded bg-black/20 p-2 font-mono text-[11px] leading-relaxed text-fg-dim">
          {path}
        </code>
        {error && <p className="mb-3 font-mono text-[11px] text-danger">{error}</p>}
        <div className="flex justify-end gap-2">
          <button
            onClick={onCancel}
            disabled={busy}
            className="rounded-lg bg-fg/8 px-3 py-1.5 text-[12px] font-medium text-fg-dim transition-colors hover:bg-fg/12 disabled:opacity-50"
          >
            Cancel
          </button>
          <button
            onClick={onConfirm}
            disabled={busy}
            className="rounded-lg bg-danger px-3 py-1.5 text-[12px] font-semibold text-white transition-colors hover:bg-danger/85 disabled:opacity-60"
          >
            {busy ? 'Deleting…' : 'Delete'}
          </button>
        </div>
      </div>
    </DialogOverlay>
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
              i === crumbs.length - 1 ? 'font-semibold text-fg hover:bg-fg/5' : 'text-muted hover:bg-fg/8 hover:text-fg active:bg-fg/10',
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
      className="grid size-8 shrink-0 place-items-center rounded-lg bg-fg/8 text-fg-dim transition-colors hover:bg-fg/12 hover:text-fg active:bg-fg/15"
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
        danger ? 'text-danger hover:bg-danger/10 active:bg-danger/15' : 'text-muted hover:bg-fg/10 hover:text-fg active:bg-fg/15',
      )}
    >
      {children}
    </button>
  )
}
