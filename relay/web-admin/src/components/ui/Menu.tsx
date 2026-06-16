import type { ComponentType, ReactElement, ReactNode } from 'react'
import * as DropdownMenu from '@radix-ui/react-dropdown-menu'
import type { LucideProps } from 'lucide-react'
import { cn } from '../../lib/cn'

const contentCls =
  'menu-pop glass z-50 min-w-[12rem] overflow-hidden rounded-xl p-1.5 ring-1 ring-line-2 shadow-2xl shadow-black/50'

export function Menu({
  trigger,
  children,
  align = 'end',
}: {
  trigger: ReactElement
  children: ReactNode
  align?: DropdownMenu.DropdownMenuContentProps['align']
}) {
  return (
    <DropdownMenu.Root>
      <DropdownMenu.Trigger asChild>{trigger}</DropdownMenu.Trigger>
      <DropdownMenu.Portal>
        <DropdownMenu.Content align={align} sideOffset={6} className={contentCls}>
          {children}
        </DropdownMenu.Content>
      </DropdownMenu.Portal>
    </DropdownMenu.Root>
  )
}

export type MenuItemProps = DropdownMenu.DropdownMenuItemProps & {
  icon?: ComponentType<LucideProps>
  danger?: boolean
}

export function MenuItem({
  icon: Icon,
  danger = false,
  children,
  className,
  ...props
}: MenuItemProps) {
  return (
    <DropdownMenu.Item
      className={cn(
        'group flex cursor-pointer items-center gap-2.5 rounded-lg px-2.5 py-2 text-[13.5px] outline-none transition-colors',
        'data-[highlighted]:bg-surface-2',
        danger
          ? 'text-danger data-[highlighted]:bg-danger/12'
          : 'text-fg-dim data-[highlighted]:text-fg',
        className,
      )}
      {...props}
    >
      {Icon && <Icon className="size-4 opacity-80" />}
      {children}
    </DropdownMenu.Item>
  )
}

export function MenuSeparator() {
  return <DropdownMenu.Separator className="my-1 h-px bg-line" />
}

export function MenuLabel({ children }: { children: ReactNode }) {
  return (
    <DropdownMenu.Label className="px-2.5 pb-1 pt-1.5 text-[11px] font-medium uppercase tracking-wider text-faint">
      {children}
    </DropdownMenu.Label>
  )
}
