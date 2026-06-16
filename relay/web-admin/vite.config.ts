import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'
import tailwindcss from '@tailwindcss/vite'

// The admin SPA is served by the Go relay under /admin/ and embedded into the
// binary via go:embed; the production build is written straight into the Go
// package (internal/relay/webdist) so a single binary ships the whole UI.
export default defineConfig({
  base: '/admin/',
  plugins: [react(), tailwindcss()],
  build: {
    outDir: '../internal/relay/webdist',
    emptyOutDir: true,
    chunkSizeWarningLimit: 1400,
  },
  server: {
    proxy: {
      // `npm run dev`: forward API + tunnel routes to a locally running relay.
      '/api': 'http://127.0.0.1:8081',
      '/control': 'http://127.0.0.1:8081',
      '/healthz': 'http://127.0.0.1:8081',
    },
  },
})
