/// Pins `npm test` to the colocated unit tests under src/, which run pure —
/// no DOM, no emulators. The rules tests under tests/rules need a live
/// Firestore emulator and run separately via `npm run test:rules`.

import { defineConfig } from 'vitest/config'

export default defineConfig({
  test: {
    include: ['src/**/*.test.{ts,tsx}'],
  },
})
