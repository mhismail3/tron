/**
 * @fileoverview Feature Controllers Module
 *
 * Controllers for feature-specific operations:
 *
 * - EventController: Event query and mutation with linearization
 * - BrowserController: Browser streaming operations
 * - WorktreeController: Git worktree operations
 * - AgentController: Agent execution
 * - ModelController: Model switching and configuration
 * - PlanModeController: Plan mode state management
 * - NotificationController: Push notification delivery
 * - TodoController: Todo and backlog management
 */

// Event query and mutation
export {
  EventController,
  createEventController,
  type EventControllerConfig,
  type EventSearchOptions,
  type DeleteMessageResult,
} from './event-controller.js';

// Browser streaming
export {
  BrowserController,
  createBrowserController,
  type BrowserControllerConfig,
  type BrowserStreamResult,
  type BrowserStatus,
} from './browser-controller.js';

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

// Plan mode management
export {
  PlanModeController,
  createPlanModeController,
  type PlanModeControllerConfig,
  type EnterPlanModeOptions,
  type ExitPlanModeOptions,
} from './plan-mode-controller.js';

// Push notifications
export {
  NotificationController,
  createNotificationController,
  type NotificationControllerConfig,
  type NotificationPayload,
} from './notification-controller.js';

// Todo and backlog management
export {
  TodoController,
  createTodoController,
  type TodoControllerConfig,
} from './todo-controller.js';
