import { X } from 'lucide-react'
import { useEffect, useRef, type ReactNode } from 'react'
import { cn } from '../lib/cn'

// Shared dialog plumbing: topmost-dialog Escape rule, a Tab focus trap
// (including <summary> elements and native video controls), focus moved in on
// open, and focus restored on close to the opener — or, when the opener is
// already gone (owner launch buttons unmount with the control center, menu
// items unmount with their overlay), to the nearest still-visible dialog's
// title, falling back to the owner's controls toggle.
function restoreFocusTo(opener: HTMLElement | null) {
  if (opener && opener !== document.body && opener.isConnected) {
    opener.focus()
    return
  }
  // Effect cleanups flush after the DOM removal, so the dialog that just
  // closed is already detached: the last remaining visible dialog is the
  // sheet it was stacked on (or a sibling overlay above one).
  const dialogs = [...document.querySelectorAll<HTMLElement>('[role="dialog"]:not([hidden])')]
  for (const dialog of [...dialogs].reverse()) {
    const title = dialog.querySelector<HTMLElement>('[data-sheet-title]')
    if (title) {
      title.focus()
      return
    }
    dialog.focus()
    if (document.activeElement !== document.body) return
  }
  document.querySelector<HTMLElement>('button[aria-label="controls"]')?.focus()
}

// Tab-cycle members: real interactive elements only. Full-screen backdrops
// and programmatic focus targets (title) carry tabIndex=-1 and are excluded
// from the cycle; the focus-in step selects them explicitly instead.
const FOCUSABLE = 'button:not(:disabled), a[href], input:not(:disabled), select:not(:disabled), textarea:not(:disabled), video[controls], summary, [tabindex="0"]'

// querySelectorAll matches CSS selectors, not the tabindex DOM property. The
// exclusion is the explicit tabindex="-1" ATTRIBUTE (backdrops, titles) — a
// WebKit <video controls> reports tabIndex -1 without any attribute and must
// stay in the cycle.
function focusCycle(surface: HTMLElement): HTMLElement[] {
  return [...surface.querySelectorAll<HTMLElement>(FOCUSABLE)]
    .filter((element) => element.getClientRects().length > 0 && element.getAttribute('tabindex') !== '-1')
}

