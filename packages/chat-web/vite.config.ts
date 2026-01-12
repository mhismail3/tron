import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';
import { resolve } from 'path';

export default defineConfig({
  plugins: [react()],
  root: 'src',
  build: {
    outDir: '../dist',
    emptyOutDir: true,
  },
  server: {
    port: 3000,
    host: '0.0.0.0', // Allow Tailscale/network access
    proxy: {
      '/ws': {
        target: 'ws://localhost:8080',
        ws: true,
      },
      '/api': {
        target: 'http://localhost:8080',
        changeOrigin: true,
      },
    },
  },
  resolve: {
    alias: {
      '@': resolve(__dirname, 'src'),
      // Resolve workspace packages - point to built dist directories
      '@tron/core': resolve(__dirname, '../core/dist'),
      '@tron/core/browser': resolve(__dirname, '../core/dist/browser.js'),
    },
  },
  // Ensure Vite can resolve workspace dependencies
  optimizeDeps: {
    include: ['@tron/core'],
  },
});
