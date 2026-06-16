// Relative + absolute time helpers. Relay timestamps are unix seconds.

export function fmtAbs(sec?: number): string {
  if (!sec) return '—'
  return new Date(sec * 1000).toLocaleString(undefined, {
    month: 'short',
    day: 'numeric',
    hour: '2-digit',
    minute: '2-digit',
  })
}

export function fmtRel(sec?: number): string {
  if (!sec) return '—'
  const diff = Date.now() / 1000 - sec
  if (diff < 45) return 'just now'
  const mins = Math.round(diff / 60)
  if (mins < 60) return `${mins}m ago`
  const hrs = Math.round(mins / 60)
  if (hrs < 24) return `${hrs}h ago`
  const days = Math.round(hrs / 24)
  if (days < 30) return `${days}d ago`
  return fmtAbs(sec)
}

export function shortId(id: string, head = 8, tail = 4): string {
  if (!id || id.length <= head + tail + 1) return id
  return `${id.slice(0, head)}…${id.slice(-tail)}`
}

// expires_at comes back as an RFC3339 string from the relay.
export function rfc3339ToSec(value?: string): number {
  if (!value) return 0
  const ms = Date.parse(value)
  return Number.isNaN(ms) ? 0 : Math.floor(ms / 1000)
}