function useDialogKeys(surface: React.RefObject<HTMLElement | null>, onClose: () => void, guardClose?: () => boolean) {
  // The listener is registered once; keep the callbacks current across renders
  // so guardClose sees the busy/deleting/removing state of the render that
  // actually matters, not the first one.
  const onCloseRef = useRef(onClose)
  onCloseRef.current = onClose
  const guardRef = useRef(guardClose)
  guardRef.current = guardClose
  useEffect(() => {
    const opener = document.activeElement as HTMLElement | null
    if (surface.current) {
      const focusables = focusCycle(surface.current)
      const heading = surface.current.querySelector<HTMLElement>('[data-sheet-title]')
      ;(heading ?? focusables[0] ?? surface.current).focus()
    }
    // Keyboard plumbing lives at document level (bubble phase): keys can
    // originate outside the dialog once focus falls to <body> after a control
    // unmounts (e.g. a Retry button that disappeared). Capture-phase
    // listeners — Radix menus consume Escape/Tab there — run first, and this
    // listener honors their preventDefault.
    const onKey = (event: KeyboardEvent) => {
      if (event.defaultPrevented) return // a child widget already consumed the key
      const dialogs = [...document.querySelectorAll<HTMLElement>('[role="dialog"]:not([hidden])')]
      if (dialogs[dialogs.length - 1] !== surface.current) return
      if (event.key === 'Escape') {
        // Nested overlays stack above their sheet: only the topmost visible
        // dialog reacts to Escape, so a confirm dialog closes by itself and
        // never its parent. The key is absorbed even when a destructive
        // request in flight refuses the close — no other layer may act on it.
        event.preventDefault()
        const guard = guardRef.current
        if (guard && !guard()) return
        onCloseRef.current()
        return
      }
      if (event.key !== 'Tab') return
      const elements = surface.current ? focusCycle(surface.current) : []
      if (!elements.length) {
        // Every control may be disabled while a destructive request runs: Tab
        // must not leave the modal, so the dialog container holds focus.
        event.preventDefault()
        surface.current?.focus()
        return
      }
      const first = elements[0]
      const last = elements[elements.length - 1]
      const active = document.activeElement as HTMLElement | null
      const inside = active !== null && elements.includes(active)
      if (event.shiftKey ? (active === first || !inside) : (active === last || !inside)) {
        event.preventDefault()
        ;(event.shiftKey ? last : first).focus()
      }
    }
    document.addEventListener('keydown', onKey)
    return () => {
      document.removeEventListener('keydown', onKey)
      restoreFocusTo(opener)
    }
    // The surface ref is stable for the lifetime of the overlay.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [])
}

// A modal overlay stacked on top of a Sheet (confirm dialogs, media viewer,
// camera view): full dialog semantics so Escape and keyboard navigation stay
// inside the overlay and never leak to the parent sheet.
export function DialogOverlay({
  onClose,
  className,
  'aria-label': ariaLabel,
  guardClose,
  children,
}: {
  onClose: () => void
  className?: string
  'aria-label'?: string
  /** Return false to refuse Escape dismissal (e.g. while a destructive request is in flight). */
  guardClose?: () => boolean
  children: ReactNode
}) {
  const surface = useRef<HTMLDivElement>(null)
  useDialogKeys(surface, onClose, guardClose)
  return (
    <div
      ref={surface}
      role="dialog"
      aria-modal="true"
      aria-label={ariaLabel}
      tabIndex={-1}
      className={cn('outline-none', className)}
    >
      {children}
    </div>
  )
}

// Responsive overlay surface: a centered floating card on desktop, a full-height
// bottom sheet on mobile. Themed chrome (bg-elevated / text-fg) so it follows the
// light/dark toggle. Shared by Files (and Console) so the secondary panels are
// consistent rather than ad-hoc fullscreen screens. Modal semantics follow the
// guest panels: role="dialog" + focus trap on Tab, Escape closes, and focus
// returns to the element that opened the sheet.
export function Sheet({
  title,
  onClose,
  toolbar,
  children,
  dim = true,
  wide = false,
}: {
  title: ReactNode
  onClose: () => void
  toolbar?: ReactNode
  children: ReactNode
  dim?: boolean // focused tasks dim the video; the control center keeps it visible
  wide?: boolean // content-dense panels (Console) get a wider desktop card
}) {
  const dialog = useRef<HTMLDivElement>(null)
  useDialogKeys(dialog, onClose)

  return (
    <div className="fixed inset-0 z-40 flex flex-col sm:items-center sm:justify-center sm:p-4">
      <button
        tabIndex={-1}
        aria-label="Close"
        onClick={onClose}
        className={cn('absolute inset-0 cursor-default', dim ? 'bg-black/50 backdrop-blur-sm' : 'bg-transparent')}
      />
      <div
        ref={dialog}
        role="dialog"
        aria-modal="true"
        aria-labelledby="sheet-title"
        tabIndex={-1}
        className={cn(
          'relative z-10 mt-auto flex h-[88dvh] w-full flex-col overflow-hidden rounded-t-2xl outline-none',
          'bg-elevated text-fg shadow-2xl shadow-black/40 ring-1 ring-line-2',
          'sm:mt-0 sm:h-auto sm:max-h-[min(85dvh,720px)] sm:rounded-2xl',
          wide ? 'sm:w-[46rem]' : 'sm:w-[28rem]',
        )}
      >
        <header className="flex h-12 shrink-0 items-center gap-2 border-b border-line px-3.5">
          <div id="sheet-title" data-sheet-title tabIndex={-1} className="mr-auto text-[13px] font-semibold outline-none">{title}</div>
          <button
            onClick={onClose}
            aria-label="Close"
            className="grid size-8 place-items-center rounded-lg bg-fg/8 text-fg-dim transition-colors hover:bg-fg/12 active:bg-fg/15"
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
