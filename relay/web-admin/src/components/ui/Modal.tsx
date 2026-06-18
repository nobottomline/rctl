import type { ReactNode } from 'react'
import * as Dialog from '@radix-ui/react-dialog'
import { AnimatePresence, motion } from 'framer-motion'
import { X } from 'lucide-react'
import { cn } from '../../lib/cn'

export type ModalProps = {
  open: boolean
  onOpenChange: (open: boolean) => void
  title?: string
  description?: string
  children?: ReactNode
  className?: string
}

// A nested Radix popper (a dropdown menu, select, etc.) portals its content
// outside the dialog's DOM subtree, so clicking it reads as an "outside"
// interaction that would otherwise dismiss the dialog. Keep the dialog open
// when the interaction lands inside any popper.
function isInsidePopper(target: EventTarget | null): boolean {
  return (
    target instanceof Element &&
    target.closest('[data-radix-popper-content-wrapper]') !== null
  )
}

export function Modal({
  open,
  onOpenChange,
  title,
  description,
  children,
  className,
}: ModalProps) {
  return (
    <Dialog.Root open={open} onOpenChange={onOpenChange}>
      <AnimatePresence>
        {open && (
          <Dialog.Portal forceMount>
            <Dialog.Overlay asChild forceMount>
              <motion.div
                initial={{ opacity: 0 }}
                animate={{ opacity: 1 }}
                exit={{ opacity: 0 }}
                transition={{ duration: 0.2 }}
                className="fixed inset-0 z-50 bg-black/65 backdrop-blur-sm"
              />
            </Dialog.Overlay>
            <div className="fixed inset-0 z-50 grid place-items-center p-4">
              <Dialog.Content
                asChild
                forceMount
                onOpenAutoFocus={(e) => e.preventDefault()}
                onInteractOutside={(e) => {
                  if (isInsidePopper(e.detail.originalEvent.target)) e.preventDefault()
                }}
              >
                <motion.div
                  initial={{ opacity: 0, scale: 0.94, y: 12 }}
                  animate={{ opacity: 1, scale: 1, y: 0 }}
                  exit={{ opacity: 0, scale: 0.96, y: 8 }}
                  transition={{ duration: 0.24, ease: [0.16, 1, 0.3, 1] }}
                  className={cn(
                    'glass relative w-full max-w-md overflow-hidden rounded-2xl ring-1 ring-line-2 shadow-2xl shadow-black/60',
                    className,
                  )}
                >
                  <div className="pointer-events-none absolute inset-x-0 top-0 h-px bg-gradient-to-r from-transparent via-signal/50 to-transparent" />
                  <div className="p-6">
                    {title && (
                      <Dialog.Title className="text-lg font-semibold tracking-tight text-fg">
                        {title}
                      </Dialog.Title>
                    )}
                    {description && (
                      <Dialog.Description className="mt-1.5 text-sm leading-relaxed text-muted">
                        {description}
                      </Dialog.Description>
                    )}
                    <div className={cn(title && 'mt-5')}>{children}</div>
                  </div>
                  <Dialog.Close className="absolute right-4 top-4 grid size-8 place-items-center rounded-lg text-muted transition-colors hover:bg-surface-2 hover:text-fg">
                    <X className="size-4" />
                  </Dialog.Close>
                </motion.div>
              </Dialog.Content>
            </div>
          </Dialog.Portal>
        )}
      </AnimatePresence>
    </Dialog.Root>
  )
}
