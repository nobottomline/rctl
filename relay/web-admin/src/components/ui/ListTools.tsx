import { forwardRef, useLayoutEffect, useRef, useState, type ReactNode, type RefObject } from 'react'
import { AnimatePresence, motion, useReducedMotion } from 'framer-motion'
import { useVirtualizer } from '@tanstack/react-virtual'
import { cn } from '../../lib/cn'

// Shared list furniture for the sidebar panels (Controllers / Enrollment /
// Sessions). The model mirrors the Activity feed: rows are virtualized (only the
// visible ones exist in the DOM, so a thousand controllers cost the same as ten),
// and motion lives on the container, not on rows. Switching a segment crossfades
// the two lists while the panel's height tweens to the new content, so nothing
// jumps; a row that disappears simply lets the list settle to its new height.

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

const HEIGHT_EASE = [0.16, 1, 0.3, 1] as const

// Animates its own height to whatever its content measures. The content is
// observed, not guessed, so virtualized lists, empty states and footnotes all
// settle smoothly. The first paint is not animated.
export function AnimatedHeight({ children, className }: { children: ReactNode; className?: string }) {
  const inner = useRef<HTMLDivElement>(null)
  const [height, setHeight] = useState<number | 'auto'>('auto')
  const reduceMotion = useReducedMotion()

  useLayoutEffect(() => {
    const el = inner.current
    if (!el) return
    const measure = () => setHeight(el.getBoundingClientRect().height)
    measure()
    const observer = new ResizeObserver(measure)
    observer.observe(el)
    return () => observer.disconnect()
  }, [])

  return (
    <motion.div
      initial={false}
      animate={{ height }}
      transition={reduceMotion ? { duration: 0 } : { duration: 0.32, ease: HEIGHT_EASE }}
      className={cn('overflow-hidden', className)}
    >
      <div ref={inner}>{children}</div>
    </motion.div>
  )
}

// A bounded scroll region: long lists scroll within themselves past a few
// screens of rows, so the page keeps a single scrollbar. `relative` lets a
// crossfading previous view sit on top of the incoming one.
export const BoundedList = forwardRef<HTMLDivElement, { children: ReactNode; className?: string }>(
  function BoundedList({ children, className }, ref) {
    return (
      <div ref={ref} className={cn('relative max-h-[26rem] overflow-y-auto overscroll-contain', className)}>
        {children}
      </div>
    )
  },
)

// Crossfades between views keyed by `viewKey`. The outgoing view is popped out
// of the layout immediately (absolute), so the incoming one and the panel height
// move at once instead of waiting for an exit animation.
export function ViewSwitch({ viewKey, children }: { viewKey: string; children: ReactNode }) {
  const reduceMotion = useReducedMotion()
  return (
    <AnimatePresence mode="popLayout" initial={false}>
      <motion.div
        key={viewKey}
        initial={{ opacity: 0 }}
        animate={{ opacity: 1 }}
        exit={{ opacity: 0 }}
        transition={{ duration: reduceMotion ? 0 : 0.18, ease: 'easeOut' }}
        className="w-full"
      >
        {children}
      </motion.div>
    </AnimatePresence>
  )
}

// Windowed list: renders only the rows that intersect the scroll region. Row
// heights are measured, so rows may differ in height. Rows must be plain
// elements (no per-row exit animation): with windowing, "gone" simply means the
// list is shorter, and AnimatedHeight makes that smooth.
export function VirtualList<T>({
  items,
  scrollRef,
  getKey,
  estimateSize = 60,
  renderRow,
}: {
  items: T[]
  scrollRef: RefObject<HTMLDivElement | null>
  getKey: (item: T) => string
  estimateSize?: number
  renderRow: (item: T, index: number) => ReactNode
}) {
  const virt = useVirtualizer({
    count: items.length,
    getScrollElement: () => scrollRef.current,
    estimateSize: () => estimateSize,
    overscan: 8,
    getItemKey: (index) => getKey(items[index]),
  })
  return (
    <ul role="list" className="relative w-full" style={{ height: `${virt.getTotalSize()}px` }}>
      {virt.getVirtualItems().map((row) => (
        <li
          key={row.key}
          ref={virt.measureElement}
          data-index={row.index}
          className="absolute left-0 top-0 w-full border-b border-line/60"
          style={{ transform: `translateY(${row.start}px)` }}
        >
          {renderRow(items[row.index], row.index)}
        </li>
      ))}
    </ul>
  )
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
