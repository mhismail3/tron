/**
 * @fileoverview Feature Controllers Module
 *
 * Controllers for feature-specific operations:
 *
 * - EventController: Event query and mutation with linearization
 * - WorktreeController: Git worktree operations
 * - AgentController: Agent execution
 * - ModelController: Model switching and configuration
 * - NotificationController: Push notification delivery
 */

// Event query and mutation
export {
  EventController,
  createEventController,
  type EventControllerConfig,
  type EventSearchOptions,
  type DeleteMessageResult,
} from './event-controller.js';

// Worktree operations
export {
  WorktreeController,
  createWorktreeController,
  type WorktreeControllerConfig,
  type CommitResult,
  type MergeResult,
  type MergeStrategy,
  type WorktreeListItem,
} from './worktree-controller.js';

// Agent execution
export {
  AgentController,
  createAgentController,
  type AgentControllerConfig,
} from './agent-controller.js';

// Model switching
export {
  ModelController,
  createModelController,
  type ModelControllerConfig,
  type ModelSwitchResult,
} from './model-controller.js';

// Push notifications
export {
  NotificationController,
  createNotificationController,
  type NotificationControllerConfig,
  type NotificationPayload,
} from './notification-controller.js';


// Embedding and vector search
export {
  EmbeddingController,
  createEmbeddingController,
  type EmbeddingControllerConfig,
} from './embedding-controller.js';
