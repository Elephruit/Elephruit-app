import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { describe, expect, it } from 'vitest'

/// Accessibility guarantees that live in CSS rather than in a component, pinned
/// so a refactor cannot silently drop them. The polish plan rewrites large parts
/// of base.css; the reduced-motion contract must survive every pass.
describe('ui css hygiene', () => {
  const uiDir = dirname(fileURLToPath(import.meta.url))
  const css = ['tokens.css', 'base.css'].map((file) => readFileSync(join(uiDir, file), 'utf8')).join('\n')

  it('ships a global prefers-reduced-motion override', () => {
    expect(css).toMatch(/@media\s*\(prefers-reduced-motion:\s*reduce\)/)
  })

  it('zeroes both animation and transition durations under reduced motion', () => {
    const start = css.search(/@media\s*\(prefers-reduced-motion:\s*reduce\)/)
    const block = css.slice(start, start + 600)
    expect(block).toMatch(/animation-duration:\s*0\.01ms\s*!important/)
    expect(block).toMatch(/transition-duration:\s*0\.01ms\s*!important/)
  })

  it('keeps the single focus-visible treatment', () => {
    expect(css).toMatch(/:focus-visible\s*{[^}]*outline:/)
  })

  it('defines the surface family in both appearances, dark with its own values', () => {
    const tokens = readFileSync(join(uiDir, 'tokens.css'), 'utf8')
    const darkStart = tokens.indexOf(":root[data-theme='dark']")
    expect(darkStart).toBeGreaterThan(0)
    const light = tokens.slice(0, darkStart)
    const dark = tokens.slice(darkStart)

    for (const token of [
      '--color-canvas:',
      '--color-surface:',
      '--color-surface-subtle:',
      '--color-surface-hover:',
      '--color-surface-selected:',
      '--color-note-surface:',
      '--color-backdrop:',
    ]) {
      expect(light, `${token} missing from light`).toContain(token)
      expect(dark, `${token} missing from dark`).toContain(token)
    }

    // Migration aliases resolve through the family, so dark mode must not
    // pin --color-background to a literal that bypasses --color-canvas.
    expect(light).toContain('--color-background: var(--color-canvas)')
    expect(dark).not.toMatch(/--color-background:\s*#/)
  })

  it('defines the motion vocabulary the polish plan animates with', () => {
    const tokens = readFileSync(join(uiDir, 'tokens.css'), 'utf8')
    for (const token of [
      '--duration-instant: 80ms',
      '--duration-fast: 140ms',
      '--duration-base: 200ms',
      '--duration-expand: 280ms',
      '--duration-insert: 360ms',
      '--ease-standard: cubic-bezier(0.2, 0, 0, 1)',
      '--ease-emphasized: cubic-bezier(0.2, 0.8, 0.2, 1)',
    ]) {
      expect(tokens).toContain(token)
    }
  })
})
