import { useEffect, useId, useState } from 'react'
import { Download, RefreshCw, ExternalLink, ChevronDown, Check } from 'lucide-react'
import { Panel } from './Shell'
import { Button } from './ui/Button'
import { Checkbox } from './ui/Checkbox'
import { Modal } from './ui/Modal'
import { Menu, MenuItem } from './ui/Menu'
import { api, ApiError } from '../lib/api'
import type { HostUpdateStatus } from '../types'

const activePhases = new Set(['checking', 'downloading', 'installing', 'recovering'])
const phaseLabels: Record<string, string> = {
  idle: 'Ready', checking: 'Checking releases', downloading: 'Downloading verified release',
  installing: 'Installing and verifying', recovering: 'Recovering previous deployment',
  succeeded: 'Update complete', failed: 'Update failed', interrupted: 'Interrupted update recovered',
  recovery_required: 'Recovery required', check_failed: 'Release check unavailable', storage_error: 'Update storage error',
}

export function UpdatesPanel() {
  const automaticId = useId()
  const [status, setStatus] = useState<HostUpdateStatus | null>(null)
  const [connectionError, setConnectionError] = useState('')
  const [actionError, setActionError] = useState('')
  const [pending, setPending] = useState(false)
  const [confirm, setConfirm] = useState<'install' | 'automatic' | null>(null)
  const [selectedVersion, setSelectedVersion] = useState('')

  useEffect(() => {
    let stopped = false
    let timer: ReturnType<typeof setTimeout>
    async function refresh() {
      try {
        const result = await api.hostUpdates()
        if (!stopped) { setStatus(result); setConnectionError('') }
      } catch (err) {
        if (!stopped) setConnectionError(err instanceof ApiError && err.message === 'host_updates_not_managed'
          ? 'Server updates are not managed by the setup wizard.'
          : 'Waiting for the update service. The relay may be restarting.')
      } finally {
        if (!stopped) timer = setTimeout(refresh, 5000)
      }
    }
    void refresh()
    return () => { stopped = true; clearTimeout(timer) }
  }, [])

  async function act(action: 'check' | 'install' | 'policy', policy = status?.policy) {
    setPending(true); setActionError('')
    try {
      const next = await api.hostUpdateAction(action, action === 'install' ? { version: selectedVersion } : action === 'policy' ? policy : undefined)
      setStatus(next); setConfirm(null)
    } catch (err) {
      setActionError(err instanceof Error ? err.message : 'Update request failed')
    } finally { setPending(false) }
  }

  const busy = pending || !!connectionError || !!status && activePhases.has(status.phase)
  return (
    <Panel title="Updates" subtitle="Relay server">
      <div className="space-y-4 p-4 text-sm">
        {status && <>
          <dl className="grid grid-cols-2 gap-2">
            <dt className="text-muted">Installed</dt><dd className="text-right font-mono">{status.installed}</dd>
            <dt className="text-muted">Latest verified</dt><dd className="text-right font-mono">{status.latest || 'Not checked'}</dd>
          </dl>
          <p role="status" className="text-fg-dim">{phaseLabels[status.phase] || 'Status unavailable'}</p>
          {status.error && <p role="alert" className="text-danger break-words">{status.error}</p>}
          {status.job?.completed_at && <div className="text-xs text-muted" role="status">
            Last update: {status.job.target} · {phaseLabels[status.job.phase] || status.job.phase}
            {status.job.error && status.job.error !== status.error && <p className="mt-1 text-danger">{status.job.error}</p>}
          </div>}
          <div className="flex flex-wrap gap-2">
            <Button size="sm" disabled={busy} onClick={() => void act('check')}><RefreshCw className="size-4" />Check now</Button>
            <Button size="sm" variant="primary" disabled={busy || !status.available} onClick={() => { setSelectedVersion(status.latest || ''); setConfirm('install') }}><Download className="size-4" />Update relay</Button>
            {status.latest && /^\d+\.\d+\.\d+$/.test(status.latest) && <a className="inline-flex items-center gap-1 text-muted hover:text-fg" href={`https://github.com/nobottomline/rctl/releases/tag/v${status.latest}`} target="_blank" rel="noreferrer"><ExternalLink className="size-4" />Release notes</a>}
          </div>
          <div className="border-t border-line pt-3 space-y-3">
            <div className="flex items-center gap-2">
              <Checkbox id={automaticId} checked={status.policy.automatic} disabled={busy} onCheckedChange={checked => {
                if (checked === true) setConfirm('automatic')
                else if (checked === false) void act('policy', { ...status.policy, automatic: false })
              }} />
              <label htmlFor={automaticId} className="cursor-pointer leading-snug peer-disabled:cursor-not-allowed peer-disabled:opacity-50">
                Install relay updates automatically
              </label>
            </div>
            <div className="flex items-center justify-between gap-3 text-muted">
              <span>Maintenance hour (UTC)</span>
              <Menu trigger={<Button size="sm" disabled={busy} aria-label="Maintenance hour UTC">{String(status.policy.hour_utc).padStart(2, '0')}:00<ChevronDown className="size-4" /></Button>}>
                <div className="max-h-56 overflow-y-auto">
                  {Array.from({ length: 24 }, (_, hour) => <MenuItem key={hour} onSelect={() => void act('policy', { ...status.policy, hour_utc: hour })}>
                    <span className="w-12 font-mono">{String(hour).padStart(2, '0')}:00</span>{hour === status.policy.hour_utc && <Check className="size-4" />}
                  </MenuItem>)}
                </div>
              </Menu>
            </div>
          </div>
          {status.checked_at && <p className="text-xs text-muted">Last checked {new Date(status.checked_at * 1000).toLocaleString()}</p>}
        </>}
        {connectionError && <p role="status" className="text-muted">{connectionError}</p>}
        {!status && !connectionError && <p className="text-muted">Loading update status</p>}
        {actionError && <p role="alert" className="text-danger break-words">{actionError}</p>}
      </div>
      <Modal open={confirm !== null} onOpenChange={open => !open && !pending && setConfirm(null)} title={confirm === 'automatic' ? 'Enable automatic relay updates?' : `Update relay to ${selectedVersion}?`} description={confirm === 'automatic'
        ? 'Verified releases will be installed during the selected UTC hour. Active remote connections may be interrupted. Device updates require separate confirmation.'
        : 'Remote connections will briefly disconnect. The server creates a backup and verifies the new deployment, with recovery on failure. This does not update connected devices.'}>
        <div className="flex justify-end gap-2">
          <Button disabled={pending} onClick={() => setConfirm(null)}>Cancel</Button>
          <Button variant="primary" loading={pending} disabled={!!connectionError} onClick={() => confirm === 'automatic' && status ? void act('policy', { ...status.policy, automatic: true }) : void act('install')}><Download className="size-4" />{confirm === 'automatic' ? 'Enable' : 'Install update'}</Button>
        </div>
      </Modal>
    </Panel>
  )
}
