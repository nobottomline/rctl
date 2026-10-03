import { StrictMode } from 'react'
import { createRoot } from 'react-dom/client'
import './index.css'
import App from './App'
import GuestControl from './GuestControl'
import { GUEST_ACCESS } from './lib/rctl'
import { applyTheme, getStoredTheme } from './lib/theme'

applyTheme(getStoredTheme()) // before first paint, so no theme flash

const root = document.getElementById('root')
if (!root) throw new Error('#root not found')
createRoot(root).render(
  <StrictMode>
    {GUEST_ACCESS ? <GuestControl /> : <App />}
  </StrictMode>,
)
