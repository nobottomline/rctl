import { apiJSON } from './rctl'

const globals = window as unknown as Record<string, unknown>

export const browserCompatibility = {
  version: __RCTL_BROWSER_VERSION__,
  protocol: { major: __RCTL_PROTOCOL_MAJOR__, minor: __RCTL_PROTOCOL_MINOR__ },
  relay: {
    version: String(globals.RCTL_RELAY_VERSION || ''),
    protocol: {
      major: Number(globals.RCTL_RELAY_PROTOCOL_MAJOR || 0),
      minor: Number(globals.RCTL_RELAY_PROTOCOL_MINOR || 0),
    },
  },
}

export interface DeviceCapabilities {
  product: string
  component: 'daemon'
  daemon: { version: string }
  browser: { version: string }
  protocol: { major: number; minor: number }
  features: string[]
}

export function loadDeviceCapabilities(): Promise<DeviceCapabilities | null> {
  return apiJSON<DeviceCapabilities>('/v1/capabilities')
}

export function compatibilityWarning(device: DeviceCapabilities): string {
  if (device.protocol.major !== browserCompatibility.protocol.major) {
    return `Incompatible protocol: browser ${browserCompatibility.protocol.major}, device ${device.protocol.major}`
  }
  const relayMajor = browserCompatibility.relay.protocol.major
  if (relayMajor && relayMajor !== browserCompatibility.protocol.major) {
    return `Incompatible relay protocol: browser ${browserCompatibility.protocol.major}, relay ${relayMajor}`
  }
  if (device.protocol.minor !== browserCompatibility.protocol.minor) {
    return `Protocol feature level differs: browser ${browserCompatibility.protocol.minor}, device ${device.protocol.minor}`
  }
  if (device.daemon.version !== browserCompatibility.version) {
    return `Version differs: browser ${browserCompatibility.version}, device ${device.daemon.version}`
  }
  return ''
}
