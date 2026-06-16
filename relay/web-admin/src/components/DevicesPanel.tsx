import type { ComponentType } from 'react'
import * as ContextMenu from '@radix-ui/react-context-menu'
import { AnimatePresence, motion } from 'framer-motion'
import {
  Ban,
  Check,
  Copy,
  ExternalLink,
  MonitorSmartphone,
  MoreHorizontal,
  Trash2,
  type LucideProps,
} from 'lucide-react'
import { toast } from 'sonner'
import { Button } from './ui/Button'
import { Menu, MenuItem, MenuLabel, MenuSeparator } from './ui/Menu'
import { OnlineDot, StatusBadge } from './ui/Status'
import { Panel } from './Shell'
import { controlURL } from '../lib/api'
import { fmtRel, shortId } from '../lib/format'
import type { Device } from '../types'

export type ActionKey = 'open' | 'approve' | 'revoke' | 'copy' | 'delete'

interface Action {
  key: ActionKey
  label: string
  icon: ComponentType<LucideProps>
  danger?: boolean
  accent?: boolean
}

function actionsFor(device: Device): Action[] {
  const list: Action[] = []
  if (device.status !== 'revoked' && device.online)
    list.push({ key: 'open', label: 'Open control', icon: ExternalLink, accent: true })
  if (device.status === 'pending')
    list.push({ key: 'approve', label: 'Approve device', icon: Check })
  if (device.status === 'approved')
    list.push({ key: 'revoke', label: 'Revoke access', icon: Ban })
  list.push({ key: 'copy', label: 'Copy device ID', icon: Copy })
  list.push({ key: 'delete', label: 'Delete device', icon: Trash2, danger: true })
  return list
}

export type DevicesPanelProps = {
  devices: Device[]
  loading: boolean
  busyId: string
  onAction: (key: ActionKey, device: Device) => void
}

export function DevicesPanel({ devices, loading, busyId, onAction }: DevicesPanelProps) {
  const online = devices.filter((d) => d.online).length

  function run(key: ActionKey, device: Device) {
    if (key === 'open') {
      window.open(controlURL(device.id), '_blank', 'noopener')
      return
    }
    if (key === 'copy') {
      navigator.clipboard?.writeText(device.id).then(
        () => toast.success('Device ID copied'),
        () => toast.error('Copy failed'),
      )
      return
    }
    onAction(key, device)
  }

  return (
    <Panel title="Devices" subtitle={`${devices.length} total · ${online} online`} className="self-start">
      {loading && devices.length === 0 ? (
        <Skeleton />
      ) : devices.length === 0 ? (
        <Empty />
      ) : (
        <ul className="divide-y divide-line/70">
          <AnimatePresence initial={false}>
            {devices.map((d, i) => (
              <motion.li
                key={d.id}
                layout
                initial={{ opacity: 0, y: 6 }}
                animate={{ opacity: 1, y: 0 }}
                exit={{ opacity: 0, height: 0 }}
                transition={{ duration: 0.25, delay: Math.min(i * 0.025, 0.2) }}
              >
                <DeviceRow device={d} busy={busyId === d.id} run={run} />
              </motion.li>
            ))}
          </AnimatePresence>
        </ul>
      )}
    </Panel>
  )
}

