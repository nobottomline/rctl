import { X } from 'lucide-react'
import type { ReactNode } from 'react'
import { cn } from '../lib/cn'

// Responsive overlay surface: a centered floating card on desktop, a full-height
// bottom sheet on mobile. Themed chrome (bg-elevated / text-fg) so it follows the
// light/dark toggle. Shared by Files (and Console) so the secondary panels are
// consistent rather than ad-hoc fullscreen screens.
export function Sheet({
  title,
  onClose,
  toolbar,
  children,
}: {
  title: ReactNode
  onClose: () => void
  toolbar?: ReactNode
  children: ReactNode
}) {
  return (
    <div className="fixed inset-0 z-40 flex flex-col sm:items-center sm:justify-center sm:p-4">
      <button
        aria-label="Close"
        onClick={onClose}
        className="absolute inset-0 cursor-default bg-black/50 backdrop-blur-sm"
      />
      <div
        className={cn(
          'relative z-10 mt-auto flex h-[88dvh] w-full flex-col overflow-hidden rounded-t-2xl',
          'bg-elevated text-fg shadow-2xl shadow-black/40 ring-1 ring-line-2',
          'sm:mt-0 sm:h-auto sm:max-h-[min(82dvh,660px)] sm:w-[28rem] sm:rounded-2xl',
        )}
      >
        <header className="flex h-12 shrink-0 items-center gap-2 border-b border-line px-3.5">
          <div className="mr-auto text-[13px] font-semibold">{title}</div>
          <button
            onClick={onClose}
            aria-label="Close"
            className="grid size-8 place-items-center rounded-lg bg-fg/8 text-fg-dim transition-colors active:bg-fg/15"
          >
            <X className="size-4" />
          </button>
        </header>
        {toolbar && <div className="shrink-0 border-b border-line px-3 py-2">{toolbar}</div>}
        <div
          className="min-h-0 flex-1 overflow-y-auto"
          style={{ paddingBottom: 'env(safe-area-inset-bottom)' }}
        >
          {children}
        </div>
      </div>
    </div>
  )
}
