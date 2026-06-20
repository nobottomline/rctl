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

// Browser brand from Sec-CH-UA client hints. Brave/Edge/Opera all ship Chrome's
// User-Agent string, so the UA alone can't tell them apart -- but their client
// hints carry the real brand. Empty for non-Chromium browsers (Firefox/Safari).
function brandFromHints(hints?: string): string {
  if (!hints) return ''
  const brands = [...hints.matchAll(/"([^"]+)"/g)].map((m) => m[1])
  if (brands.some((b) => /Brave/i.test(b))) return 'Brave'
  if (brands.some((b) => /Edge/i.test(b))) return 'Edge'
  if (brands.some((b) => /OPR|Opera/i.test(b))) return 'Opera'
  if (brands.some((b) => /Google Chrome/i.test(b))) return 'Chrome'
  return ''
}

// "Browser · OS", preferring the client-hint brand so e.g. Brave isn't mislabeled
// as Chrome. Falls back to the User-Agent for the browser and always for the OS.
export function describeClient(ua?: string, hints?: string): string {
  const brand = brandFromHints(hints)
  if (!brand) return describeUserAgent(ua)
  const full = describeUserAgent(ua)
  const os = full.includes(' · ') ? full.split(' · ')[1] : ''
  return os ? `${brand} · ${os}` : brand
}

// "in 29d" / "in 5h" — for a future timestamp (e.g. when a session auto-expires).
export function fmtUntil(sec?: number): string {
  if (!sec) return '—'
  const diff = sec - Date.now() / 1000
  if (diff <= 0) return 'expired'
  const mins = Math.round(diff / 60)
  if (mins < 60) return `in ${mins}m`
  const hrs = Math.round(mins / 60)
  if (hrs < 48) return `in ${hrs}h`
  return `in ${Math.round(hrs / 24)}d`
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
