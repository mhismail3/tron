/**
 * @fileoverview Settings RPC Handlers
 *
 * Handlers for settings.* RPC methods:
 * - settings.get: Get current user-configurable settings
 * - settings.update: Update settings (deep merge into ~/.tron/settings.json)
 */

import {
  getSettings,
  loadUserSettings,
  saveSettings,
  reloadSettings,
} from '@infrastructure/settings/index.js';
import type { UserSettings } from '@infrastructure/settings/index.js';
import type { SettingsGetResult, SettingsUpdateParams } from '../types/settings.js';
import type { MethodRegistration, MethodHandler } from '../registry.js';

// =============================================================================
// Helpers
// =============================================================================

/**
 * Deep merge source into target. Arrays and primitives are replaced.
 * Only merges plain objects recursively.
 */
function deepMergeSettings(
  target: Record<string, unknown>,
  source: Record<string, unknown>
): Record<string, unknown> {
  const result = { ...target };

  for (const key of Object.keys(source)) {
    const sourceVal = source[key];
    const targetVal = target[key];

    if (
      sourceVal !== undefined &&
      sourceVal !== null &&
      typeof sourceVal === 'object' &&
      !Array.isArray(sourceVal) &&
      targetVal !== undefined &&
      typeof targetVal === 'object' &&
      !Array.isArray(targetVal)
    ) {
      result[key] = deepMergeSettings(
        targetVal as Record<string, unknown>,
        sourceVal as Record<string, unknown>
      );
    } else if (sourceVal !== undefined) {
      result[key] = sourceVal;
    }
  }

  return result;
}

// =============================================================================
// Handler Factory
// =============================================================================

export function createSettingsHandlers(): MethodRegistration[] {
  const getHandler: MethodHandler = async () => {
    const settings = getSettings();
    const result: SettingsGetResult = {
      defaultModel: settings.server.defaultModel,
      defaultWorkspace: settings.server.defaultWorkspace,
      maxConcurrentSessions: settings.server.maxConcurrentSessions,
      compaction: {
        preserveRecentTurns: settings.context.compactor.preserveRecentCount,
        forceAlways: settings.context.compactor.forceAlways ?? false,
        triggerTokenThreshold: settings.context.compactor.triggerTokenThreshold ?? 0.70,
        alertZoneThreshold: settings.context.compactor.alertZoneThreshold ?? 0.50,
        defaultTurnFallback: settings.context.compactor.defaultTurnFallback ?? 8,
        alertTurnFallback: settings.context.compactor.alertTurnFallback ?? 5,
      },
      memory: {
        ledger: {
          enabled: settings.context.memory.ledger?.enabled ?? true,
        },
        autoInject: {
          enabled: settings.context.memory.autoInject?.enabled ?? false,
          count: settings.context.memory.autoInject?.count ?? 5,
        },
      },
      tools: {
        web: {
          fetch: { timeoutMs: settings.tools.web.fetch.timeoutMs },
          cache: {
            ttlMs: settings.tools.web.cache.ttlMs,
            maxEntries: settings.tools.web.cache.maxEntries,
          },
        },
      },
    };
    return result;
  };

  const updateHandler: MethodHandler<SettingsUpdateParams> = async (request) => {
    const params = request.params!;
    const current = (loadUserSettings() ?? {}) as Record<string, unknown>;
    const updated = deepMergeSettings(current, params.settings as unknown as Record<string, unknown>);
    saveSettings(updated as UserSettings);
    reloadSettings();
    return { success: true };
  };

  return [
    {
      method: 'settings.get',
      handler: getHandler,
      options: { description: 'Get user-configurable settings' },
    },
    {
      method: 'settings.update',
      handler: updateHandler,
      options: {
        requiredParams: ['settings'],
        description: 'Update user settings (deep merge)',
      },
    },
  ];
}
