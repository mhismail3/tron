import { defineConfig } from 'vitest/config';
export default defineConfig({
    test: {
        globals: true,
        include: ['test/**/*.test.ts', 'test/**/*.test.tsx'],
        exclude: ['**/node_modules/**', '**/dist/**'],
        testTimeout: 10000,
    },
});
//# sourceMappingURL=vitest.config.js.map