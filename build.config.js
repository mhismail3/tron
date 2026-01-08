/**
 * @fileoverview Tron Build Configuration
 *
 * Defines build parameters for all three tiers:
 * - beta: Development builds, hot-reload, full debugging
 * - prod: Personal production builds, optimized, auto-server
 * - public: Public release builds, stable features only
 */
export const BUILD_CONFIGS = {
    beta: {
        tier: 'beta',
        description: 'Development build with hot-reload and full debugging',
        installPath: '', // Uses workspace directly
        dataDir: '~/.tron',
        nodeEnv: 'development',
        sourceMaps: true,
        minify: false,
        includeDev: true,
        autoStartServer: false,
        serviceId: 'com.tron.beta',
        binaryName: 'tron-beta',
        featureTier: 'beta',
    },
    prod: {
        tier: 'prod',
        description: 'Personal production build with all features',
        installPath: '~/.tron/install/prod',
        dataDir: '~/.tron',
        nodeEnv: 'production',
        sourceMaps: true, // Keep for debugging production issues
        minify: true,
        includeDev: false,
        autoStartServer: true,
        serviceId: 'com.tron.server',
        binaryName: 'tron',
        featureTier: 'prod',
    },
    public: {
        tier: 'public',
        description: 'Public release build with stable features only',
        installPath: '/usr/local/lib/tron',
        dataDir: '~/.tron',
        nodeEnv: 'production',
        sourceMaps: false,
        minify: true,
        includeDev: false,
        autoStartServer: true,
        serviceId: 'com.tron.server',
        binaryName: 'tron',
        featureTier: 'public',
    },
};
export default BUILD_CONFIGS;
//# sourceMappingURL=build.config.js.map