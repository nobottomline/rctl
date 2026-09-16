import type { ComponentProps } from 'react'
import * as CheckboxPrimitive from '@radix-ui/react-checkbox'
import { Check } from 'lucide-react'
import { cn } from '../../lib/cn'

export function Checkbox({ className, ...props }: ComponentProps<typeof CheckboxPrimitive.Root>) {
  return (
    <CheckboxPrimitive.Root
      data-slot="checkbox"
      className={cn(
        'peer size-4 shrink-0 rounded-[4px] border border-line-2 bg-surface shadow-xs outline-none transition-[background-color,border-color,box-shadow] duration-150',
        'hover:border-signal data-[state=checked]:border-signal data-[state=checked]:bg-signal data-[state=checked]:text-on-signal',
        'focus-visible:border-signal focus-visible:ring-[3px] focus-visible:ring-signal/30 aria-invalid:border-danger aria-invalid:ring-danger/20',
        'disabled:cursor-not-allowed disabled:opacity-50 disabled:hover:border-line-2',
        className,
      )}
      {...props}
    >
      <CheckboxPrimitive.Indicator data-slot="checkbox-indicator" className="flex items-center justify-center text-current">
        <Check className="size-3.5" aria-hidden="true" />
      </CheckboxPrimitive.Indicator>
    </CheckboxPrimitive.Root>
  )
}
