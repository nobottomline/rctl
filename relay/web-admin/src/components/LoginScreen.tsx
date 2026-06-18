import { useState, type FormEvent, type ReactNode } from 'react'
import { motion } from 'framer-motion'
import { KeyRound, ShieldCheck } from 'lucide-react'
import { Button } from './ui/Button'
import { Field } from './ui/Field'
import { AuroraBackground } from './AuroraBackground'
import { ThemeToggle } from './ThemeToggle'
import { api, ApiError } from '../lib/api'

export function LoginScreen({ onAuthed }: { onAuthed: () => void }) {
  const [secret, setSecret] = useState('')
  const [error, setError] = useState('')
  const [loading, setLoading] = useState(false)

  async function submit(e: FormEvent) {
    e.preventDefault()
    if (!secret || loading) return
    setLoading(true)
    setError('')
    try {
      await api.login(secret)
      setSecret('')
      onAuthed()
    } catch (err) {
      setError(
        err instanceof ApiError && err.status === 401
          ? 'That admin secret is not recognized.'
          : err instanceof Error
            ? err.message
            : 'Login failed.',
      )
      setLoading(false)
    }
  }

  return (
    <>
      <AuroraBackground />
      <div className="relative z-10 grid min-h-svh place-items-center p-5">
        <div className="absolute right-5 top-5">
          <ThemeToggle />
        </div>
        <motion.div
          initial={{ opacity: 0, y: 16, scale: 0.97 }}
          animate={{ opacity: 1, y: 0, scale: 1 }}
          transition={{ duration: 0.45, ease: [0.16, 1, 0.3, 1] }}
          className="glass relative w-full max-w-[25rem] overflow-hidden rounded-[1.4rem] ring-1 ring-line-2 shadow-[0_30px_80px_-20px_rgba(0,0,0,0.7)]"
        >
          <div className="pointer-events-none absolute inset-x-0 top-0 h-px bg-gradient-to-r from-transparent via-signal/60 to-transparent" />
          <div className="p-8 sm:p-9">
            <motion.div
              initial="hidden"
              animate="show"
              variants={{ show: { transition: { staggerChildren: 0.08, delayChildren: 0.12 } } }}
            >
              <Stagger>
                <h1 className="text-[1.6rem] font-semibold leading-tight tracking-tight text-fg">
                  Sign in to relay
                </h1>
                <p className="mt-2 text-[14px] leading-relaxed text-muted">
                  Enter the admin secret configured for this relay to continue.
                </p>
              </Stagger>

              <form onSubmit={submit} className="mt-7 space-y-4">
                <Stagger>
                  <Field
                    label="Admin secret"
                    type="password"
                    icon={KeyRound}
                    autoComplete="current-password"
                    placeholder="••••••••••••••••"
                    value={secret}
                    autoFocus
                    onChange={(e) => {
                      setSecret(e.target.value)
                      setError('')
                    }}
                  />
                </Stagger>

                {error && (
                  <motion.p
                    initial={{ opacity: 0, y: -4 }}
                    animate={{ opacity: 1, y: 0 }}
                    className="flex items-center gap-2 text-[13px] text-danger"
                  >
                    <span className="size-1.5 rounded-full bg-danger" />
                    {error}
                  </motion.p>
                )}

                <Stagger>
                  <Button
                    type="submit"
                    variant="primary"
                    size="lg"
                    loading={loading}
                    disabled={!secret}
                    className="w-full"
                  >
                    {loading ? 'Verifying…' : 'Sign in'}
                  </Button>
                </Stagger>
              </form>

              <Stagger>
                <p className="mt-6 flex items-center justify-center gap-1.5 text-[12px] text-faint">
                  <ShieldCheck className="size-3.5" />
                  Sign-ins are rate-limited.
                </p>
              </Stagger>
            </motion.div>
          </div>
        </motion.div>
      </div>
    </>
  )
}

function Stagger({ children }: { children: ReactNode }) {
  return (
    <motion.div
      variants={{
        hidden: { opacity: 0, y: 10 },
        show: { opacity: 1, y: 0, transition: { duration: 0.4, ease: [0.16, 1, 0.3, 1] } },
      }}
    >
      {children}
    </motion.div>
  )
}
