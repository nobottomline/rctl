import { defineConfig } from 'vite'
import { readFileSync } from 'node:fs'
import react from '@vitejs/plugin-react'
import tailwindcss from '@tailwindcss/vite'
import { viteSingleFile } from 'vite-plugin-singlefile'

// The control page must be ONE self-contained file: the device serves it from
// /var/mobile/rctl/index.html (HttpStreamServer) and the relay from WebDir, and
// neither serves separate JS/CSS assets. viteSingleFile inlines everything.

// opus-decoder embeds its WASM as String.raw`dynEncode...` literals full of raw
// high/control/NUL bytes. They build fine normally but corrupt the single-file HTML
// (UTF-8 reparse + the device's byte-length serving). We never decode them: the WASM
// is supplied separately as base64 and injected via OpusDecoder.module (see
// lib/audio.ts), so we strip the literals at build time for a clean ASCII bundle.
function stripOpusDynEncode() {
  return {
    name: 'strip-opus-dynencode',
    enforce: 'pre' as const,
    transform(code: string, id: string) {
      if (
        id.includes('opus-decoder/src/EmscriptenWasm') ||
        id.includes('common/src/WASMAudioDecoderCommon')
      ) {
        const out = code.replace(/String\.raw`dynEncode[^`]*`/g, '""')
        if (out !== code) return { code: out, map: null }
      }
      return null
    },
  }
}

const control = readFileSync(new URL('../control', import.meta.url), 'utf8')
const productVersion = control.match(/^Version:\s*(\S+)/m)?.[1] || 'dev'

export default defineConfig({
  base: './',
  plugins: [stripOpusDynEncode(), react(), tailwindcss(), viteSingleFile()],
  build: { outDir: 'dist', emptyOutDir: true, assetsInlineLimit: 100000000, cssCodeSplit: false },
  // Force ASCII output so no stray non-ASCII byte can corrupt the inlined HTML.
  esbuild: { charset: 'ascii' },
  define: {
    __RCTL_BROWSER_VERSION__: JSON.stringify(productVersion),
    __RCTL_PROTOCOL_MAJOR__: '1',
    __RCTL_PROTOCOL_MINOR__: '0',
  },
})