function DeviceRow({
  device,
  busy,
  run,
}: {
  device: Device
  busy: boolean
  run: (key: ActionKey, device: Device) => void
}) {
  const acts = actionsFor(device)
  return (
    <ContextMenu.Root>
      <ContextMenu.Trigger asChild>
        <div className="group flex flex-wrap items-center gap-x-4 gap-y-3 px-5 py-3.5 transition-colors hover:bg-surface-2/50">
          <div className="grid size-9 shrink-0 place-items-center rounded-lg bg-surface-2 text-muted ring-1 ring-line transition-colors group-hover:text-fg-dim">
            <MonitorSmartphone className="size-[18px]" />
          </div>

          <div className="min-w-0 flex-1">
            <div className="truncate text-[14.5px] font-medium text-fg">{device.name}</div>
            <button
              onClick={() => run('copy', device)}
              title={device.id}
              className="mt-0.5 inline-flex items-center gap-1.5 font-mono text-[11.5px] text-muted transition-colors hover:text-fg-dim"
            >
              {shortId(device.id)}
              <Copy className="size-3 opacity-0 transition-opacity group-hover:opacity-60" />
            </button>
          </div>

          <div className="hidden sm:block">
            <OnlineDot online={device.online} />
          </div>
          <StatusBadge status={device.status} />
          <div className="hidden text-right md:block">
            <div className="text-[12.5px] text-fg-dim tnum">{fmtRel(device.updated_at)}</div>
            <div className="text-[11px] text-faint">updated</div>
          </div>

          <Menu
            trigger={
              <Button variant="ghost" size="icon" loading={busy} aria-label="Device actions">
                {!busy && <MoreHorizontal className="size-[18px]" />}
              </Button>
            }
          >
            <MenuLabel>{device.name}</MenuLabel>
            {acts.map((a, idx) => (
              <div key={a.key}>
                {a.danger && idx > 0 && <MenuSeparator />}
                <MenuItem
                  icon={a.icon}
                  danger={a.danger}
                  className={a.accent ? 'text-signal data-[highlighted]:text-signal-hi' : ''}
                  onSelect={() => run(a.key, device)}
                >
                  {a.label}
                </MenuItem>
              </div>
            ))}
          </Menu>
        </div>
      </ContextMenu.Trigger>

      <ContextMenu.Portal>
        <ContextMenu.Content className="menu-pop glass z-50 min-w-[13rem] overflow-hidden rounded-xl p-1.5 ring-1 ring-line-2 shadow-2xl shadow-black/50">
          <ContextMenu.Label className="px-2.5 pb-1 pt-1.5 text-[11px] font-medium uppercase tracking-wider text-faint">
            {shortId(device.id, 10, 6)}
          </ContextMenu.Label>
          {acts.map((a, idx) => (
            <div key={a.key}>
              {a.danger && idx > 0 && (
                <ContextMenu.Separator className="my-1 h-px bg-line" />
              )}
              <ContextMenu.Item
                onSelect={() => run(a.key, device)}
                className={
                  'flex cursor-pointer items-center gap-2.5 rounded-lg px-2.5 py-2 text-[13.5px] outline-none transition-colors data-[highlighted]:bg-surface-2 ' +
                  (a.danger
                    ? 'text-danger data-[highlighted]:bg-danger/12'
                    : a.accent
                      ? 'text-signal'
                      : 'text-fg-dim data-[highlighted]:text-fg')
                }
              >
                <a.icon className="size-4 opacity-80" />
                {a.label}
              </ContextMenu.Item>
            </div>
          ))}
        </ContextMenu.Content>
      </ContextMenu.Portal>
    </ContextMenu.Root>
  )
}

function Empty() {
  return (
    <div className="flex flex-col items-center justify-center px-6 py-16 text-center">
      <div className="grid size-12 place-items-center rounded-xl bg-surface-2 text-faint ring-1 ring-line">
        <MonitorSmartphone className="size-6" />
      </div>
      <p className="mt-4 text-[15px] font-medium text-fg-dim">No devices yet</p>
      <p className="mt-1 max-w-xs text-[13px] text-muted">
        Create an enrollment token, build a personalized package, and install it on a
        device to see it appear here.
      </p>
    </div>
  )
}

function Skeleton() {
  return (
    <div className="divide-y divide-line/70">
      {[0, 1, 2].map((i) => (
        <div key={i} className="flex items-center gap-4 px-5 py-4">
          <div className="size-9 shrink-0 animate-pulse rounded-lg bg-surface-2" />
          <div className="flex-1 space-y-2">
            <div className="h-3.5 w-40 animate-pulse rounded bg-surface-2" />
            <div className="h-2.5 w-24 animate-pulse rounded bg-surface-2/70" />
          </div>
          <div className="h-6 w-20 animate-pulse rounded-full bg-surface-2" />
        </div>
      ))}
    </div>
  )
}
