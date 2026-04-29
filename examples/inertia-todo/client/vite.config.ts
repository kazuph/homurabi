import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';
import { fileURLToPath } from 'node:url';
import { dirname, resolve } from 'node:path';

const __dirname = dirname(fileURLToPath(import.meta.url));

export default defineConfig({
  plugins: [react()],
  build: {
    outDir: resolve(__dirname, '..', 'public', 'assets'),
    emptyOutDir: true,
    cssCodeSplit: false,
    rollupOptions: {
      input: resolve(__dirname, 'src', 'main.tsx'),
      output: {
        entryFileNames: 'inertia-app.js',
        chunkFileNames: 'inertia-app-[name].js',
        assetFileNames: (info) => {
          if (info.name?.endsWith('.css')) return 'inertia-app.css';
          return 'inertia-app-[name][extname]';
        },
      },
    },
  },
});
