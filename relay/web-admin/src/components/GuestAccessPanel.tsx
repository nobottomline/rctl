import { useCallback, useEffect, useRef, useState } from 'react'
import { Ban, Check, Copy, Link, Pencil, Plus, Trash2, Clock3, ShieldCheck, Tablet } from 'lucide-react'
import { toast } from 'sonner'
import { guestAPI, type GuestGrant, type GuestInvitation, type GuestDisconnectResult } from '../lib/guestAccess'
import type { GuestPermission } from '../lib/guestPermissions.generated'
import { ApiError } from '../lib/api'
import { fmtUntil } from '../lib/format'
import type { Device } from '../types'
import { Panel } from './Shell'
import { Button } from './ui/Button'
import { Field } from './ui/Field'
import { Modal } from './ui/Modal'
import { Checkbox } from './ui/Checkbox'
import { SelectField } from './ui/SelectField'
import { GuestPermissionPicker } from './GuestPermissionPicker'

const live = (grant: GuestGrant) => grant.status === 'active' || grant.status === 'invited'
function reportDisconnect(result: GuestDisconnectResult, message: string) {
  if (result.disconnect_confirmed) toast.success(message)
  else toast.warning('Access blocked. Device disconnect is not confirmed; its authorization lease expires within 20 seconds.')
}

