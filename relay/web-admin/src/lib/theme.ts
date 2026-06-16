export type Theme = 'dark' | 'warm'

const KEY = 'rctl-theme'

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
