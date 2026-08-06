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
})
