import { useId } from 'react'
import * as Select from '@radix-ui/react-select'
import { Check, ChevronDown, ChevronUp } from 'lucide-react'

export function SelectField({ label, value, onValueChange, options, disabled, placeholder = 'Select…' }: {
  label: string
  value: string
  onValueChange: (value: string) => void
  options: { value: string; label: string }[]
  disabled?: boolean
  placeholder?: string
}) {
  const id = useId()
  return <div>
    <label htmlFor={id} className="mb-2 block text-[13px] font-medium text-fg-dim">{label}</label>
    <Select.Root value={value} onValueChange={onValueChange} disabled={disabled}>
      <Select.Trigger id={id} className="flex h-11 w-full items-center justify-between gap-3 rounded-xl border border-line bg-bg/55 px-3.5 text-left text-[15px] text-fg outline-none transition-colors hover:border-line-2 focus-visible:border-signal focus-visible:ring-[3px] focus-visible:ring-signal/20 disabled:opacity-55 [&>span:first-child]:truncate">
        <Select.Value placeholder={placeholder} />
        <Select.Icon asChild><ChevronDown className="size-4 shrink-0 text-muted" /></Select.Icon>
      </Select.Trigger>
      <Select.Portal>
        <Select.Content position="popper" sideOffset={6} collisionPadding={16} className="menu-pop glass z-50 max-h-[var(--radix-select-content-available-height)] min-w-[var(--radix-select-trigger-width)] overflow-hidden rounded-xl p-1.5 text-fg ring-1 ring-line-2 shadow-2xl shadow-black/40">
          <Select.ScrollUpButton className="flex h-6 items-center justify-center"><ChevronUp className="size-4" /></Select.ScrollUpButton>
          <Select.Viewport>
            {options.map((option) => <Select.Item key={option.value} value={option.value} className="relative flex min-h-10 cursor-pointer items-center rounded-lg py-2 pl-3 pr-9 text-sm outline-none data-[highlighted]:bg-surface-2 data-[state=checked]:text-signal">
              <Select.ItemText>{option.label}</Select.ItemText>
              <Select.ItemIndicator className="absolute right-3"><Check className="size-4" /></Select.ItemIndicator>
            </Select.Item>)}
          </Select.Viewport>
          <Select.ScrollDownButton className="flex h-6 items-center justify-center"><ChevronDown className="size-4" /></Select.ScrollDownButton>
        </Select.Content>
      </Select.Portal>
    </Select.Root>
  </div>
}
