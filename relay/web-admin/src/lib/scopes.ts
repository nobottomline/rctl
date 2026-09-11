import type { ControllerScope } from '../types'

// Human labels for controller permissions, shared by the pairing form and the
// controller detail card. Elevated scopes are excluded from the Everyday preset.
export const SCOPE_OPTIONS: Array<{ id: ControllerScope; label: string; elevated?: boolean }> = [
  { id: 'screen.view', label: 'View screen' },
  { id: 'device.control', label: 'Control device' },
  { id: 'audio.listen', label: 'Listen to audio' },
  { id: 'microphone.talk', label: 'Use Talk' },
  { id: 'camera', label: 'Use cameras' },
  { id: 'files.read', label: 'Read files' },
  { id: 'files.write', label: 'Change files' },
  { id: 'terminal', label: 'Open terminal', elevated: true },
  { id: 'device.update', label: 'Update device', elevated: true },
  { id: 'system.destructive', label: 'Destructive actions', elevated: true },
]

const byId = new Map(SCOPE_OPTIONS.map((scope) => [scope.id, scope]))

export function scopeLabel(scope: ControllerScope | string): string {
  return byId.get(scope as ControllerScope)?.label ?? scope
}

export function scopeElevated(scope: ControllerScope | string): boolean {
  return byId.get(scope as ControllerScope)?.elevated ?? false
}
