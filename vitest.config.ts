import { defineConfig } from 'vitest/config';
import { resolve } from 'path';

export default defineConfig({
  test: {
    globals: true,
    environment: 'node',
    include: ['packages/*/test/**/*.test.ts'],
    exclude: ['**/node_modules/**', '**/dist/**', 'packages/chat-web/**'],
    coverage: {
      provider: 'v8',
      reporter: ['text', 'json', 'html'],
      include: ['packages/*/src/**/*.ts'],
      exclude: [
        'packages/*/src/**/*.d.ts',
        'packages/*/src/index.ts',
        '**/types/**'
      ],
      thresholds: {
        lines: 80,
        functions: 80,
        branches: 75,
        statements: 80
      }
    },
    testTimeout: 30000,
    hookTimeout: 10000,
    reporters: ['verbose'],
    pool: 'threads',
    poolOptions: {
      threads: {
        singleThread: false
      }
    }
  },
  resolve: {
    alias: {
      '@tron/core': resolve(__dirname, 'packages/core/src'),
      '@tron/server': resolve(__dirname, 'packages/server/src'),
      '@tron/agent': resolve(__dirname, 'packages/agent/src'),
      '@tron/agent/browser': resolve(__dirname, 'packages/agent/src/browser.ts'),
      '@tron/tui': resolve(__dirname, 'packages/tui/src')
    }
  },
  esbuild: {
    target: 'node20'
  }
});
