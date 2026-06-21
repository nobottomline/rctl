import { StrictMode } from 'react'
import { createRoot } from 'react-dom/client'
import './index.css'
import App from './App'
import { applyTheme, getStoredTheme } from './lib/theme'

applyTheme(getStoredTheme()) // before first paint, so no theme flash

const root = document.getElementById('root')
if (!root) throw new Error('#root not found')
createRoot(root).render(
  <StrictMode>
    <App />
  </StrictMode>,
)
