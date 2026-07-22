import { defineConfig } from 'vite';
import solid from 'vite-plugin-solid';

export default defineConfig({
  // relative base so the built playground works wherever it is mounted
  // (locally at /play/, on GitHub Pages at /<repo>/play/)
  base: './',
  plugins: [solid()],
  build: { target: 'es2022', chunkSizeWarningLimit: 4000 },
  worker: { format: 'es' },
});
