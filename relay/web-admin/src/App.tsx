import { useCallback, useEffect, useRef, useState } from 'react'
import { Ban, Check, Download, RadioTower, Trash2, Wifi, WifiOff } from 'lucide-react'
import { toast } from 'sonner'
import { LoginScreen } from './components/LoginScreen'
import { Shell } from './components/Shell'
import { DevicesPanel, type ActionKey } from './components/DevicesPanel'
import { EnrollPanel } from './components/EnrollPanel'
import { ControllersPanel } from './components/ControllersPanel'
import { SessionsPanel } from './components/SessionsPanel'
import { ActivityPanel } from './components/ActivityPanel'
import { StatusPanel } from './components/StatusPanel'
import { Modal } from './components/ui/Modal'
import { Button } from './components/ui/Button'
import { api, ApiError } from './lib/api'
import type { AuditEntry, Controller, Device, EnrollmentSummary, RelayStatus, Session } from './types'

export default function App() {
  const [authed, setAuthed] = useState<boolean | null>(null) // null = checking
  const [devices, setDevices] = useState<Device[]>([])
  const [sessions, setSessions] = useState<Session[]>([])
  const [enrollments, setEnrollments] = useState<EnrollmentSummary[]>([])
  const [controllers, setControllers] = useState<Controller[]>([])
  const [audit, setAudit] = useState<AuditEntry[]>([])
  const [status, setStatus] = useState<RelayStatus | null>(null)
  const [loading, setLoading] = useState(true)
  const [refreshing, setRefreshing] = useState(false)
  const [busyId, setBusyId] = useState('')
  const [confirmAction, setConfirmAction] = useState<{
    kind: 'revoke' | 'delete' | 'update'
    device: Device
  } | null>(null)
  const [actingConfirm, setActingConfirm] = useState(false)
  const [localAccess, setLocalAccess] = useState<{
    device: Device
    current: boolean
    selected: boolean
  } | null>(null)
  const [savingLocalAccess, setSavingLocalAccess] = useState(false)
  const pollRef = useRef<number | undefined>(undefined)

  const loadAll = useCallback(async ({ silent }: { silent?: boolean } = {}) => {
    if (!silent) setRefreshing(true)
    try {
      const [d, s, e, c, st] = await Promise.all([
        api.devices(),
        api.sessions(),
        api.enrollments(),
        api.controllers(),
        api.status(),
      ])
      setDevices(d.devices || [])
      setSessions(s.sessions || [])
      setEnrollments(e.enrollments || [])
      setControllers(c.controllers || [])
      setStatus(st)
      setAuthed(true)
    } catch (err) {
      if (err instanceof ApiError && err.status === 401) setAuthed(false)
      else if (!silent) toast.error(err instanceof Error ? err.message : 'Failed to load')
    } finally {
      setLoading(false)
      setRefreshing(false)
    }
  }, [])

  const loadAudit = useCallback(() => {
    // The activity feed is heavier and less time-critical than live status, so it
    // refreshes on its own slower cadence (not the 10s status poll). A high limit is
    // fine -- the response is bounded by the real row count, and the list is
    // virtualized, so a big history is cheap to hold and render.
    api
      .audit(10000)
      .then((r) => setAudit(r.audit || []))
      .catch(() => {})
  }, [])

  // Initial auth probe: any failure (401 OR relay unreachable) drops to the
  // login screen rather than spinning on the splash forever.
  useEffect(() => {
    let cancelled = false
    ;(async () => {
      try {
        const [d, s, e, c, st] = await Promise.all([
          api.devices(),
          api.sessions(),
          api.enrollments(),
          api.controllers(),
          api.status(),
        ])
        if (cancelled) return
        setDevices(d.devices || [])
        setSessions(s.sessions || [])
        setEnrollments(e.enrollments || [])
        setControllers(c.controllers || [])
        setStatus(st)
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

  // Activity feed refreshes on its own slower cadence, decoupled from status.
  useEffect(() => {
    if (authed !== true) return
    loadAudit()
    const id = window.setInterval(loadAudit, 30000)
    return () => window.clearInterval(id)
  }, [authed, loadAudit])

  function handleErr(err: unknown) {
    if (err instanceof ApiError && err.status === 401) {
      setAuthed(false)
      return
    }
    toast.error(err instanceof Error ? err.message : 'Something went wrong')
  }

  async function handleAction(key: ActionKey, device: Device) {
    // Destructive actions go through a confirmation step.
    if (key === 'delete' || key === 'revoke' || key === 'update') {
      setConfirmAction({ kind: key, device })
      return
    }
    setBusyId(device.id)
    try {
      if (key === 'approve') {
        await api.approveDevice(device.id)
        toast.success(`${device.name} approved`)
      }
      if (key === 'local-access') {
        const policy = await api.localAccess(device.id)
        setLocalAccess({ device, current: policy.enabled, selected: policy.enabled })
      }
      await loadAll({ silent: true })
    } catch (err) {
      handleErr(err)
    } finally {
      setBusyId('')
    }
  }

  async function saveLocalAccess() {
    if (!localAccess) return
    if (localAccess.current === localAccess.selected) {
      setLocalAccess(null)
      return
    }
    setSavingLocalAccess(true)
    try {
      await api.setLocalAccess(localAccess.device.id, localAccess.selected)
      toast.success(
        localAccess.selected
          ? 'LAN access enabled; device is reconnecting'
          : 'Relay-only mode enabled; device is reconnecting',
      )
      setLocalAccess(null)
      window.setTimeout(() => loadAll({ silent: true }), 4500)
    } catch (err) {
      handleErr(err)
    } finally {
      setSavingLocalAccess(false)
    }
  }

  async function doConfirm() {
    if (!confirmAction) return
    const { kind, device } = confirmAction
    setActingConfirm(true)
    try {
      if (kind === 'update') {
        const result = await api.updateDevice(device.id)
        toast.success(`Update started (${result.job_id.slice(0, 8)})`)
      } else if (kind === 'delete') {
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
    setEnrollments([])
    setControllers([])
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
      <Shell
        onRefresh={() => {
          loadAll()
          loadAudit()
        }}
        refreshing={refreshing}
        onSignOut={signOut}
      >
        <div className="flex flex-col gap-5">
          <DevicesPanel
            devices={devices}
            loading={loading}
            busyId={busyId}
            audit={audit}
            updateConfigured={status?.update_configured ?? false}
            updateTargetVersion={status?.update_target_version}
            onAction={handleAction}
          />
          <ActivityPanel entries={audit} sessions={sessions} />
        </div>
        <div className="flex flex-col gap-5">
          <ControllersPanel controllers={controllers} onChanged={() => loadAll({ silent: true })} />
          <EnrollPanel
            enrollments={enrollments}
            packageAvailable={status?.device_package_available ?? false}
            packageVersion={status?.device_package_version}
            onChanged={() => loadAll({ silent: true })}
          />
          <SessionsPanel
            sessions={sessions}
            busyId={busyId}
            audit={audit}
            onRevoke={revokeSession}
            onRevokeOthers={revokeOthers}
          />
          <StatusPanel status={status} />
        </div>
      </Shell>

      <Modal
        open={!!confirmAction}
        onOpenChange={(o) => !o && setConfirmAction(null)}
        title={
          confirmAction?.kind === 'delete'
            ? 'Delete device?'
            : confirmAction?.kind === 'update'
              ? 'Update device?'
              : 'Revoke device access?'
        }
        description={
          confirmAction
            ? confirmAction.kind === 'delete'
              ? `“${confirmAction.device.name}” will be removed from the relay. If it reconnects it will need a fresh enrollment.`
              : confirmAction.kind === 'update'
                ? `“${confirmAction.device.name}” will download a signed release, preserve its relay identity, reinstall cleanly, and roll back automatically if verification fails.`
                : `“${confirmAction.device.name}” will be disconnected and blocked from the relay. A revoked device can’t be re-approved — restoring it needs a fresh enrollment.`
            : ''
        }
      >
        <div className="flex justify-end gap-2.5">
          <Button variant="secondary" onClick={() => setConfirmAction(null)}>
            Cancel
          </Button>
          <Button variant={confirmAction?.kind === 'update' ? 'primary' : 'danger-solid'} loading={actingConfirm} onClick={doConfirm}>
            {confirmAction?.kind === 'update' ? (
              <>
                <Download className="size-4" />
                Start update
              </>
            ) : confirmAction?.kind === 'delete' ? (
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

      <Modal
        open={!!localAccess}
        onOpenChange={(open) => !open && !savingLocalAccess && setLocalAccess(null)}
        title="Local network access"
        description={
          localAccess
            ? `Choose how “${localAccess.device.name}” accepts direct connections. Relay access remains available in both modes.`
            : undefined
        }
        className="max-w-lg"
      >
        {localAccess && (
          <div className="space-y-5">
            <div className="grid grid-cols-2 gap-2 rounded-xl bg-surface-2 p-1 ring-1 ring-line">
              <button
                type="button"
                aria-pressed={localAccess.selected}
                onClick={() => setLocalAccess({ ...localAccess, selected: true })}
                className={`flex min-h-24 flex-col items-start justify-between rounded-lg p-3 text-left transition-colors ${
                  localAccess.selected ? 'bg-bg text-fg shadow-sm ring-1 ring-line-2' : 'text-muted hover:text-fg-dim'
                }`}
              >
                <span className="flex w-full items-center justify-between">
                  <Wifi className="size-4" />
                  {localAccess.selected && <Check className="size-4 text-signal" />}
                </span>
                <span>
                  <strong className="block text-[13.5px] font-medium">LAN + Relay</strong>
                  <span className="mt-0.5 block text-[11.5px] leading-snug opacity-75">Port 8080 accepts trusted LAN clients.</span>
                </span>
              </button>
              <button
                type="button"
                aria-pressed={!localAccess.selected}
                onClick={() => setLocalAccess({ ...localAccess, selected: false })}
                className={`flex min-h-24 flex-col items-start justify-between rounded-lg p-3 text-left transition-colors ${
                  !localAccess.selected ? 'bg-bg text-fg shadow-sm ring-1 ring-line-2' : 'text-muted hover:text-fg-dim'
                }`}
              >
                <span className="flex w-full items-center justify-between">
                  <WifiOff className="size-4" />
                  {!localAccess.selected && <Check className="size-4 text-signal" />}
                </span>
                <span>
                  <strong className="block text-[13.5px] font-medium">Relay only</strong>
                  <span className="mt-0.5 block text-[11.5px] leading-snug opacity-75">Port 8080 listens only inside the device.</span>
                </span>
              </button>
            </div>

            {!localAccess.selected && (
              <div className="flex gap-2.5 text-[12px] leading-relaxed text-muted">
                <RadioTower className="mt-0.5 size-4 shrink-0 text-signal" />
                Direct Wi-Fi and USB browser connections will stop working. Keep relay access and SSH recovery available before applying this mode.
              </div>
            )}

            <div className="flex justify-end gap-2.5">
              <Button variant="secondary" disabled={savingLocalAccess} onClick={() => setLocalAccess(null)}>
                Cancel
              </Button>
              <Button variant="primary" loading={savingLocalAccess} onClick={saveLocalAccess}>
                {!savingLocalAccess && (localAccess.selected ? <Wifi className="size-4" /> : <WifiOff className="size-4" />)}
                Apply mode
              </Button>
            </div>
          </div>
        )}
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
