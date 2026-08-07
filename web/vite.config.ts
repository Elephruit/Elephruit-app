import { defineConfig, loadEnv } from 'vite'
import react from '@vitejs/plugin-react'
import { productionConfigurationError } from './src/buildEnvironment.js'

// https://vite.dev/config/
export default defineConfig(({ command, mode }) => {
  const env = loadEnv(mode, process.cwd(), 'VITE_')
  if (command === 'build') {
    const error = productionConfigurationError(env)
    if (error) throw new Error(error)
  }

  return {
    plugins: [react()],
    // Vite does not read PORT on its own, and several worktrees of this repo are
    // routinely open at once — each wanting 5173. Honouring it here means a
    // second checkout can be told where to listen instead of silently landing on
    // whatever port happened to be free.
    server: process.env.PORT ? { port: Number(process.env.PORT) } : undefined,
  }
})
