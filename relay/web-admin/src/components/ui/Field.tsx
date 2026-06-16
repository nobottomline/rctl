import { forwardRef, type ComponentType, type InputHTMLAttributes } from 'react'
import type { LucideProps } from 'lucide-react'
import { cn } from '../../lib/cn'

export type FieldProps = InputHTMLAttributes<HTMLInputElement> & {
  label?: string
  hint?: string
  icon?: ComponentType<LucideProps>
}

export const Field = forwardRef<HTMLInputElement, FieldProps>(function Field(
  { label, hint, className, icon: Icon, ...props },
  ref,
) {
  return (
    <label className="block">
      {label && (
        <span className="mb-2 block text-[13px] font-medium text-fg-dim">{label}</span>
      )}
      <div className="relative">
        {Icon && (
          <Icon className="pointer-events-none absolute left-3.5 top-1/2 size-4 -translate-y-1/2 text-muted" />
        )}
        <input
          ref={ref}
          className={cn(
            'h-11 w-full rounded-xl border border-line bg-bg/55 px-3.5 text-[15px] text-fg outline-none transition-[border-color,box-shadow,background-color] duration-200 placeholder:text-faint',
            'hover:border-line-2',
            'focus:border-signal/55 focus:bg-bg/80 focus:outline-none focus-visible:outline-none',
            'focus:shadow-[0_0_0_3px_color-mix(in_oklab,var(--color-signal)_15%,transparent),0_2px_14px_-4px_color-mix(in_oklab,var(--color-signal)_35%,transparent)]',
            Icon && 'pl-10',
            className,
          )}
          {...props}
        />
      </div>
      {hint && <span className="mt-1.5 block text-xs text-muted">{hint}</span>}
    </label>
  )
})