export function GuestAccessPanel({ devices, onChanged }: { devices: Device[]; onChanged: () => void }) {
  const [grants, setGrants] = useState<GuestGrant[]>([])
  const [error, setError] = useState('')
  const [formError, setFormError] = useState('')
  const [loading, setLoading] = useState(true)
  const [form, setForm] = useState<GuestGrant | 'create' | null>(null)
  const [invitation, setInvitation] = useState<GuestInvitation | null>(null)
  const [device, setDevice] = useState('')
  const [label, setLabel] = useState('Guest')
  const [permissions, setPermissions] = useState<GuestPermission[]>(['screen.view'])
  const [ttl, setTTL] = useState(3600)
  const [direct, setDirect] = useState(false)
  const [busy, setBusy] = useState('')
  const [confirmAll, setConfirmAll] = useState(false)
  const [history, setHistory] = useState(false)
  const [copied, setCopied] = useState(false)
  const mounted = useRef(true)
  const loadVersion = useRef(0)
  const reload = useCallback(async () => {
    const version = ++loadVersion.current
    try {
      const result = await guestAPI.list()
      if (mounted.current && loadVersion.current === version) { setGrants(result.grants); setError('') }
    } catch (e) {
      if (mounted.current && loadVersion.current === version) setError(e instanceof Error ? e.message : 'Could not load temporary access')
    } finally { if (mounted.current && loadVersion.current === version) setLoading(false) }
  }, [])
  useEffect(() => {
    mounted.current = true
    void reload()
    const timer = setInterval(() => void reload(), 10000)
    return () => { mounted.current = false; clearInterval(timer) }
  }, [reload])
  const eligible = devices.filter((d) => d.status === 'approved' && d.online && d.features.includes('guest.scoped_sessions_v1'))
  function open(grant: GuestGrant | 'create') {
    setForm(grant); setInvitation(null); setCopied(false)
    setDevice(grant === 'create' ? eligible[0]?.id || '' : grant.device_id)
    setLabel(grant === 'create' ? 'Guest' : grant.label)
    setPermissions(grant === 'create' ? ['screen.view'] : grant.permissions)
    setDirect(grant === 'create' ? false : grant.allow_direct)
    setFormError('')
  }
  async function save() {
    if (!form || busy) return
    setBusy('form'); setFormError('')
    try {
      if (form === 'create') {
        setInvitation(await guestAPI.create({ device_id: device, label, permissions, ttl_seconds: ttl, allow_direct: direct }))
      } else {
        const result = await guestAPI.permissions(form, permissions)
        if (result.changed) reportDisconnect(result, 'Permissions updated. Previous connections closed.')
        else toast.success('Permissions are unchanged')
        setForm(null)
      }
      await reload(); onChanged()
    } catch (e) {
      if (e instanceof ApiError && e.status === 409 && form !== 'create') {
        setFormError('Access changed in another session. Close this dialog and open it again to reload permissions.')
        await reload()
      } else setFormError(e instanceof Error ? e.message : 'Could not save temporary access')
    } finally { setBusy('') }
  }
  async function revoke(grant?: GuestGrant) {
    if (busy) return
    setBusy(grant?.id || 'all')
    try {
      reportDisconnect(await guestAPI.revoke(grant?.id), grant ? `${grant.label} disconnected` : 'All guest access revoked')
      setConfirmAll(false); await reload(); onChanged()
    } catch (e) { toast.error(e instanceof Error ? e.message : 'Could not revoke access') }
    finally { setBusy('') }
  }
  async function remove(grant: GuestGrant) {
    if (busy) return
    setBusy(grant.id)
    try { await guestAPI.remove(grant.id); await reload(); onChanged() }
    catch (e) { toast.error(e instanceof Error ? e.message : 'Could not remove access history') }
    finally { setBusy('') }
  }
  async function copy() {
    try { await navigator.clipboard.writeText(invitation!.invitation_url); setCopied(true) }
    catch { toast.error('Clipboard access was denied. Select and copy the link below.') }
  }
  const active = grants.filter(live)
  const shown = grants.filter((g) => history ? !live(g) : live(g))
  return <>
    <Panel title="Temporary browser access" subtitle={`${active.length} available · ${active.reduce((n, g) => n + g.connections, 0)} connections`}
      action={<div className="flex gap-2"><Button variant="danger" size="sm" disabled={!active.length || !!busy} onClick={() => setConfirmAll(true)}><Ban className="size-4" />Revoke all</Button>
        <Button variant="primary" size="sm" disabled={!eligible.length} onClick={() => open('create')}><Plus className="size-4" />Create link</Button></div>}>
      <div className="px-5 py-3 text-xs text-muted">A one-time link grants access to one device. Rights changes close all previous connections.
        {!eligible.length && <p className="mt-2">An online device with guest access support is required.</p>}
        <button className="mt-2 block text-signal" onClick={() => setHistory(!history)}>{history ? 'Show available access' : 'Show ended access'}</button>
      </div>
      {error && !form && <div role="alert" className="px-5 py-3 text-sm text-danger">{error}<button className="ml-3 underline" onClick={() => void reload()}>Retry</button></div>}
      {loading ? <p className="px-5 pb-4 text-sm text-muted">Loading temporary access…</p> : !shown.length ? <p className="px-5 pb-4 text-sm text-muted">{history ? 'No ended access.' : 'No temporary access.'}</p> :
        <div className="max-h-96 overflow-auto divide-y divide-line">{shown.map((g) => <div key={g.id} className="flex flex-wrap items-center gap-3 px-5 py-3">
          <Link className="size-4 text-muted" /><div className="min-w-0 flex-1"><p className="text-sm font-medium">{g.label} <span className="text-xs text-muted">· {g.status}</span></p>
            <p className="text-xs text-muted">{g.device_name} · {g.permissions.length} permissions · {g.connections} connections</p><p className="text-xs text-faint">Expires {fmtUntil(g.expires_at)}</p></div>
          {live(g) ? <><Button size="sm" disabled={!!busy} onClick={() => open(g)}><Pencil className="size-3" />Permissions</Button><Button size="sm" variant="danger" loading={busy === g.id} disabled={!!busy} onClick={() => void revoke(g)}>Revoke</Button></> :
            <Button size="icon" variant="ghost" aria-label={`Delete ${g.label} from history`} loading={busy === g.id} disabled={!!busy} onClick={() => void remove(g)}><Trash2 className="size-4" /></Button>}
        </div>)}</div>}
    </Panel>
    <Modal open={!!form} autoFocusContent onOpenChange={(open) => { if (!open && !busy) { setForm(null); setInvitation(null); setFormError('') } }}
      className={invitation ? 'max-w-lg' : 'max-w-4xl'}
      title={invitation ? 'Invitation ready' : form === 'create' ? 'Create temporary access' : 'Change guest permissions'}
      description={invitation ? 'A one-time link for one browser. Copy it before closing this window.' : form === 'create' ? 'Choose a device, set an expiry, and allow only what your guest needs.' : 'Saving changes closes all guest connections. The guest can reconnect with the updated permissions.'}
      footer={<div className="space-y-3">
        {formError && !invitation && <p role="alert" className="text-sm text-danger">{formError}</p>}
        <div className="flex flex-wrap items-center justify-between gap-3">
          <p className="text-xs text-muted">{invitation ? 'The link is shown only once.' : `${permissions.length} permission${permissions.length === 1 ? '' : 's'} selected`}</p>
          <div className="ml-auto flex gap-2">
            {invitation ? <><Button onClick={() => void copy()}>{copied ? <Check className="size-4" /> : <Copy className="size-4" />}{copied ? 'Copied' : 'Copy link'}</Button><Button variant="primary" onClick={() => { setInvitation(null); setForm(null) }}>Done</Button></> : <>
              <Button disabled={!!busy} onClick={() => { setForm(null); setFormError('') }}>Cancel</Button>
              <Button variant="primary" loading={busy === 'form'} disabled={!!busy || !permissions.length || (form === 'create' && !device)} onClick={() => void save()}>{form === 'create' ? 'Create link' : 'Save permissions'}</Button>
            </>}
          </div>
        </div>
      </div>}>
      {invitation ? <div className="space-y-5">
        <div className="flex items-center gap-3"><span className="grid size-10 shrink-0 place-items-center rounded-xl bg-online/10 text-online"><Check className="size-5" /></span><div><p className="text-sm font-medium text-fg">{label}</p><p className="text-xs text-muted">Share privately with your guest</p></div></div>
        <textarea aria-label="Invitation link" readOnly value={invitation.invitation_url} className="w-full resize-none rounded-xl border border-line bg-bg/55 p-3.5 font-mono text-xs leading-relaxed text-fg" rows={4} />
        <div className="space-y-2 text-xs text-muted"><p>Claim before {fmtUntil(invitation.claim_deadline)}.</p><p>Access expires {fmtUntil(invitation.expires_at)}. You can revoke it at any time.</p></div>
      </div> : <div className="grid min-w-0 gap-6 lg:grid-cols-[15rem_minmax(0,1fr)] lg:gap-8">
        <fieldset disabled={!!busy} className="min-w-0 space-y-5 disabled:opacity-70">
          <legend className="sr-only">Access settings</legend>
          {form === 'create' ? <>
            <div className="flex items-center gap-2 text-sm font-semibold"><Link className="size-4 text-muted" />Access details</div>
            <Field label="Guest label" value={label} maxLength={80} onChange={(e) => setLabel(e.target.value)} />
            <SelectField label="Device" value={device} onValueChange={setDevice} disabled={!!busy} options={eligible.map((d) => ({ value: d.id, label: d.name }))} placeholder="Choose a device" />
            <SelectField label="Access lifetime" value={String(ttl)} onValueChange={(value) => setTTL(Number(value))} disabled={!!busy} options={[{ value: '300', label: '5 minutes' }, { value: '900', label: '15 minutes' }, { value: '3600', label: '1 hour' }, { value: '14400', label: '4 hours' }, { value: '86400', label: '24 hours' }]} />
          </> : <>
            <div className="flex items-center gap-2 text-sm font-semibold"><Link className="size-4 text-muted" />{label}</div>
            <div className="space-y-3 rounded-xl border border-line bg-bg/25 p-4 text-sm">
              <p className="flex items-start gap-2"><Tablet className="mt-0.5 size-4 shrink-0 text-muted" /><span className="break-words">{form && form.device_name}</span></p>
              <p className="flex items-start gap-2 text-xs leading-relaxed text-muted"><Clock3 className="size-4 shrink-0" />Expires {form && fmtUntil(form.expires_at)}</p>
            </div>
          </>}
          <div className="border-t border-line pt-5">
            {form === 'create' ? <label className="flex cursor-pointer items-start gap-3">
              <Checkbox checked={direct} disabled={!!busy} onCheckedChange={(checked) => setDirect(checked === true)} className="mt-0.5" />
              <span><span className="block text-[13px] font-medium text-fg-dim">Allow direct connection</span><span className="mt-1.5 block text-xs leading-relaxed text-muted">Off uses TURN only. Direct connections may reveal network addresses to the guest.</span></span>
            </label> : <p className="text-xs leading-relaxed text-muted">{direct ? 'Direct connections are allowed.' : 'Connections use TURN only.'}</p>}
          </div>
          <div className="flex items-start gap-2.5 text-xs leading-relaxed text-muted"><ShieldCheck className="mt-0.5 size-4 shrink-0" /><p>You can change permissions or revoke access at any time. These permissions apply to guest access; local control follows the device’s Relay-only policy.</p></div>
        </fieldset>
        <div className="min-w-0 border-t border-line pt-6 lg:border-t-0 lg:border-l lg:pl-8 lg:pt-0">
          <GuestPermissionPicker key={form === 'create' ? 'create' : form?.id} value={permissions} onChange={setPermissions} operationsSupported={!!devices.find((d) => d.id === device)?.features.includes('guest.operations_v1')} disabled={!!busy} />
        </div>
      </div>}
    </Modal>
    <Modal open={confirmAll} onOpenChange={(open) => !busy && setConfirmAll(open)} title="Revoke all guest access?" description="Every guest connection will close and every outstanding invitation will stop working.">
      <div className="flex justify-end gap-2"><Button disabled={!!busy} onClick={() => setConfirmAll(false)}>Cancel</Button><Button variant="danger-solid" loading={busy === 'all'} onClick={() => void revoke()}>Revoke all</Button></div>
    </Modal>
  </>
}
