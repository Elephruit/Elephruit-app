import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'

// https://vite.dev/config/
export default defineConfig({
  plugins: [react()],
  // Vite does not read PORT on its own, and several worktrees of this repo are
  // routinely open at once — each wanting 5173. Honouring it here means a
  // second checkout can be told where to listen instead of silently landing on
  // whatever port happened to be free.
  server: process.env.PORT ? { port: Number(process.env.PORT) } : undefined,
})
