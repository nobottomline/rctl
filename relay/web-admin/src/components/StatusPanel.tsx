import { Panel } from './Shell'
import { fmtUptime } from '../lib/format'
import type { RelayStatus } from '../types'

export function StatusPanel({ status }: { status: RelayStatus | null }) {
  if (!status) return null
  const stats: { label: string; value: string }[] = [
    { label: 'Devices online', value: `${status.devices_online} / ${status.devices_total}` },
    { label: 'Admin sessions', value: String(status.sessions) },
  ]
  return (
    <Panel title="Relay" subtitle={`up ${fmtUptime(status.uptime_seconds)}`}>
      <div className="grid grid-cols-2 gap-3 p-4">
        {stats.map((s) => (
          <div key={s.label} className="rounded-lg bg-surface-2/40 px-3.5 py-2.5 ring-1 ring-line/70">
            <div className="text-[11px] text-muted">{s.label}</div>
            <div className="mt-0.5 text-[16px] font-semibold tracking-tight text-fg tnum">
              {s.value}
            </div>
          </div>
        ))}
      </div>
    </Panel>
  )
}
