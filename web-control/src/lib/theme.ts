// Light/dark chrome theming, mirroring the relay admin: a `warm` class on the
// root flips the CSS color tokens (the .warm block in index.css). The video stage
// stays black regardless -- only the chrome (panels, sheets) themes.
export type Theme = 'dark' | 'warm'

const KEY = 'rctl-control-theme'

export function getStoredTheme(): Theme {
  try {
    return localStorage.getItem(KEY) === 'warm' ? 'warm' : 'dark'
  } catch {
    return 'dark'
  }
}

export function applyTheme(theme: Theme): void {
  const root = document.documentElement
  root.classList.toggle('warm', theme === 'warm')
  root.style.colorScheme = theme === 'warm' ? 'light' : 'dark'
  try {
    localStorage.setItem(KEY, theme)
  } catch {
    /* storage may be unavailable */
  }
}
