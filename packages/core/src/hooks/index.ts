/**
 * @fileoverview Hooks module exports
 *
 * The hook system provides lifecycle interception points for the agent.
 * Built-in hooks integrate the memory layer with the agent loop.
 *
 * @example
 * ```typescript
 * import {
 *   HookEngine,
 *   discoverHooks,
 *   loadDiscoveredHooks,
 *   registerBuiltinHooks,
 * } from '@tron/core/hooks';
 *
 * const engine = new HookEngine();
 *
 * // Register built-in hooks
 * registerBuiltinHooks(engine, { ledgerManager, handoffManager });
 *
 * // Discover and load user hooks
 * const discovered = await discoverHooks({ projectPath });
 * const userHooks = await loadDiscoveredHooks(discovered);
 * userHooks.forEach(hook => engine.register(hook));
 * ```
 */

export * from './types.js';
export { HookEngine } from './engine.js';

// Discovery module
export {
  discoverHooks,
  loadDiscoveredHooks,
  watchHooks,
  type DiscoveredHook,
  type DiscoveryConfig,
} from './discovery.js';

// Built-in hooks
export {
  createSessionStartHook,
  createSessionEndHook,
  createPreCompactHook,
  createPostToolUseHook,
  registerBuiltinHooks,
  type SessionStartHookConfig,
  type SessionEndHookConfig,
  type PreCompactHookConfig,
  type PostToolUseHookConfig,
  type BuiltinHooksConfig,
} from './builtin/index.js';
