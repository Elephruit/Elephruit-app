// Lets Node run the app's TypeScript directly (`node --import ./scripts/ts-import.mjs …`).
// Node strips types natively but refuses the extensionless relative imports the
// Vite-built source uses everywhere; the hook retries those with `.ts` appended.
import { registerHooks } from 'node:module'

registerHooks({
  resolve(specifier, context, nextResolve) {
    try {
      return nextResolve(specifier, context)
    } catch (error) {
      const relative = specifier.startsWith('./') || specifier.startsWith('../')
      if (relative && !specifier.endsWith('.ts')) {
        return nextResolve(`${specifier}.ts`, context)
      }
      throw error
    }
  },
})
