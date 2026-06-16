import { StrictMode } from 'react'
import { createRoot } from 'react-dom/client'
import '@fontsource-variable/hanken-grotesk'
import '@fontsource/geist-mono/400.css'
import '@fontsource/geist-mono/500.css'
import './index.css'
import App from './App'
import { Toaster } from 'sonner'

const root = document.getElementById('root')
if (!root) throw new Error('#root not found')

createRoot(root).render(
  <StrictMode>
    <App />
    <Toaster
      position="bottom-right"
      gap={10}
      toastOptions={{
        style: {
          background: 'var(--color-elevated)',
          border: '1px solid var(--color-line-2)',
          color: 'var(--color-fg)',
          borderRadius: '12px',
        },
      }}
    />
  </StrictMode>,
)
