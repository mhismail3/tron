/**
 * @fileoverview Feature Controllers Module
 *
 * Controllers for feature-specific operations:
 *
 * - ModelController: Model switching and configuration
 * - PlanModeController: Plan mode state management
 * - NotificationController: Push notification delivery
 * - TodoController: Todo and backlog management
 */

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
