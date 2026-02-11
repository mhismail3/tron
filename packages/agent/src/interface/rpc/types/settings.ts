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
  maxConcurrentSessions: number;
  compaction: {
    preserveRecentTurns: number;
    forceAlways: boolean;
    triggerTokenThreshold: number;
    alertZoneThreshold: number;
    defaultTurnFallback: number;
    alertTurnFallback: number;
  };
  memory: {
    ledger: { enabled: boolean };
    autoInject: { enabled: boolean; count: number };
  };
  rules: {
    discoverStandaloneFiles: boolean;
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
    server?: { defaultModel?: string; defaultWorkspace?: string; maxConcurrentSessions?: number };
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
        ledger?: { enabled?: boolean };
        autoInject?: { enabled?: boolean; count?: number };
      };
      rules?: {
        discoverStandaloneFiles?: boolean;
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
