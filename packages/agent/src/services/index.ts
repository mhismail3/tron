/**
 * @fileoverview Services Module
 *
 * Provides clean service interfaces for the orchestrator subsystems.
 * Each service encapsulates a specific domain with well-defined inputs/outputs.
 *
 * ## Architecture
 *
 * ```
 * services/
 * ├── session/      - Session lifecycle management
 * ├── context/      - Context management and compaction
 * └── orchestration/- Agent run coordination (TODO)
 * ```
 *
 * ## Usage
 *
 * ```typescript
 * import {
 *   createSessionService,
 *   createContextService,
 * } from './services/index.js';
 *
 * const sessionService = createSessionService(deps);
 * const contextService = createContextService(deps);
 * ```
 */

// =============================================================================
// Session Service
// =============================================================================

export {
  createSessionService,
  type SessionService,
  type SessionServiceDeps,
  type EndSessionOptions,
} from './session/index.js';

// =============================================================================
// Context Service
// =============================================================================

export {
  createContextService,
  type ContextService,
  type ContextServiceDeps,
  type CompactionOptions,
  type TurnValidationOptions,
  type ClearContextResult,
} from './context/index.js';

// =============================================================================
// Orchestration Service
// =============================================================================

export {
  type OrchestrationService,
} from './orchestration/index.js';
