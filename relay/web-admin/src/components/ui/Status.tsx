import type { DeviceStatus } from '../../types'
import { cn } from '../../lib/cn'

export function OnlineDot({ online }: { online: boolean }) {
  return (
    <span className="inline-flex items-center gap-2">
      <span className="relative flex size-2.5">
        {online && (
          <span className="absolute inline-flex size-full animate-ping rounded-full bg-online/60" />
        )}
        <span
          className={cn(
            'relative inline-flex size-2.5 rounded-full',
            online ? 'bg-online shadow-[0_0_8px_1px_rgba(70,211,154,0.55)]' : 'bg-faint',
          )}
        />
      </span>
      <span className={cn('text-[13px]', online ? 'text-online' : 'text-muted')}>
        {online ? 'online' : 'offline'}
      </span>
    </span>
  )
}

const statusStyle: Record<DeviceStatus, string> = {
  approved: 'text-online ring-online/25 bg-online/8',
  pending: 'text-signal ring-signal/30 bg-signal/10',
  revoked: 'text-danger ring-danger/25 bg-danger/8',
}

export function StatusBadge({ status }: { status: DeviceStatus }) {
  return (
    <span
      className={cn(
        'inline-flex items-center gap-1.5 rounded-full px-2.5 py-1 text-[11px] font-medium uppercase tracking-wide ring-1',
        statusStyle[status] || 'text-muted ring-line bg-surface-2',
      )}
    >
      <span className="size-1.5 rounded-full bg-current" />
      {status}
    </span>
  )
}
