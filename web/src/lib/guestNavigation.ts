export const GUEST_TOOLS = [
  { id: 'console', label: 'Console', description: 'Device, applications and input', prefixes: ['device.', 'clipboard.', 'apps.', 'input.text', 'input.pointer', 'automation.', 'screen.snapshot'] },
  { id: 'sound', label: 'Sound', description: 'Playback, microphone and Talk', prefixes: ['audio.', 'talk.'] },
  { id: 'camera', label: 'Camera', description: 'Live camera and captures', prefixes: ['camera.'] },
  { id: 'media', label: 'Media', description: 'Photos and videos', prefixes: ['media.'] },
  { id: 'files', label: 'Files', description: 'Device exchange folder', prefixes: ['files.'] },
  { id: 'system', label: 'System', description: 'Packages and tweaks', prefixes: ['system.'] },
  { id: 'terminal', label: 'Terminal', description: 'Root shell', prefixes: ['terminal.'] },
] as const

export type GuestTool = typeof GUEST_TOOLS[number]['id']

// Navigation describes existing scoped tools; it never adds authority. A lone
// capture.download right has no source to export without a recording right.
export function guestTools(permissions: readonly string[]) {
  return GUEST_TOOLS.filter(tool => permissions.some(right => tool.prefixes.some(prefix => right.startsWith(prefix))))
}

export function guestTime(seconds: number) {
  const remaining = Math.max(0, Math.ceil(seconds))
  const hours = Math.floor(remaining / 3600)
  const minutes = Math.floor(remaining / 60) % 60
  const tail = String(remaining % 60).padStart(2, '0')
  return hours ? `${hours}:${String(minutes).padStart(2, '0')}:${tail}` : `${minutes}:${tail}`
}
