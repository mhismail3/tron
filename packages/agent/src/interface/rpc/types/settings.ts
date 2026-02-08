/**
 * @fileoverview Settings RPC Types
 *
 * Types for settings.get and settings.update methods.
 */

// =============================================================================
// Settings Methods
// =============================================================================

/** Result of settings.get */
export interface SettingsGetResult {
  defaultModel: string;
  defaultWorkspace?: string;
  compaction: {
    preserveRecentTurns: number;
    forceAlways: boolean;
    triggerTokenThreshold: number;
    alertZoneThreshold: number;
    defaultTurnFallback: number;
    alertTurnFallback: number;
  };
  memory: {
    autoInject: { enabled: boolean; count: number };
  };
  tools: {
    web: {
      fetch: { timeoutMs: number };
      cache: { ttlMs: number; maxEntries: number };
    };
  };
}

/** Params for settings.update */
export interface SettingsUpdateParams {
  settings: {
    server?: { defaultModel?: string; defaultWorkspace?: string };
    context?: {
      compactor?: {
        preserveRecentCount?: number;
        forceAlways?: boolean;
        triggerTokenThreshold?: number;
        alertZoneThreshold?: number;
        defaultTurnFallback?: number;
        alertTurnFallback?: number;
      };
      memory?: {
        autoInject?: { enabled?: boolean; count?: number };
      };
    };
    tools?: {
      web?: {
        fetch?: { timeoutMs?: number };
        cache?: { ttlMs?: number; maxEntries?: number };
      };
    };
  };
}
