import type { ReactNode } from 'react'
import { motion } from 'framer-motion'
import { LogOut, RadioTower, RefreshCw } from 'lucide-react'
import { Button } from './ui/Button'
import { cn } from '../lib/cn'

export function Shell({
  onRefresh,
  refreshing,
  onSignOut,
  children,
}: {
  onRefresh: () => void
  refreshing: boolean
  onSignOut: () => void
  children: ReactNode
}) {
  return (
    <div className="mx-auto min-h-svh w-full max-w-[78rem] px-4 sm:px-6 lg:px-8">
      <header className="sticky top-0 z-30 -mx-4 mb-2 flex items-center justify-between gap-3 border-b border-line/70 bg-bg/70 px-4 py-3.5 backdrop-blur-xl sm:-mx-6 sm:px-6 lg:-mx-8 lg:px-8">
        <div className="flex items-center gap-3">
          <div className="grid size-9 place-items-center rounded-[10px] bg-signal/12 ring-1 ring-signal/25">
            <RadioTower className="size-[18px] text-signal" />
          </div>
          <div className="leading-tight">
            <div className="font-mono text-[14px] font-medium tracking-tight text-fg">
              rctl<span className="text-signal">·</span>relay
            </div>
            <div className="hidden text-[11px] text-muted sm:block">operator console</div>
          </div>
        </div>

        <div className="flex items-center gap-2">
          <Button variant="secondary" size="sm" onClick={onRefresh} disabled={refreshing}>
            <RefreshCw className={cn('size-4', refreshing && 'animate-spin')} />
            <span className="hidden sm:inline">Refresh</span>
          </Button>
          <Button variant="ghost" size="sm" onClick={onSignOut}>
            <LogOut className="size-4" />
            <span className="hidden sm:inline">Sign out</span>
          </Button>
        </div>
      </header>

      <motion.main
        initial={{ opacity: 0, y: 8 }}
        animate={{ opacity: 1, y: 0 }}
        transition={{ duration: 0.35, ease: [0.16, 1, 0.3, 1] }}
        className="grid grid-cols-1 gap-5 py-5 lg:grid-cols-[minmax(0,1fr)_22rem]"
      >
        {children}
      </motion.main>
    </div>
  )
}

export function Panel({
  title,
  subtitle,
  action,
  children,
  className,
}: {
  title?: string
  subtitle?: string
  action?: ReactNode
  children: ReactNode
  className?: string
}) {
  return (
    <section
      className={cn(
        'overflow-hidden rounded-2xl bg-surface/70 ring-1 ring-line backdrop-blur-sm',
        className,
      )}
    >
      {(title || action) && (
        <div className="flex items-center justify-between gap-3 border-b border-line/80 px-5 py-4">
          <div>
            <h2 className="text-[15px] font-semibold tracking-tight text-fg">{title}</h2>
            {subtitle && <p className="mt-0.5 text-[12.5px] text-muted">{subtitle}</p>}
          </div>
          {action}
        </div>
      )}
      {children}
    </section>
  )
}
