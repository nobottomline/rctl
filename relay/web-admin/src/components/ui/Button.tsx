import type { ReactNode } from 'react'
import { motion, type HTMLMotionProps } from 'framer-motion'
import { Loader2 } from 'lucide-react'
import { cn } from '../../lib/cn'

type Variant = 'primary' | 'secondary' | 'ghost' | 'danger' | 'danger-solid'
type Size = 'sm' | 'md' | 'lg' | 'icon'

const variants: Record<Variant, string> = {
  primary:
    'bg-signal text-on-signal font-semibold hover:bg-signal-hi shadow-[0_1px_0_0_rgba(255,255,255,0.22)_inset,0_8px_24px_-8px_color-mix(in_oklab,var(--color-signal)_55%,transparent)]',
  secondary: 'bg-surface-2 text-fg ring-line hover:bg-elevated hover:ring-line-2',
  ghost: 'text-fg-dim hover:bg-surface-2 hover:text-fg',
  danger: 'bg-danger/12 text-danger ring-1 ring-danger/25 hover:bg-danger/20',
  'danger-solid': 'bg-danger text-on-danger font-semibold hover:brightness-110',
}

const sizes: Record<Size, string> = {
  sm: 'h-8 px-3 text-[13px] rounded-lg gap-1.5',
  md: 'h-10 px-4 text-sm rounded-[10px] gap-2',
  lg: 'h-11 px-5 text-[15px] rounded-xl gap-2',
  icon: 'h-9 w-9 rounded-lg',
}

export type ButtonProps = Omit<HTMLMotionProps<'button'>, 'children'> & {
  variant?: Variant
  size?: Size
  loading?: boolean
  children?: ReactNode
}

export function Button({
  variant = 'secondary',
  size = 'md',
  className,
  loading = false,
  disabled,
  children,
  ...props
}: ButtonProps) {
  return (
    <motion.button
      whileTap={{ scale: 0.97 }}
      transition={{ duration: 0.12 }}
      disabled={disabled || loading}
      className={cn(
        'relative inline-flex select-none items-center justify-center whitespace-nowrap font-medium ring-1 ring-transparent transition-[background,color,box-shadow] duration-150 outline-none disabled:pointer-events-none disabled:opacity-55',
        variants[variant],
        sizes[size],
        className,
      )}
      {...props}
    >
      {loading && <Loader2 className="size-4 animate-spin" />}
      {children}
    </motion.button>
  )
}
