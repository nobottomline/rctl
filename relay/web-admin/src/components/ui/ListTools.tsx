import type { ReactNode } from 'react'
import { cn } from '../../lib/cn'

// Shared list furniture for the sidebar panels (Controllers / Enrollment /
// Sessions): a segmented state filter with counts, and a bounded scroll region
// so a long history never stretches the page.

export type SegmentOption<K extends string> = { key: K; label: string; count: number }

export function SegmentedFilter<K extends string>({
  value,
  options,
  onChange,
  trailing,
}: {
  value: K
  options: SegmentOption<K>[]
  onChange: (key: K) => void
  trailing?: ReactNode
}) {
  return (
    <div className="flex items-center justify-between gap-3 border-b border-line/60 px-5 py-2">
      <div role="tablist" className="flex items-center gap-1">
        {options.map((option) => {
          const active = option.key === value
          return (
            <button
              key={option.key}
              type="button"
              role="tab"
              aria-selected={active}
              onClick={() => onChange(option.key)}
              className={cn(
                'inline-flex h-7 items-center gap-1.5 rounded-lg px-2.5 text-[12px] font-medium transition-colors',
                active ? 'bg-surface-2 text-fg ring-1 ring-line-2' : 'text-muted hover:text-fg-dim',
              )}
            >
              {option.label}
              <span
                className={cn(
                  'rounded-full px-1.5 py-px text-[10px] tnum',
                  active ? 'bg-bg/70 text-fg-dim ring-1 ring-line/70' : 'bg-surface-2/60 text-faint',
                )}
              >
                {option.count}
              </span>
            </button>
          )
        })}
      </div>
      {trailing}
    </div>
  )
}

// A list that scrolls within itself past a few screens of rows. Panels stay a
// predictable height; the page keeps a single scrollbar.
export function BoundedList({ children, className }: { children: ReactNode; className?: string }) {
  return <div className={cn('max-h-[26rem] overflow-y-auto overscroll-contain', className)}>{children}</div>
}

export function ListEmpty({ icon, children }: { icon: ReactNode; children: ReactNode }) {
  return (
    <div className="px-5 py-10 text-center">
      <div className="mx-auto grid size-10 place-items-center rounded-xl bg-surface-2 text-faint ring-1 ring-line">
        {icon}
      </div>
      <p className="mt-3 text-[13px] text-muted">{children}</p>
    </div>
  )
}

export function ListFootnote({ children }: { children: ReactNode }) {
  return <p className="border-t border-line/60 px-5 py-2.5 text-[11.5px] leading-relaxed text-faint">{children}</p>
}
