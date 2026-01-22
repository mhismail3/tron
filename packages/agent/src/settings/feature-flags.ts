/**
 * @fileoverview Feature Flags System
 *
 * Controls which features are available in different build tiers:
 * - beta: All features enabled (development)
 * - prod: All features + experimental (personal production)
 * - public: Stable features only (public release)
 */

// =============================================================================
// Types
// =============================================================================

export type BuildTier = 'beta' | 'prod' | 'public';

export interface FeatureFlags {
  /** Enable experimental model switching */
  experimentalModelSwitcher: boolean;
  /** Enable advanced memory features */
  experimentalMemory: boolean;
  /** Enable plugin system */
  experimentalPlugins: boolean;
  /** Enable multi-agent orchestration */
  experimentalMultiAgent: boolean;
  /** Enable voice input/output */
  experimentalVoice: boolean;
  /** Enable debug toolbar in TUI */
  debugToolbar: boolean;
  /** Enable performance profiling */
  performanceProfiling: boolean;
  /** Enable hot-reload in development */
  hotReload: boolean;
}

// =============================================================================
// Feature Definitions
// =============================================================================

const BETA_FEATURES: FeatureFlags = {
  experimentalModelSwitcher: true,
  experimentalMemory: true,
  experimentalPlugins: true,
  experimentalMultiAgent: true,
  experimentalVoice: true,
  debugToolbar: true,
  performanceProfiling: true,
  hotReload: true,
};

const PROD_FEATURES: FeatureFlags = {
  experimentalModelSwitcher: true,
  experimentalMemory: true,
  experimentalPlugins: true,
  experimentalMultiAgent: true,
  experimentalVoice: true,
  debugToolbar: false, // Disabled in prod
  performanceProfiling: false, // Disabled in prod
  hotReload: false, // Disabled in prod
};

const PUBLIC_FEATURES: FeatureFlags = {
  experimentalModelSwitcher: false, // Stable model selection only
  experimentalMemory: false, // Standard memory only
  experimentalPlugins: false, // No plugins in public
  experimentalMultiAgent: false, // Single agent only
  experimentalVoice: false, // No voice in public
  debugToolbar: false,
  performanceProfiling: false,
  hotReload: false,
};

// =============================================================================
// Runtime Detection
// =============================================================================

/**
 * Detect the current build tier from environment
 */
export function detectBuildTier(): BuildTier {
  // Explicit tier override
  const tierOverride = process.env.TRON_BUILD_TIER as BuildTier | undefined;
  if (tierOverride && ['beta', 'prod', 'public'].includes(tierOverride)) {
    return tierOverride;
  }

  // Detect based on NODE_ENV and other signals
  const nodeEnv = process.env.NODE_ENV;
  const isDev = nodeEnv === 'development' || process.env.TRON_DEV === '1';
  const isPublic = process.env.TRON_PUBLIC === '1';

  if (isPublic) return 'public';
  if (isDev) return 'beta';
  return 'prod';
}

/**
 * Get feature flags for a specific build tier
 */
export function getFeatureFlagsForTier(tier: BuildTier): FeatureFlags {
  switch (tier) {
    case 'beta':
      return { ...BETA_FEATURES };
    case 'prod':
      return { ...PROD_FEATURES };
    case 'public':
      return { ...PUBLIC_FEATURES };
  }
}

// =============================================================================
// Singleton Instance
// =============================================================================

let _currentTier: BuildTier | null = null;
let _features: FeatureFlags | null = null;

/**
 * Get the current build tier
 */
export function getBuildTier(): BuildTier {
  if (_currentTier === null) {
    _currentTier = detectBuildTier();
  }
  return _currentTier;
}

/**
 * Get current feature flags
 */
export function getFeatures(): FeatureFlags {
  if (_features === null) {
    _features = getFeatureFlagsForTier(getBuildTier());
  }
  return _features;
}

/**
 * Check if a specific feature is enabled
 */
export function isFeatureEnabled(feature: keyof FeatureFlags): boolean {
  return getFeatures()[feature];
}

/**
 * Reset feature detection (for testing)
 */
export function resetFeatures(): void {
  _currentTier = null;
  _features = null;
}

// =============================================================================
// Feature Guards (for code branching)
// =============================================================================

/**
 * Execute callback only if feature is enabled
 */
export function withFeature<T>(
  feature: keyof FeatureFlags,
  callback: () => T,
  fallback?: T
): T | undefined {
  if (isFeatureEnabled(feature)) {
    return callback();
  }
  return fallback;
}

/**
 * Decorator-style feature guard for async functions
 */
export function requireFeature(feature: keyof FeatureFlags): MethodDecorator {
  return function (
    _target: object,
    _propertyKey: string | symbol,
    descriptor: PropertyDescriptor
  ) {
    const originalMethod = descriptor.value;
    descriptor.value = function (...args: unknown[]) {
      if (!isFeatureEnabled(feature)) {
        throw new Error(
          `Feature '${feature}' is not available in ${getBuildTier()} build`
        );
      }
      return originalMethod.apply(this, args);
    };
    return descriptor;
  };
}
