// Relay injects these as window globals; on the device-local path they're absent.
const proxyBase = (window as { RCTL_PROXY_BASE?: string }).RCTL_PROXY_BASE || ''
const deviceId = (window as { RCTL_RELAY_DEVICE_ID?: string }).RCTL_RELAY_DEVICE_ID || ''
const relayMode = !!proxyBase

export default function App() {
  return (
    <div className="grid min-h-svh place-items-center p-6 text-center">
      <div>
        <div className="text-lg font-semibold tracking-tight text-fg">rctl · control</div>
        <div className="mt-1 text-[13px] text-muted">
          {relayMode ? `relay mode · ${deviceId.slice(0, 8)}…` : 'device-local mode'}
        </div>
        <div className="mt-4 text-[12px] text-faint">web-control scaffold — Vite build pipeline OK</div>
      </div>
    </div>
  )
}
