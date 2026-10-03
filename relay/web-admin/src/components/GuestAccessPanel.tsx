import { useCallback, useEffect, useRef, useState } from 'react'
import { Ban, Check, Copy, Link, Pencil, Plus, Trash2 } from 'lucide-react'
import { toast } from 'sonner'
import { guestAPI, type GuestGrant, type GuestInvitation, type GuestDisconnectResult } from '../lib/guestAccess'
import { GUEST_PERMISSIONS, type GuestPermission } from '../lib/guestPermissions.generated'
import { ApiError } from '../lib/api'
import { fmtUntil } from '../lib/format'
import type { Device } from '../types'
import { Panel } from './Shell'
import { Button } from './ui/Button'
import { Field } from './ui/Field'
import { Modal } from './ui/Modal'

const live = (grant: GuestGrant) => grant.status === 'active' || grant.status === 'invited'
function reportDisconnect(result: GuestDisconnectResult, message: string) {
  if (result.disconnect_confirmed) toast.success(message)
  else toast.warning('Access blocked. Device disconnect is not confirmed; its authorization lease expires within 20 seconds.')
}

export function GuestAccessPanel({ devices, onChanged }: { devices: Device[]; onChanged: () => void }) {
  const [grants, setGrants] = useState<GuestGrant[]>([])
  const [error, setError] = useState('')
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
    setError('')
  }
  async function save() {
    if (!form || busy) return
    setBusy('form'); setError('')
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
        setError('Access changed in another session. Close this dialog and open it again to reload permissions.')
        await reload()
      } else setError(e instanceof Error ? e.message : 'Could not save temporary access')
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
    <Modal open={!!form} onOpenChange={(open) => { if (!open && !busy) { setForm(null); setInvitation(null); setError('') } }} title={invitation ? 'Invitation ready' : form === 'create' ? 'Create temporary access' : 'Change guest permissions'}
      description={invitation ? 'Copy this link now. It is shown only once and can be claimed by one browser before the claim deadline.' : form === 'create' ? 'Choose exactly what your guest can do and when access ends.' : 'Saving a change disconnects every open connection. The guest must connect again with the updated rights.'}>
      {invitation ? <div className="space-y-4">
        <textarea aria-label="Invitation link" readOnly value={invitation.invitation_url} className="w-full rounded-lg bg-bg p-3 font-mono text-xs text-fg" rows={4} />
        <p className="text-xs text-muted">Claim before {fmtUntil(invitation.claim_deadline)}. Access expires {fmtUntil(invitation.expires_at)}.</p>
        <div className="flex justify-end gap-2"><Button onClick={() => void copy()}>{copied ? <Check className="size-4" /> : <Copy className="size-4" />}Copy link</Button><Button variant="primary" onClick={() => { setInvitation(null); setForm(null) }}>Done</Button></div>
      </div> : <div className="space-y-4">
        {form === 'create' && <><Field label="Guest label" value={label} maxLength={80} onChange={(e) => setLabel(e.target.value)} />
          <label className="block text-sm text-muted">Device<select className="mt-2 block w-full rounded-lg bg-bg p-3 text-fg" value={device} onChange={(e) => setDevice(e.target.value)}>{eligible.map((d) => <option key={d.id} value={d.id}>{d.name}</option>)}</select></label></>}
        <p className="text-xs leading-relaxed text-muted">Root terminal grants full device authority, including persistent changes. Touch and keyboard can operate other apps and their settings. Direct LAN control remains unrestricted unless you enabled the device’s Relay-only policy.</p>
        <div><div className="mb-3 flex items-center justify-between"><p className="text-sm text-muted">Permissions · {permissions.length} selected</p><Button size="sm" onClick={() => setPermissions(['screen.view'])}>View only</Button></div>
          <div className="max-h-72 space-y-4 overflow-y-auto pr-2">{Array.from(new Set(GUEST_PERMISSIONS.map((p) => p.group))).map((group) => <fieldset key={group}><legend className="mb-2 text-xs font-medium text-muted">{group}</legend><div className="space-y-2">{GUEST_PERMISSIONS.filter((p) => p.group === group).map((p) => {
            const initial = ['screen.view', 'input.touch', 'input.keyboard', 'input.button.home', 'input.button.lock', 'input.button.volume', 'input.button.system_ui'].includes(p.id)
            const supported = initial || devices.find((d) => d.id === device)?.features.includes('guest.operations_v1')
            return <label key={p.id} className="flex min-h-10 items-center gap-3 rounded-lg bg-surface-2 px-3 text-sm"><input type="checkbox" checked={permissions.includes(p.id)} disabled={!supported && !permissions.includes(p.id)} onChange={(e) => setPermissions(e.target.checked ? [...permissions, p.id] : permissions.filter((id) => id !== p.id))} />{p.label}{!supported && <span className="text-xs text-muted">Device update required</span>}</label>
          })}</div></fieldset>)}</div></div>
        {form === 'create' && <><label className="block text-sm text-muted">Access lifetime<select className="mt-2 block w-full rounded-lg bg-bg p-3 text-fg" value={ttl} onChange={(e) => setTTL(Number(e.target.value))}>{[300, 900, 3600, 14400, 86400].map((s) => <option key={s} value={s}>{s < 3600 ? `${s / 60} minutes` : `${s / 3600} hours`}</option>)}</select></label>
          <label className="flex items-start gap-3 text-sm text-muted"><input type="checkbox" checked={direct} onChange={(e) => setDirect(e.target.checked)} />Allow a direct connection. This may reveal network addresses to the guest. Off uses TURN only.</label></>}
        {error && <p role="alert" className="text-sm text-danger">{error}</p>}
        <div className="flex justify-end gap-2"><Button disabled={!!busy} onClick={() => { setForm(null); setError('') }}>Cancel</Button><Button variant="primary" loading={busy === 'form'} disabled={!permissions.length || (form === 'create' && !device)} onClick={() => void save()}>{form === 'create' ? 'Create link' : 'Save permissions'}</Button></div>
      </div>}
    </Modal>
    <Modal open={confirmAll} onOpenChange={(open) => !busy && setConfirmAll(open)} title="Revoke all guest access?" description="Every guest connection will close and every outstanding invitation will stop working.">
      <div className="flex justify-end gap-2"><Button disabled={!!busy} onClick={() => setConfirmAll(false)}>Cancel</Button><Button variant="danger-solid" loading={busy === 'all'} onClick={() => void revoke()}>Revoke all</Button></div>
    </Modal>
  </>
}
