/// The appearance preference and the data-theme attribute it drives. tokens.css
/// is light-only until the dark semantic layer ships; the mechanism lands first
/// so that adding dark mode is a stylesheet change, not a plumbing change.

export type ThemePreference = 'light' | 'dark' | 'system'

const STORAGE_KEY = 'elephruit.theme'

export function themePreference(): ThemePreference {
  const stored = localStorage.getItem(STORAGE_KEY)
  return stored === 'light' || stored === 'dark' ? stored : 'system'
}

export function setThemePreference(preference: ThemePreference): void {
  if (preference === 'system') localStorage.removeItem(STORAGE_KEY)
  else localStorage.setItem(STORAGE_KEY, preference)
  applyTheme()
}

function resolvedTheme(): 'light' | 'dark' {
  const preference = themePreference()
  if (preference !== 'system') return preference
  return window.matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light'
}

function applyTheme(): void {
  document.documentElement.dataset.theme = resolvedTheme()
}

/// Call once before first render. While the preference is 'system', the
/// attribute keeps following the OS.
export function initTheme(): void {
  applyTheme()
  window.matchMedia('(prefers-color-scheme: dark)').addEventListener('change', applyTheme)
}
