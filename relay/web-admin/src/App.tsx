import { useCallback, useEffect, useRef, useState } from 'react'
import { Ban, Trash2 } from 'lucide-react'
import { toast } from 'sonner'
import { LoginScreen } from './components/LoginScreen'
import { Shell } from './components/Shell'
import { DevicesPanel, type ActionKey } from './components/DevicesPanel'
import { EnrollPanel } from './components/EnrollPanel'
import { SessionsPanel } from './components/SessionsPanel'
import { ActivityPanel } from './components/ActivityPanel'
import { Modal } from './components/ui/Modal'
import { Button } from './components/ui/Button'
import { api, ApiError } from './lib/api'
import type { AuditEntry, Device, EnrollmentSummary, Session } from './types'

export default function App() {
  const [authed, setAuthed] = useState<boolean | null>(null) // null = checking
  const [devices, setDevices] = useState<Device[]>([])
  const [sessions, setSessions] = useState<Session[]>([])
  const [enrollments, setEnrollments] = useState<EnrollmentSummary[]>([])
  const [audit, setAudit] = useState<AuditEntry[]>([])
  const [loading, setLoading] = useState(true)
  const [refreshing, setRefreshing] = useState(false)
  const [busyId, setBusyId] = useState('')
  const [confirmAction, setConfirmAction] = useState<{
    kind: 'revoke' | 'delete'
    device: Device
  } | null>(null)
  const [actingConfirm, setActingConfirm] = useState(false)
  const pollRef = useRef<number | undefined>(undefined)

  const loadAll = useCallback(async ({ silent }: { silent?: boolean } = {}) => {
    if (!silent) setRefreshing(true)
    try {
      const [d, s, e, a] = await Promise.all([
        api.devices(),
        api.sessions(),
        api.enrollments(),
        api.audit(),
      ])
      setDevices(d.devices || [])
      setSessions(s.sessions || [])
      setEnrollments(e.enrollments || [])
      setAudit(a.audit || [])
      setAuthed(true)
    } catch (err) {
      if (err instanceof ApiError && err.status === 401) setAuthed(false)
      else if (!silent) toast.error(err instanceof Error ? err.message : 'Failed to load')
    } finally {
      setLoading(false)
      setRefreshing(false)
    }
  }, [])

  // Initial auth probe: any failure (401 OR relay unreachable) drops to the
  // login screen rather than spinning on the splash forever.
  useEffect(() => {
    let cancelled = false
    ;(async () => {
      try {
        const [d, s, e, a] = await Promise.all([
          api.devices(),
          api.sessions(),
          api.enrollments(),
          api.audit(),
        ])
        if (cancelled) return
        setDevices(d.devices || [])
        setSessions(s.sessions || [])
        setEnrollments(e.enrollments || [])
        setAudit(a.audit || [])
        setAuthed(true)
      } catch {
        if (!cancelled) setAuthed(false)
      } finally {
        if (!cancelled) setLoading(false)
      }
    })()
    return () => {
      cancelled = true
    }
  }, [])

  // Light polling so online status stays fresh while signed in.
  useEffect(() => {
    if (authed !== true) return
    pollRef.current = window.setInterval(() => loadAll({ silent: true }), 10000)
    return () => window.clearInterval(pollRef.current)
  }, [authed, loadAll])

  function handleErr(err: unknown) {
    if (err instanceof ApiError && err.status === 401) {
      setAuthed(false)
      return
    }
    toast.error(err instanceof Error ? err.message : 'Something went wrong')
  }

  async function handleAction(key: ActionKey, device: Device) {
    // Destructive actions go through a confirmation step.
    if (key === 'delete' || key === 'revoke') {
      setConfirmAction({ kind: key, device })
      return
    }
    setBusyId(device.id)
    try {
      if (key === 'approve') {
        await api.approveDevice(device.id)
        toast.success(`${device.name} approved`)
      }
      await loadAll({ silent: true })
    } catch (err) {
      handleErr(err)
    } finally {
      setBusyId('')
    }
  }

  async function doConfirm() {
    if (!confirmAction) return
    const { kind, device } = confirmAction
    setActingConfirm(true)
    try {
      if (kind === 'delete') {
        await api.deleteDevice(device.id)
        toast.success(`${device.name} deleted`)
      } else {
        await api.revokeDevice(device.id)
        toast.success(`${device.name} access revoked`)
      }
      setConfirmAction(null)
      await loadAll({ silent: true })
    } catch (err) {
      handleErr(err)
    } finally {
      setActingConfirm(false)
    }
  }

  async function revokeSession(id: string) {
    setBusyId(id)
    try {
      const r = await api.revokeSession(id)
      if (r.current_revoked) return setAuthed(false)
      toast.success('Session revoked')
      await loadAll({ silent: true })
    } catch (err) {
      handleErr(err)
    } finally {
      setBusyId('')
    }
  }

  async function revokeOthers() {
    try {
      const r = await api.revokeOtherSessions()
      toast.success(`Revoked ${r.revoked} other session${r.revoked === 1 ? '' : 's'}`)
      await loadAll({ silent: true })
    } catch (err) {
      handleErr(err)
    }
  }

  async function signOut() {
    try {
      await api.logout()
    } catch {
      /* ignore */
    }
    setAuthed(false)
    setDevices([])
    setSessions([])
  }

  if (authed === null) return <BootSplash />
  if (authed === false)
    return (
      <LoginScreen
        onAuthed={() => {
          setLoading(true)
          loadAll({ silent: true })
        }}
      />
    )

  return (
    <>
      <Shell onRefresh={() => loadAll()} refreshing={refreshing} onSignOut={signOut}>
        <div className="flex flex-col gap-5">
          <DevicesPanel
            devices={devices}
            loading={loading}
            busyId={busyId}
            onAction={handleAction}
          />
          <ActivityPanel entries={audit} />
        </div>
        <div className="flex flex-col gap-5">
          <EnrollPanel
            enrollments={enrollments}
            onChanged={() => loadAll({ silent: true })}
          />
          <SessionsPanel
            sessions={sessions}
            busyId={busyId}
            onRevoke={revokeSession}
            onRevokeOthers={revokeOthers}
          />
        </div>
      </Shell>

      <Modal
        open={!!confirmAction}
        onOpenChange={(o) => !o && setConfirmAction(null)}
        title={confirmAction?.kind === 'delete' ? 'Delete device?' : 'Revoke device access?'}
        description={
          confirmAction
            ? confirmAction.kind === 'delete'
              ? `“${confirmAction.device.name}” will be removed from the relay. If it reconnects it will need a fresh enrollment.`
              : `“${confirmAction.device.name}” will be disconnected and blocked from the relay. A revoked device can’t be re-approved — restoring it needs a fresh enrollment.`
            : ''
        }
      >
        <div className="flex justify-end gap-2.5">
          <Button variant="secondary" onClick={() => setConfirmAction(null)}>
            Cancel
          </Button>
          <Button variant="danger-solid" loading={actingConfirm} onClick={doConfirm}>
            {confirmAction?.kind === 'delete' ? (
              <>
                <Trash2 className="size-4" />
                Delete device
              </>
            ) : (
              <>
                <Ban className="size-4" />
                Revoke access
              </>
            )}
          </Button>
        </div>
      </Modal>
    </>
  )
}

function BootSplash() {
  return (
    <div className="grid min-h-svh place-items-center">
      <div className="size-9 animate-spin rounded-full border-2 border-line border-t-signal" />
    </div>
  )
}
