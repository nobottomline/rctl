import type { ComponentType, ReactNode } from 'react'
import type { LucideProps } from 'lucide-react'

// Shared building blocks for the device / session detail modals.

export function DetailSection({
  title,
  action,
  children,
}: {
  title: string
  action?: ReactNode
  children: ReactNode
}) {
  return (
    <div className="rounded-xl bg-surface-2/40 p-3.5 ring-1 ring-line/70">
      <div className="mb-2.5 flex items-center justify-between">
        <span className="text-[11px] font-medium uppercase tracking-wider text-faint">{title}</span>
        {action}
      </div>
      {children}
    </div>
  )
}

export function DetailField({
  icon: Icon,
  label,
  value,
}: {
  icon?: ComponentType<LucideProps>
  label: string
  value?: string
}) {
  return (
    <div className="min-w-0">
      <div className="flex items-center gap-1.5 text-[11px] text-muted">
        {Icon && <Icon className="size-3 opacity-70" />}
        {label}
      </div>
      <div className="mt-0.5 truncate text-[13.5px] text-fg" title={value || undefined}>
        {value || '—'}
      </div>
    </div>
  )
}
