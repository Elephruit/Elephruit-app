import { readFileSync, readdirSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { describe, expect, it } from 'vitest'

/// The domain layer is pure TypeScript. The moment it imports Firebase or the
/// Anthropic SDK, it stops being testable without a network and stops being
/// portable to whatever the next client is — the same layering the Mac app
/// enforces between ElephruitCore and everything above it.
describe('domain hygiene', () => {
  it('imports no SDK anywhere under src/domain', () => {
    const domainDir = dirname(fileURLToPath(import.meta.url))
    const offenders: string[] = []

    for (const file of readdirSync(domainDir)) {
      if (!file.endsWith('.ts')) continue
      const source = readFileSync(join(domainDir, file), 'utf8')
      if (/from\s+['"](firebase|@firebase|@anthropic-ai)/.test(source)) {
        offenders.push(file)
      }
      if (/import\s+['"](firebase|@firebase|@anthropic-ai)/.test(source)) {
        offenders.push(file)
      }
    }

    expect(offenders).toEqual([])
  })
})
