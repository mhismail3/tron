/**
 * @fileoverview Hook execution engine
 *
 * Manages hook registration and execution with priority ordering.
 */

import type {
  HookType,
  HookResult,
  HookDefinition,
  RegisteredHook,
  AnyHookContext,
} from './types.js';
import { createLogger } from '../logging/logger.js';
import { getSettings } from '../settings/index.js';

const logger = createLogger('hooks:engine');

// Get hook settings (loaded lazily on first access)
function getHookSettings() {
  return getSettings().hooks;
}

export class HookEngine {
  private hooks: Map<string, RegisteredHook> = new Map();

  /**
   * Register a hook
   */
  register(definition: HookDefinition): void {
    const existing = this.hooks.get(definition.name);
    if (existing) {
      logger.debug('Replacing existing hook', { name: definition.name });
    }

    const hook: RegisteredHook = {
      ...definition,
      priority: definition.priority ?? 0,
      registeredAt: new Date().toISOString(),
    };

    this.hooks.set(definition.name, hook);
    logger.info('Hook registered', {
      name: definition.name,
      type: definition.type,
      priority: hook.priority,
    });
  }

  /**
   * Unregister a hook by name
   */
  unregister(name: string): void {
    const removed = this.hooks.delete(name);
    if (removed) {
      logger.info('Hook unregistered', { name });
    }
  }

  /**
   * Get all hooks for a specific type
   */
  getHooks(type: HookType): RegisteredHook[] {
    return Array.from(this.hooks.values())
      .filter(hook => hook.type === type)
      .sort((a, b) => (b.priority ?? 0) - (a.priority ?? 0));
  }

  /**
   * List all registered hooks
   */
  listHooks(): RegisteredHook[] {
    return Array.from(this.hooks.values());
  }

  /**
   * Clear all hooks
   */
  clear(): void {
    this.hooks.clear();
    logger.info('All hooks cleared');
  }

  /**
   * Execute hooks for a specific type
   */
  async execute(type: HookType, context: AnyHookContext): Promise<HookResult> {
    const hooks = this.getHooks(type);

    if (hooks.length === 0) {
      return { action: 'continue' };
    }

    logger.debug('Executing hooks', { type, count: hooks.length });

    const collectedModifications: Record<string, unknown> = {};
    const messages: string[] = [];

    for (const hook of hooks) {
      try {
        // Apply filter if present
        if (hook.filter && !hook.filter(context)) {
          logger.debug('Hook filtered out', { name: hook.name });
          continue;
        }

        const result = await this.executeHook(hook, context);

        // Collect messages
        if (result.message) {
          messages.push(result.message);
        }

        // Handle result based on action
        switch (result.action) {
          case 'block':
            logger.warn('Hook blocked execution', {
              name: hook.name,
              reason: result.reason,
            });
            return {
              action: 'block',
              reason: result.reason,
              message: messages.join('\n'),
            };

          case 'modify':
            // Collect modifications
            if (result.modifications) {
              Object.assign(collectedModifications, result.modifications);
            }
            break;

          case 'continue':
            // Continue to next hook
            break;
        }
      } catch (error) {
        // Log error but continue (fail-open)
        logger.error('Hook execution error', {
          name: hook.name,
          error: error instanceof Error ? error.message : String(error),
        });
      }
    }

    // Return collected modifications if any
    if (Object.keys(collectedModifications).length > 0) {
      return {
        action: 'modify',
        modifications: collectedModifications,
        message: messages.join('\n') || undefined,
      };
    }

    return {
      action: 'continue',
      message: messages.join('\n') || undefined,
    };
  }

  /**
   * Execute a single hook with timeout
   */
  private async executeHook(
    hook: RegisteredHook,
    context: AnyHookContext
  ): Promise<HookResult> {
    const settings = getHookSettings();
    const timeout = hook.timeout ?? settings.defaultTimeoutMs;

    const timeoutPromise = new Promise<HookResult>((_, reject) => {
      setTimeout(() => {
        reject(new Error(`Hook timed out after ${timeout}ms`));
      }, timeout);
    });

    const executionPromise = hook.handler(context);

    try {
      const result = await Promise.race([executionPromise, timeoutPromise]);
      logger.debug('Hook executed', { name: hook.name, action: result.action });
      return result;
    } catch (error) {
      logger.warn('Hook failed', {
        name: hook.name,
        error: error instanceof Error ? error.message : String(error),
      });
      // Fail-open: return continue on error
      return { action: 'continue' };
    }
  }
}
