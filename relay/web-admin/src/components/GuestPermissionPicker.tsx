import { useState } from 'react'
import { Search } from 'lucide-react'
import { GUEST_PERMISSIONS, type GuestPermission } from '../lib/guestPermissions.generated'
import { cn } from '../lib/cn'
import { Button } from './ui/Button'
import { Checkbox } from './ui/Checkbox'
import { Field } from './ui/Field'

const groups = [...new Set(GUEST_PERMISSIONS.map((permission) => permission.group))]
const basic = new Set<string>(['screen.view', 'input.touch', 'input.keyboard', 'input.button.home', 'input.button.lock', 'input.button.volume', 'input.button.system_ui'])

export function GuestPermissionPicker({ value, onChange, operationsSupported, disabled }: {
  value: GuestPermission[]
  onChange: (value: GuestPermission[]) => void
  operationsSupported: boolean
  disabled: boolean
}) {
  const [group, setGroup] = useState<string>('Screen')
  const [query, setQuery] = useState('')
  const [selectedOnly, setSelectedOnly] = useState(false)
  const search = query.trim().toLowerCase()
  const visible = GUEST_PERMISSIONS.filter((permission) =>
    selectedOnly ? value.includes(permission.id) : search
      ? `${permission.label} ${permission.group}`.toLowerCase().includes(search)
      : permission.group === group,
  )
  return <section aria-label="Guest permissions" className="min-w-0 space-y-4">
    <div className="flex flex-wrap items-center justify-between gap-2">
      <div><h2 className="text-sm font-semibold text-fg">Permissions</h2><p className="mt-1 text-xs text-muted" aria-live="polite">{value.length} of {GUEST_PERMISSIONS.length} selected</p></div>
      <Button type="button" size="sm" disabled={disabled} onClick={() => onChange(['screen.view'])}>View only</Button>
    </div>
    <Field aria-label="Search permissions" placeholder="Find a permission…" type="search" icon={Search} value={query} disabled={disabled} onChange={(event) => { setQuery(event.target.value); setSelectedOnly(false) }} />
    <nav aria-label="Permission categories" className="grid grid-cols-3 gap-1.5 sm:grid-cols-4 lg:grid-cols-3">
      {groups.map((category) => {
        const items = GUEST_PERMISSIONS.filter((permission) => permission.group === category)
        const count = items.filter((permission) => value.includes(permission.id)).length
        const active = !search && !selectedOnly && group === category
        return <button key={category} type="button" disabled={disabled} aria-pressed={active} onClick={() => { setGroup(category); setQuery(''); setSelectedOnly(false) }}
          className={cn('flex min-h-9 items-center justify-between gap-1 rounded-lg px-2.5 py-2 text-left text-xs font-medium transition-colors disabled:opacity-55', active ? 'bg-signal/12 text-signal ring-1 ring-inset ring-signal/30' : 'text-muted hover:bg-surface-2 hover:text-fg')}>
          <span>{category}</span><span className={cn('font-mono text-[10px] tabular-nums', count ? 'text-signal' : 'text-faint')}>{count}/{items.length}</span>
        </button>
      })}
    </nav>
    <div className="flex items-center justify-between border-t border-line pt-4">
      <h3 className="text-[13px] font-medium text-fg-dim">{selectedOnly ? 'Selected permissions' : search ? 'Search results' : group}</h3>
      <button type="button" disabled={disabled} aria-pressed={selectedOnly} className="text-xs font-medium text-signal disabled:opacity-55" onClick={() => { setSelectedOnly(!selectedOnly); setQuery('') }}>{selectedOnly ? 'Browse categories' : 'Review selected'}</button>
    </div>
    <div className="divide-y divide-line rounded-xl border border-line bg-bg/25">
      {visible.map((permission) => {
        const supported = basic.has(permission.id) || operationsSupported
        const checked = value.includes(permission.id)
        return <label key={permission.id} className={cn('flex min-h-12 cursor-pointer items-center gap-3 px-3.5 py-3 text-sm transition-colors first:rounded-t-xl last:rounded-b-xl hover:bg-surface-2/60', checked && 'bg-signal/5', (!supported || disabled) && 'text-muted')}>
          <Checkbox checked={checked} disabled={disabled || (!supported && !checked)} onCheckedChange={(next) => onChange(next === true ? [...value, permission.id] : value.filter((id) => id !== permission.id))} />
          <span className="min-w-0 leading-snug">{permission.label}{!supported && <span className="mt-1 block text-xs text-muted">Device update required</span>}{(search || selectedOnly) && <span className="mt-1 block text-xs text-muted">{permission.group}</span>}</span>
        </label>
      })}
      {!visible.length && <p className="px-4 py-6 text-sm text-muted">{selectedOnly ? 'No permissions selected.' : 'No matching permissions. Try another search.'}</p>}
    </div>
    {!value.length && <p role="alert" className="text-xs text-danger">Select at least one permission to continue.</p>}
    {value.includes('terminal.root') && <p className="rounded-lg bg-danger/10 px-3 py-2 text-xs leading-relaxed text-danger">Root terminal grants full device authority, including persistent changes.</p>}
    {(value.includes('input.touch') || value.includes('input.keyboard') || value.includes('input.text')) && <p className="text-xs leading-relaxed text-muted">Input access can operate other apps and change their settings.</p>}
  </section>
}
