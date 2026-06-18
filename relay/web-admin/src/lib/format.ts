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
  // slice(-0) returns the whole string, so guard the tail explicitly.
  const end = tail > 0 ? id.slice(-tail) : ''
  return `${id.slice(0, head)}…${end}`
}

// Best-effort "Browser · OS" label from a User-Agent string.
export function describeUserAgent(ua?: string): string {
  if (!ua) return 'Unknown client'
  const browser = /Edg\//.test(ua)
    ? 'Edge'
    : /OPR\/|Opera/.test(ua)
      ? 'Opera'
      : /Firefox\//.test(ua)
        ? 'Firefox'
        : /Chrome\//.test(ua)
          ? 'Chrome'
          : /Safari\//.test(ua)
            ? 'Safari'
            : /curl\//.test(ua)
              ? 'curl'
              : ''
  const os = /iPhone/.test(ua)
    ? 'iPhone'
    : /iPad/.test(ua)
      ? 'iPad'
      : /Android/.test(ua)
        ? 'Android'
        : /Mac OS X|Macintosh/.test(ua)
          ? 'macOS'
          : /Windows/.test(ua)
            ? 'Windows'
            : /Linux/.test(ua)
              ? 'Linux'
              : ''
  if (browser && os) return `${browser} · ${os}`
  if (browser) return browser
  if (os) return os
  return ua.length > 28 ? ua.slice(0, 28) + '…' : ua
}

export function fmtUptime(sec?: number): string {
  if (!sec || sec < 0) return '—'
  const d = Math.floor(sec / 86400)
  const h = Math.floor((sec % 86400) / 3600)
  const m = Math.floor((sec % 3600) / 60)
  if (d > 0) return `${d}d ${h}h`
  if (h > 0) return `${h}h ${m}m`
  if (m > 0) return `${m}m`
  return `${Math.floor(sec)}s`
}

export function fmtBytes(n?: number): string {
  if (!n) return '—'
  const u = ['B', 'KB', 'MB', 'GB']
  let v = n
  let i = 0
  while (v >= 1024 && i < u.length - 1) {
    v /= 1024
    i++
  }
  return `${v.toFixed(v >= 100 || i === 0 ? 0 : 1)} ${u[i]}`
}

// expires_at comes back as an RFC3339 string from the relay.
export function rfc3339ToSec(value?: string): number {
  if (!value) return 0
  const ms = Date.parse(value)
  return Number.isNaN(ms) ? 0 : Math.floor(ms / 1000)
}
