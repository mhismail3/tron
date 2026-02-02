/**
 * @fileoverview Event Persistence Module
 *
 * Components for event persistence and session orchestration:
 *
 * - EventPersister: Linearized event persistence
 * - EventStoreOrchestrator: Session orchestration and management
 */

// Event persistence (Phase 1)
export {
  EventPersister,
  createEventPersister,
  type EventPersisterConfig,
  type AppendRequest,
} from './event-persister.js';

// Event store orchestrator
export { EventStoreOrchestrator } from './event-store-orchestrator.js';

// Re-export types from orchestrator for convenience
export type {
  EventStoreOrchestratorConfig,
  ActiveSession,
  AgentRunOptions,
  AgentEvent,
  CreateSessionOptions,
  SessionInfo,
  ForkResult,
  WorktreeInfo,
} from './event-store-orchestrator.js';
