/// Config for the Firestore rules tests only. They require the emulator
/// suite to be running (`npm run emulators` in another terminal), same
/// contract as `npm run smoke`. Invoked via `npm run test:rules`.

import { defineConfig } from 'vitest/config'

export default defineConfig({
  test: {
    include: ['tests/rules/**/*.test.ts'],
    testTimeout: 15_000,
    hookTimeout: 20_000,
  },
})
