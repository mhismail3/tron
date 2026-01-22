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
  type ListSessionsOptions,
  // Re-exported types
  type ActiveSession,
  type CreateSessionOptions,
  type SessionInfo,
  type ForkResult,
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
  // Re-exported types
  type ContextSnapshot,
  type DetailedContextSnapshot,
  type PreTurnValidation,
  type CompactionPreview,
  type CompactionResult,
} from './context/index.js';

// =============================================================================
// Orchestration Service
// =============================================================================

export {
  type OrchestrationService,
  // Re-exported types
  type AgentRunOptions,
  type AgentEvent,
  type RunResult,
} from './orchestration/index.js';
