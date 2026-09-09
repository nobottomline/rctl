import * as DropdownMenu from '@radix-ui/react-dropdown-menu'
import { Check, ChevronDown } from 'lucide-react'

export function OptionMenu({ label, value, options, disabled, onChange }: {
  label: string
  value: string
  options: readonly (readonly [string, string])[]
  disabled?: boolean
  onChange: (value: string) => void
}) {
  return <DropdownMenu.Root modal={false}>
    <DropdownMenu.Trigger asChild>
      <button type="button" disabled={disabled} aria-label={label}
        className="flex h-9 w-full min-w-0 items-center justify-between gap-2 rounded-lg bg-fg/6 px-2.5 text-left text-[13px] text-fg ring-1 ring-line/70 transition-colors hover:bg-fg/10 disabled:opacity-50">
        <span className="truncate">{options.find(([key]) => key === value)?.[1]}</span>
        <ChevronDown className="size-3.5 shrink-0 text-muted" />
      </button>
    </DropdownMenu.Trigger>
    <DropdownMenu.Portal>
      <DropdownMenu.Content align="start" sideOffset={5} collisionPadding={12}
        className="z-[70] w-[var(--radix-dropdown-menu-trigger-width)] max-h-[var(--radix-dropdown-menu-content-available-height)] overflow-y-auto rounded-lg bg-elevated p-1 text-fg shadow-xl ring-1 ring-line-2">
        <DropdownMenu.RadioGroup value={value} onValueChange={onChange} aria-label={label}>
          {options.map(([key, text]) => <DropdownMenu.RadioItem key={key} value={key}
            className="flex min-h-9 cursor-pointer items-center justify-between gap-2 rounded-md px-2.5 py-2 text-[13px] font-medium outline-none transition-colors data-[highlighted]:bg-fg/8 data-[state=checked]:text-signal">
            <span>{text}</span>
            <span className="grid size-3.5 shrink-0 place-items-center"><DropdownMenu.ItemIndicator><Check className="size-3.5" /></DropdownMenu.ItemIndicator></span>
          </DropdownMenu.RadioItem>)}
        </DropdownMenu.RadioGroup>
      </DropdownMenu.Content>
    </DropdownMenu.Portal>
  </DropdownMenu.Root>
}
