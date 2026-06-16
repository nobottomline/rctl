import type { ReactNode } from 'react'
import { motion } from 'framer-motion'
import { LogOut, RadioTower, RefreshCw } from 'lucide-react'
import { Button } from './ui/Button'
import { ThemeToggle } from './ThemeToggle'
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
    <div className="min-h-svh pb-12">
      {/* floating pill navbar */}
      <div className="sticky top-3.5 z-30 mx-auto w-full max-w-[78rem] px-4 sm:px-6 lg:px-8">
        <header className="flex items-center justify-between gap-3 rounded-full border border-line/70 bg-surface/65 py-2 pl-4 pr-2 shadow-[0_14px_38px_-16px_rgba(0,0,0,0.5)] backdrop-blur-xl">
          <div className="flex items-center gap-2.5">
            <div className="grid size-8 place-items-center rounded-full bg-signal/12 ring-1 ring-signal/25">
              <RadioTower className="size-4 text-signal" />
            </div>
            <div className="font-mono text-[13.5px] font-medium tracking-tight text-fg">
              rctl<span className="text-signal">·</span>relay
            </div>
          </div>

          <div className="flex items-center gap-1">
            <ThemeToggle />
            <span className="mx-1 h-5 w-px bg-line" />
            <Button variant="ghost" size="sm" onClick={onRefresh} disabled={refreshing}>
              <RefreshCw className={cn('size-4', refreshing && 'animate-spin')} />
              <span className="hidden sm:inline">Refresh</span>
            </Button>
            <Button variant="ghost" size="sm" onClick={onSignOut}>
              <LogOut className="size-4" />
              <span className="hidden sm:inline">Sign out</span>
            </Button>
          </div>
        </header>
      </div>

      <motion.main
        initial={{ opacity: 0, y: 8 }}
        animate={{ opacity: 1, y: 0 }}
        transition={{ duration: 0.35, ease: [0.16, 1, 0.3, 1] }}
        className="mx-auto grid w-full max-w-[78rem] grid-cols-1 gap-5 px-4 py-6 sm:px-6 lg:grid-cols-[minmax(0,1fr)_22rem] lg:px-8"
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
