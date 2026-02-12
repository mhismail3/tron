/**
 * @fileoverview Hook execution engine
 *
 * Orchestrates hook registration, lookup, and execution.
 * Manages background hook tracking with drain functionality.
 */

import type {
  HookType,
  HookResult,
  HookDefinition,
  RegisteredHook,
  AnyHookContext,
  HookExecutionMode,
  PreToolHookContext,
  PostToolHookContext,
} from './types.js';
import type { TronEvent } from '@core/types/index.js';
import { createLogger, categorizeError, LogErrorCategory, LogErrorCodes } from '@infrastructure/logging/index.js';
import { getSettings } from '@infrastructure/settings/index.js';
import type { HookSettings } from '@infrastructure/settings/types.js';

const logger = createLogger('hooks:engine');

/**
 * Hook types that must always be blocking because they can affect agent flow.
 * PreToolUse, UserPromptSubmit, PreCompact need to block to allow modifications/blocking.
 */
const FORCED_BLOCKING_TYPES: HookType[] = ['PreToolUse', 'UserPromptSubmit', 'PreCompact'];

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
  private hooks = new Map<string, RegisteredHook>();
  private pendingBackground = new Map<string, Promise<void>>();
  private backgroundCounter = 0;

  /**
   * Register a hook
   */
  register(definition: HookDefinition): void {
    const existing = this.hooks.get(definition.name);
    if (existing) {
      logger.debug('Replacing existing hook', { name: definition.name });
    }

    // Force blocking mode for hooks that need to affect agent flow
    const resolvedMode: HookExecutionMode = FORCED_BLOCKING_TYPES.includes(definition.type)
      ? 'blocking'
      : (definition.mode ?? 'blocking');

    const hook: RegisteredHook = {
      ...definition,
      priority: definition.priority ?? 0,
      mode: resolvedMode,
      registeredAt: new Date().toISOString(),
    };

    this.hooks.set(definition.name, hook);
    logger.info('Hook registered', {
      name: definition.name,
      type: definition.type,
      priority: hook.priority,
      mode: hook.mode,
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
   * Get all hooks for a specific type, sorted by priority (descending)
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

    return this.runHooksSequentially(hooks, context, type);
  }

  /**
   * Execute hooks with automatic event emission.
   *
   * This is the preferred method for hook invocation - it handles:
   * 1. Getting hooks by type (sorted by priority)
   * 2. Separating blocking and background hooks
   * 3. Emitting hook_triggered event if blocking hooks exist
   * 4. Executing blocking hooks with fail-open error handling
   * 5. Emitting hook_completed event with duration
   * 6. Starting background hooks (fire-and-forget)
   * 7. Returning the aggregated result from blocking hooks
   *
   * @param type - Hook type to execute
   * @param context - Type-safe hook context
   * @param eventEmitter - Event emitter for hook lifecycle events
   * @returns HookResult with action and optional modifications (from blocking hooks only)
   */
  async executeWithEvents(
    type: HookType,
    context: AnyHookContext,
    eventEmitter: { emit: (event: TronEvent) => void }
  ): Promise<HookResult> {
    const hooks = this.getHooks(type);

    // Separate by mode
    const blockingHooks = hooks.filter(h => h.mode === 'blocking');
    const backgroundHooks = hooks.filter(h => h.mode === 'background');

    const startTime = Date.now();
    const blockingHookNames = blockingHooks.map(h => h.name);

    // Log hook execution start
    logger.info('executeWithEvents started', {
      hookType: type,
      sessionId: context.sessionId,
      blockingCount: blockingHooks.length,
      backgroundCount: backgroundHooks.length,
      blockingHookNames,
      backgroundHookNames: backgroundHooks.map(h => h.name),
      ...(this.isToolContext(context) && {
        toolName: context.toolName,
        toolCallId: context.toolCallId,
      }),
    });

    // Only emit events if blocking hooks are registered
    if (blockingHooks.length > 0) {
      // Build event with optional tool context
      const triggeredEvent: TronEvent = {
        type: 'hook_triggered',
        sessionId: context.sessionId,
        timestamp: new Date().toISOString(),
        hookNames: blockingHookNames,
        hookEvent: type,
        // Include tool context if present in context
        ...(this.isToolContext(context) && {
          toolName: context.toolName,
          toolCallId: context.toolCallId,
        }),
      };
      eventEmitter.emit(triggeredEvent);
    }

    // Execute blocking hooks only
    const result = await this.executeBlockingHooks(blockingHooks, context);
    const duration = Date.now() - startTime;

    // Emit completed event with result for blocking hooks
    if (blockingHooks.length > 0) {
      const completedEvent: TronEvent = {
        type: 'hook_completed',
        sessionId: context.sessionId,
        timestamp: new Date().toISOString(),
        hookNames: blockingHookNames,
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

    // Fire background hooks (no await)
    if (backgroundHooks.length > 0) {
      this.startBackgroundHooks(type, backgroundHooks, context, eventEmitter);
    }

    // Log hook execution complete
    logger.info('executeWithEvents completed', {
      hookType: type,
      sessionId: context.sessionId,
      blockingCount: blockingHooks.length,
      backgroundCount: backgroundHooks.length,
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
   * Wait for all pending background hooks to complete.
   * Call this before session end to ensure all hooks have finished.
   *
   * @param timeoutMs - Maximum time to wait (default: 30000ms)
   */
  async waitForBackgroundHooks(timeoutMs = 30000): Promise<void> {
    const pending = Array.from(this.pendingBackground.values());
    if (pending.length === 0) {
      return;
    }

    logger.debug('Waiting for background hooks', { count: pending.length, timeoutMs });

    await Promise.race([
      Promise.allSettled(pending),
      new Promise<void>(resolve => setTimeout(resolve, timeoutMs)),
    ]);

    logger.debug('Background hooks drain complete', {
      remaining: this.pendingBackground.size,
    });
  }

  /**
   * Get the number of pending background hooks
   */
  getPendingBackgroundCount(): number {
    return this.pendingBackground.size;
  }

  /**
   * Execute blocking hooks sequentially
   */
  private async executeBlockingHooks(
    hooks: RegisteredHook[],
    context: AnyHookContext
  ): Promise<HookResult> {
    if (hooks.length === 0) {
      return { action: 'continue' };
    }

    return this.runHooksSequentially(hooks, context, context.hookType);
  }

  /**
   * Run hooks sequentially with shared execution logic.
   * Handles filtering, modification collection, blocking, and fail-open error handling.
   */
  private async runHooksSequentially(
    hooks: RegisteredHook[],
    context: AnyHookContext,
    hookType: HookType
  ): Promise<HookResult> {
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
        const structured = categorizeError(error, { hookName: hook.name, hookType });
        logger.error('Hook execution error', {
          name: hook.name,
          sessionId: context.sessionId,
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
   * Start background hooks (fire-and-forget)
   */
  private startBackgroundHooks(
    type: HookType,
    hooks: RegisteredHook[],
    context: AnyHookContext,
    eventEmitter: { emit: (event: TronEvent) => void }
  ): void {
    const executionId = `bg_${++this.backgroundCounter}_${Date.now()}`;
    const hookNames = hooks.map(h => h.name);
    const startTime = Date.now();

    // Emit started event immediately
    eventEmitter.emit({
      type: 'hook.background_started',
      sessionId: context.sessionId,
      timestamp: new Date().toISOString(),
      hookNames,
      hookEvent: type,
      executionId,
    } as TronEvent);

    // Execute without awaiting
    const promise = this.executeBackgroundHooksInternal(
      hooks,
      context,
      eventEmitter,
      executionId,
      hookNames,
      startTime,
      type
    );

    // Track for draining
    this.pendingBackground.set(executionId, promise);
    promise.finally(() => this.pendingBackground.delete(executionId));
  }

  /**
   * Internal execution of background hooks
   */
  private async executeBackgroundHooksInternal(
    hooks: RegisteredHook[],
    context: AnyHookContext,
    eventEmitter: { emit: (event: TronEvent) => void },
    executionId: string,
    hookNames: string[],
    startTime: number,
    type: HookType
  ): Promise<void> {
    let hasError = false;
    let errorMessage: string | undefined;

    for (const hook of hooks) {
      try {
        // Apply filter if present
        if (hook.filter && !hook.filter(context)) {
          logger.debug('Background hook filtered out', { name: hook.name });
          continue;
        }

        // Execute hook directly without using executeHook (which swallows errors)
        // We want to track errors for background hooks separately
        await this.executeBackgroundHook(hook, context);
      } catch (error) {
        // Log error but continue to next hook (fail-open)
        hasError = true;
        const structured = categorizeError(error, { hookName: hook.name, hookType: type });
        errorMessage = structured.message;
        logger.error('Background hook execution error', {
          name: hook.name,
          executionId,
          sessionId: context.sessionId,
          code: LogErrorCodes.HOOK_ERROR,
          category: LogErrorCategory.HOOK_EXECUTION,
          error: structured.message,
          retryable: structured.retryable,
        });
      }
    }

    const duration = Date.now() - startTime;

    // Emit completed event
    eventEmitter.emit({
      type: 'hook.background_completed',
      sessionId: context.sessionId,
      timestamp: new Date().toISOString(),
      hookNames,
      hookEvent: type,
      executionId,
      result: hasError ? 'error' : 'continue',
      duration,
      error: errorMessage,
    } as TronEvent);

    logger.info('Background hooks completed', {
      executionId,
      sessionId: context.sessionId,
      hookCount: hooks.length,
      result: hasError ? 'error' : 'continue',
      duration,
    });
  }

  /**
   * Execute a single background hook with timeout.
   * Unlike executeHook, this throws errors instead of swallowing them.
   */
  private async executeBackgroundHook(
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

    // This will throw on error or timeout (for error tracking in background hooks)
    const result = await Promise.race([executionPromise, timeoutPromise]);
    logger.debug('Background hook executed', { name: hook.name, action: result.action });
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
