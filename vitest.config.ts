import { defineConfig } from 'vitest/config';
import { resolve } from 'path';

export default defineConfig({
  test: {
    globals: true,
    environment: 'node',
    include: [
      'packages/*/src/**/*.test.ts',      // Co-located tests
      'packages/*/src/**/__tests__/*.test.ts',  // Tests in __tests__ folders
    ],
    exclude: ['**/node_modules/**', '**/dist/**', 'packages/chat-web/**'],
    coverage: {
      provider: 'v8',
      reporter: ['text', 'json', 'html'],
      reportsDirectory: '.coverage', // Renamed to avoid conflict with Python imports
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
      '@tron/agent': resolve(__dirname, 'packages/agent/src'),
      '@tron/agent/browser': resolve(__dirname, 'packages/agent/src/browser.ts'),
      '@tron/tui': resolve(__dirname, 'packages/tui/src'),
      // Internal agent package aliases
      '@core': resolve(__dirname, 'packages/agent/src/core'),
      '@infrastructure': resolve(__dirname, 'packages/agent/src/infrastructure'),
      '@llm': resolve(__dirname, 'packages/agent/src/llm'),
      '@context': resolve(__dirname, 'packages/agent/src/context'),
      '@runtime': resolve(__dirname, 'packages/agent/src/runtime'),
      '@capabilities': resolve(__dirname, 'packages/agent/src/capabilities'),
      '@interface': resolve(__dirname, 'packages/agent/src/interface'),
      '@platform': resolve(__dirname, 'packages/agent/src/platform'),
    }
  },
  esbuild: {
    target: 'node20'
  }
});
