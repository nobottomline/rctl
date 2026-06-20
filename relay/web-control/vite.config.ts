import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'
import tailwindcss from '@tailwindcss/vite'
import { viteSingleFile } from 'vite-plugin-singlefile'

// The control page must be ONE self-contained file: the device serves it from
// /var/mobile/rctl/index.html (HttpStreamServer) and the relay from WebDir, and
// neither serves separate JS/CSS assets. viteSingleFile inlines everything.
export default defineConfig({
  base: './',
  plugins: [react(), tailwindcss(), viteSingleFile()],
  build: { outDir: 'dist', emptyOutDir: true, assetsInlineLimit: 100000000, cssCodeSplit: false },
})
