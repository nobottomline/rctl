import { StrictMode } from 'react'
import { createRoot } from 'react-dom/client'
import './index.css'
import App from './App'
import GuestControl from './GuestControl'
import { GUEST_ACCESS, bootstrapLAN } from './lib/rctl'
import { applyTheme, getStoredTheme } from './lib/theme'

applyTheme(getStoredTheme()) // before first paint, so no theme flash

const root = document.getElementById('root')
if (!root) throw new Error('#root not found')

// Device-local mode must hold the LAN token before the first API request
// fires; relay mode bootstraps through its own authenticated proxy.
bootstrapLAN().then(() => {
  createRoot(root).render(
    <StrictMode>
      {GUEST_ACCESS ? <GuestControl /> : <App />}
    </StrictMode>,
  )
})
