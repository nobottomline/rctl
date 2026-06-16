import { useState } from 'react'
import { AnimatePresence, motion } from 'framer-motion'
import { Check, Copy, KeyRound, Plus, ShieldAlert } from 'lucide-react'
import { toast } from 'sonner'
import { Button } from './ui/Button'
import { Panel } from './Shell'
import { api } from '../lib/api'
import { fmtAbs, rfc3339ToSec } from '../lib/format'
import type { Enrollment } from '../types'

export function EnrollPanel() {
  const [result, setResult] = useState<Enrollment | null>(null)
  const [loading, setLoading] = useState(false)
  const [copied, setCopied] = useState(false)

  async function create() {
    setLoading(true)
    try {
      const r = await api.createEnrollment()
      setResult(r)
      setCopied(false)
    } catch (err) {
      toast.error(err instanceof Error ? err.message : 'Could not create token')
    } finally {
      setLoading(false)
    }
  }

  function copy() {
    if (!result) return
    const envBlock = `RELAY_URL=${result.relay_url}\nENROLL_TOKEN=${result.token}`
    navigator.clipboard?.writeText(envBlock).then(() => {
      setCopied(true)
      toast.success('Enrollment config copied')
      setTimeout(() => setCopied(false), 1800)
    })
  }

  return (
    <Panel
      title="Enrollment"
      subtitle="Pair a new device"
      action={
        <Button variant="primary" size="sm" onClick={create} loading={loading}>
          {!loading && <Plus className="size-4" />}
          New token
        </Button>
      }
    >
      <div className="p-5">
        <p className="text-[13px] leading-relaxed text-muted">
          A one-time, short-lived token. Drop it into{' '}
          <code className="rounded bg-surface-2 px-1.5 py-0.5 font-mono text-[11.5px] text-fg-dim">
            make-device-deb
          </code>{' '}
          to build a personalized package — no compiler required.
        </p>

        <AnimatePresence mode="wait">
          {result && (
            <motion.div
              key={result.token}
              initial={{ opacity: 0, height: 0 }}
              animate={{ opacity: 1, height: 'auto' }}
              exit={{ opacity: 0, height: 0 }}
              transition={{ duration: 0.3, ease: [0.16, 1, 0.3, 1] }}
              className="overflow-hidden"
            >
              <div className="mt-4 overflow-hidden rounded-xl bg-bg/70 ring-1 ring-line">
                <div className="flex items-center justify-between border-b border-line/80 px-3 py-2">
                  <span className="flex items-center gap-1.5 text-[11px] font-medium uppercase tracking-wider text-faint">
                    <KeyRound className="size-3.5" /> relay.env
                  </span>
                  <Button variant="ghost" size="sm" onClick={copy}>
                    {copied ? (
                      <Check className="size-3.5 text-online" />
                    ) : (
                      <Copy className="size-3.5" />
                    )}
                    {copied ? 'Copied' : 'Copy'}
                  </Button>
                </div>
                <pre className="overflow-x-auto px-3.5 py-3 font-mono text-[11.5px] leading-relaxed text-fg-dim">
                  <span className="text-faint">RELAY_URL=</span>
                  {result.relay_url}
                  {'\n'}
                  <span className="text-faint">ENROLL_TOKEN=</span>
                  <span className="text-signal">{result.token}</span>
                </pre>
              </div>

              <div className="mt-3 flex items-start gap-2 text-[12px] leading-relaxed text-muted">
                <ShieldAlert className="mt-0.5 size-3.5 shrink-0 text-signal/80" />
                <span>
                  Keep this private — it embeds in the package. Expires{' '}
                  <span className="text-fg-dim">{fmtAbs(rfc3339ToSec(result.expires_at))}</span>.
                </span>
              </div>
            </motion.div>
          )}
        </AnimatePresence>
      </div>
    </Panel>
  )
}
