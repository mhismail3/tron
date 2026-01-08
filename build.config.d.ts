/**
 * @fileoverview Tron Build Configuration
 *
 * Defines build parameters for all three tiers:
 * - beta: Development builds, hot-reload, full debugging
 * - prod: Personal production builds, optimized, auto-server
 * - public: Public release builds, stable features only
 */
export interface BuildConfig {
    /** Build tier name */
    tier: 'beta' | 'prod' | 'public';
    /** Human-readable description */
    description: string;
    /** Install location for built binaries */
    installPath: string;
    /** Data directory */
    dataDir: string;
    /** Node environment */
    nodeEnv: 'development' | 'production';
    /** Enable source maps */
    sourceMaps: boolean;
    /** Minify output */
    minify: boolean;
    /** Include development dependencies */
    includeDev: boolean;
    /** Auto-start server on login */
    autoStartServer: boolean;
    /** Service identifier */
    serviceId: string;
    /** Binary name */
    binaryName: string;
    /** Feature tier flag */
    featureTier: string;
}
export declare const BUILD_CONFIGS: Record<string, BuildConfig>;
export default BUILD_CONFIGS;
//# sourceMappingURL=build.config.d.ts.map