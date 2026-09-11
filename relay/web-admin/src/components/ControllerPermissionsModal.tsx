import { useState } from 'react'
import { ShieldCheck } from 'lucide-react'
import { toast } from 'sonner'
import { api, ApiError } from '../lib/api'
import { SCOPE_OPTIONS } from '../lib/scopes'
import type { Controller } from '../types'
import { Button } from './ui/Button'
import { Modal } from './ui/Modal'

export function ControllerPermissionsModal({ controller, current, onClose, onReload, onChanged }: {
  controller: Controller
  current?: Controller
  onClose: () => void
  onReload: (controller: Controller) => void
  onChanged: () => void
}) {
  const [scopes, setScopes] = useState(controller.scopes)
  const [saving, setSaving] = useState(false)
  const [conflict, setConflict] = useState(false)
  const [error, setError] = useState('')
  const unavailable = !current || current.status !== 'active'
  const stale = conflict || current?.authorization_revision !== controller.authorization_revision
  const changed = scopes.length !== controller.scopes.length || scopes.some((scope) => !controller.scopes.includes(scope))

  async function save() {
    if (saving || unavailable || stale || !changed || !scopes.length || !controller.authorization_revision) return
    setSaving(true)
    setError('')
    try {
      await api.updateControllerPermissions(controller.id, scopes, controller.authorization_revision)
      toast.success('Permissions saved. Previous sessions are closing.')
      onChanged()
      onClose()
    } catch (error) {
      if (error instanceof ApiError && error.status === 409) {
        setConflict(true)
        onChanged()
      }
      setError(error instanceof ApiError && error.status === 409
        ? 'Controller access changed elsewhere. Reload before saving.'
        : 'Could not confirm the update. Refresh controller details before retrying.')
      onChanged()
    } finally { setSaving(false) }
  }

  return (
    <Modal open autoFocusContent onOpenChange={(open) => { if (!open && !saving) onClose() }} title="Controller permissions"
      description={`${controller.name} · Active sessions will disconnect. Pairing is preserved.`} className="max-w-lg">
      <form onSubmit={(event) => { event.preventDefault(); void save() }} className="space-y-5">
        <fieldset disabled={saving || unavailable || stale} className="grid grid-cols-1 gap-3 sm:grid-cols-2 disabled:opacity-60">
          <legend className="sr-only">Permissions</legend>
          {SCOPE_OPTIONS.map((scope) => (
            <label key={scope.id} className="flex min-h-10 cursor-pointer items-center gap-2 rounded-lg bg-surface-2 px-3 py-2 text-[12px] text-fg-dim ring-1 ring-line">
              <input type="checkbox" checked={scopes.includes(scope.id)} className="size-4 shrink-0 accent-signal"
                onChange={(event) => setScopes((previous) => event.target.checked ? [...previous, scope.id] : previous.filter((value) => value !== scope.id))} />
              {scope.label}
              {scope.elevated && <ShieldCheck className="ml-auto size-3.5 shrink-0 text-signal" />}
            </label>
          ))}
        </fieldset>
        {!scopes.length && <p role="alert" className="text-sm text-danger">Select at least one permission. Use Revoke access to remove all access.</p>}
        {(error || unavailable || stale) && <p role="alert" className="text-sm text-danger">{unavailable ? 'This controller is no longer authorized.' : error || 'Permissions changed elsewhere. Reload before saving.'}</p>}
        <div className="flex flex-wrap justify-end gap-2">
          <Button type="button" variant="secondary" disabled={saving} onClick={onClose}>Cancel</Button>
          {stale && current && !unavailable && <Button type="button" variant="secondary" disabled={saving || (conflict && current.authorization_revision === controller.authorization_revision)} onClick={() => onReload(current)}>Reload permissions</Button>}
          <Button type="submit" disabled={saving || unavailable || stale || !changed || !scopes.length}>{saving ? 'Saving…' : 'Save permissions'}</Button>
        </div>
      </form>
    </Modal>
  )
}
