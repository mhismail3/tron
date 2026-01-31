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
  PreToolHookContext,
  PostToolHookContext,
} from './types.js';
import type { TronEvent } from '../types/index.js';
import { createLogger, categorizeError, LogErrorCategory, LogErrorCodes } from '../logging/index.js';
import { getSettings } from '../settings/index.js';
import type { HookSettings } from '../settings/types.js';

const logger = createLogger('hooks:engine');

/**
 * Get default hook settings from global settings.
 * Exported for dependency injection - consumers can pass custom settings.
 */
export function getDefaultHookSettings(): HookSettings {
  return getSettings().hooks;
}

// Internal helper - uses the exported getter
function getHookSettings() {
  return getDefaultHookSettings();
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
        const structured = categorizeError(error, { hookName: hook.name, hookType: type });
        logger.error('Hook execution error', {
          name: hook.name,
          code: LogErrorCodes.HOOK_ERROR,
          category: LogErrorCategory.HOOK_EXECUTION,
          error: structured.message,
          retryable: structured.retryable,
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
   * Execute hooks with automatic event emission.
   *
   * This is the preferred method for hook invocation - it handles:
   * 1. Getting hooks by type (sorted by priority)
   * 2. Emitting hook_triggered event if hooks exist
   * 3. Executing all hooks with fail-open error handling
   * 4. Emitting hook_completed event with duration
   * 5. Returning the aggregated result
   *
   * @param type - Hook type to execute
   * @param context - Type-safe hook context
   * @param eventEmitter - Event emitter for hook lifecycle events
   * @returns HookResult with action and optional modifications
   */
  async executeWithEvents(
    type: HookType,
    context: AnyHookContext,
    eventEmitter: { emit: (event: TronEvent) => void }
  ): Promise<HookResult> {
    const hooks = this.getHooks(type);
    const startTime = Date.now();
    const hookNames = hooks.map(h => h.name);

    // Log hook execution start
    logger.info('executeWithEvents started', {
      hookType: type,
      sessionId: context.sessionId,
      hookCount: hooks.length,
      hookNames,
      ...(this.isToolContext(context) && {
        toolName: context.toolName,
        toolCallId: context.toolCallId,
      }),
    });

    // Only emit events if hooks are registered
    if (hooks.length > 0) {
      // Build event with optional tool context
      const triggeredEvent: TronEvent = {
        type: 'hook_triggered',
        sessionId: context.sessionId,
        timestamp: new Date().toISOString(),
        hookNames,
        hookEvent: type,
        // Include tool context if present in context
        ...(this.isToolContext(context) && {
          toolName: context.toolName,
          toolCallId: context.toolCallId,
        }),
      };
      eventEmitter.emit(triggeredEvent);
    }

    // Execute hooks (HookEngine.execute already handles fail-open)
    const result = await this.execute(type, context);
    const duration = Date.now() - startTime;

    // Emit completed event with result
    if (hooks.length > 0) {
      const completedEvent: TronEvent = {
        type: 'hook_completed',
        sessionId: context.sessionId,
        timestamp: new Date().toISOString(),
        hookNames,
        hookEvent: type,
        result: result.action,
        duration,
        reason: result.reason,
        // Include tool context if present
        ...(this.isToolContext(context) && {
          toolName: context.toolName,
          toolCallId: context.toolCallId,
        }),
      };
      eventEmitter.emit(completedEvent);
    }

    // Log hook execution complete
    logger.info('executeWithEvents completed', {
      hookType: type,
      sessionId: context.sessionId,
      hookCount: hooks.length,
      result: result.action,
      duration,
      reason: result.reason,
      ...(this.isToolContext(context) && {
        toolName: context.toolName,
        toolCallId: context.toolCallId,
      }),
    });

    return result;
  }

  /**
   * Type guard to check if context has tool-related fields
   */
  private isToolContext(
    context: AnyHookContext
  ): context is PreToolHookContext | PostToolHookContext {
    return 'toolName' in context && 'toolCallId' in context;
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
      const structured = categorizeError(error, { hookName: hook.name });
      logger.warn('Hook failed', {
        name: hook.name,
        code: structured.code,
        category: LogErrorCategory.HOOK_EXECUTION,
        error: structured.message,
        retryable: structured.retryable,
      });
      // Fail-open: return continue on error
      return { action: 'continue' };
    }
  }
}
