/**
 * @fileoverview Hook registration and lookup
 *
 * Manages hook registration with priority sorting and mode enforcement.
 * Extracted from HookEngine to reduce god class responsibilities.
 */

import type {
  HookType,
  HookDefinition,
  RegisteredHook,
  HookExecutionMode,
} from './types.js';
import { createLogger } from '@infrastructure/logging/index.js';

const logger = createLogger('hooks:registry');

/**
 * Hook types that must always be blocking because they can affect agent flow.
 * PreToolUse, UserPromptSubmit, PreCompact need to block to allow modifications/blocking.
 */
const FORCED_BLOCKING_TYPES: HookType[] = ['PreToolUse', 'UserPromptSubmit', 'PreCompact'];

/**
 * Registry for hook definitions with priority-based lookup
 */
export class HookRegistry {
  private hooks = new Map<string, RegisteredHook>();

  /**
   * Register a hook definition
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
   * @returns true if hook was removed, false if not found
   */
  unregister(name: string): boolean {
    const removed = this.hooks.delete(name);
    if (removed) {
      logger.info('Hook unregistered', { name });
    }
    return removed;
  }

  /**
   * Get a hook by name
   */
  get(name: string): RegisteredHook | undefined {
    return this.hooks.get(name);
  }

  /**
   * Get all hooks for a specific type, sorted by priority (descending)
   */
  getByType(type: HookType): RegisteredHook[] {
    return Array.from(this.hooks.values())
      .filter(hook => hook.type === type)
      .sort((a, b) => (b.priority ?? 0) - (a.priority ?? 0));
  }

  /**
   * Get all registered hooks
   */
  getAll(): RegisteredHook[] {
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
   * Get number of registered hooks
   */
  size(): number {
    return this.hooks.size;
  }
}
