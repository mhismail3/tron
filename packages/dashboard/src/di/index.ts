/**
 * @fileoverview Dependency Injection container for dashboard services
 *
 * Provides a simple service container that allows injecting mock implementations
 * for testing while using real implementations in production.
 */

import type {
  IDashboardSessionRepository,
  IDashboardEventRepository,
} from '../data/repositories/types.js';

/**
 * Service container interface
 */
export interface ServiceContainer {
  sessions: IDashboardSessionRepository;
  events: IDashboardEventRepository;
}

/**
 * Create a service container with the provided repositories
 */
export function createContainer(repositories: ServiceContainer): ServiceContainer {
  return {
    sessions: repositories.sessions,
    events: repositories.events,
  };
}

/**
 * Default container instance (set during app initialization)
 */
let defaultContainer: ServiceContainer | null = null;

/**
 * Initialize the default container
 */
export function initializeContainer(repositories: ServiceContainer): void {
  defaultContainer = createContainer(repositories);
}

/**
 * Get the default container (throws if not initialized)
 */
export function getContainer(): ServiceContainer {
  if (!defaultContainer) {
    throw new Error(
      'Service container not initialized. Call initializeContainer() first.'
    );
  }
  return defaultContainer;
}

/**
 * Reset the default container (for testing)
 */
export function resetContainer(): void {
  defaultContainer = null;
}
