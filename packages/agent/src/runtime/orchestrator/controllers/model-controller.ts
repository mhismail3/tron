/**
 * @fileoverview Model Controller
 *
 * Extracted from EventStoreOrchestrator as part of modular refactoring.
 * Handles model switching operations including:
 * - Session validation
 * - Event persistence (linearized for active sessions)
 * - Database model update
 * - Active session reconfiguration
 * - Agent model switching with auth
 *
 * ## Design
 *
 * ModelController is a stateless coordinator that operates on provided dependencies.
 * All state lives in EventStore and ActiveSession. This design:
 * - Improves testability (easy to mock dependencies)
 * - Reduces coupling to orchestrator
 * - Makes the model switching flow explicit and traceable
 */
import { createLogger } from '@infrastructure/logging/index.js';
import type { EventStore } from '@infrastructure/events/event-store.js';
import type { SessionId } from '@infrastructure/events/types.js';
import type { AuthProvider } from '../session/auth-provider.js';
import type { ActiveSession } from '../types.js';
import type { ActiveSessionStore } from '../session/active-session-store.js';
import { normalizeToUnifiedAuth } from '../agent-factory.js';

const logger = createLogger('model-controller');

// =============================================================================
// Types
// =============================================================================

/**
 * Configuration for ModelController.
 * All dependencies are injected to avoid circular imports and improve testability.
 */
export interface ModelControllerConfig {
  /** EventStore for session lookup and persistence */
  eventStore: EventStore;

  /** AuthProvider for loading auth credentials for new model */
  authProvider: AuthProvider;

  /** Active session store */
  sessionStore: ActiveSessionStore;

  /** Optional: normalize auth to unified format (injected for testing) */
  normalizeToUnifiedAuth?: (auth: unknown) => unknown;
}

/**
 * Result of a model switch operation.
 */
export interface ModelSwitchResult {
  previousModel: string;
  newModel: string;
}

// =============================================================================
// ModelController Class
// =============================================================================

/**
 * Coordinates model switching for a session.
 *
 * Extracted from EventStoreOrchestrator to reduce complexity and improve
 * maintainability. Handles validation, event persistence, database update,
 * and agent reconfiguration.
 */
export class ModelController {
  private config: ModelControllerConfig;

  constructor(config: ModelControllerConfig) {
    this.config = config;
  }

  /**
   * Switch the model for a session.
   *
   * @param sessionId - The session to switch model for
   * @param model - The new model to switch to
   * @returns Previous and new model names
   * @throws If session not found or agent is processing
   */
  async switchModel(sessionId: string, model: string): Promise<ModelSwitchResult> {
    // 1. Validate session exists
    const session = await this.config.eventStore.getSession(sessionId as SessionId);
    if (!session) {
      throw new Error(`Session not found: ${sessionId}`);
    }

    const previousModel = session.latestModel;

    // 2. Get active session (if any)
    const active = this.config.sessionStore.get(sessionId);

    // 3. Validate not processing
    if (active?.sessionContext.isProcessing()) {
      throw new Error('Cannot switch model while agent is processing');
    }

    // 4. Append model switch event
    await this.appendModelSwitchEvent(sessionId, active, previousModel, model);

    // 5. Persist model to database
    await this.config.eventStore.updateLatestModel(sessionId as SessionId, model);
    logger.debug('[MODEL_SWITCH] Model persisted to database', { sessionId, model });

    // 6. Update active session if exists
    if (active) {
      await this.updateActiveSession(active, model);
    }

    logger.info('Model switched', { sessionId, previousModel, newModel: model });

    return { previousModel, newModel: model };
  }

  // ===========================================================================
  // Private Methods
  // ===========================================================================

  /**
   * Append config.model_switch event.
   * Uses linearized append for active sessions, direct append for inactive.
   */
  private async appendModelSwitchEvent(
    sessionId: string,
    active: ActiveSession | undefined,
    previousModel: string,
    newModel: string
  ): Promise<void> {
    const payload = { previousModel, newModel };

    if (active?.sessionContext) {
      // Linearized append for active session
      const event = await active.sessionContext.appendEvent('config.model_switch', payload);
      if (event) {
        logger.debug('[LINEARIZE] config.model_switch appended', {
          sessionId,
          eventId: event.id,
        });
      }
    } else {
      // Direct append for inactive session (no concurrent events)
      const event = await this.config.eventStore.append({
        sessionId: sessionId as SessionId,
        type: 'config.model_switch',
        payload,
      });
      if (event) {
        logger.debug('[DIRECT] config.model_switch appended', {
          sessionId,
          eventId: event.id,
        });
      }
    }
  }

  /**
   * Update active session with new model.
   * Handles auth loading, model update, and agent reconfiguration.
   */
  private async updateActiveSession(active: ActiveSession, model: string): Promise<void> {
    // Load auth for the new model
    const newAuth = await this.config.authProvider.getAuthForProvider(model);
    logger.debug('[MODEL_SWITCH] Auth loaded', {
      sessionId: active.sessionId,
      authType: (newAuth as { type?: string }).type,
    });

    // Update session model
    active.model = model;

    // Update provider type for token normalization (resets baseline)
    active.sessionContext.updateProviderTypeForModel(model);

    // Normalize auth and preserve endpoint for Google models
    const normalize = this.config.normalizeToUnifiedAuth ?? normalizeToUnifiedAuth;
    const normalizedAuth = normalize(newAuth) as Record<string, unknown>;
    const authWithEndpoint = 'endpoint' in (newAuth as object)
      ? { ...normalizedAuth, endpoint: (newAuth as { endpoint: string }).endpoint }
      : normalizedAuth;

    // Switch model on agent (preserves conversation history)
    active.agent.switchModel(model, undefined, authWithEndpoint as Parameters<typeof active.agent.switchModel>[2]);
    logger.debug('[MODEL_SWITCH] Agent model switched (preserving messages)', {
      sessionId: active.sessionId,
      model,
    });
  }
}

// =============================================================================
// Factory Function
// =============================================================================

/**
 * Create a ModelController instance.
 */
export function createModelController(config: ModelControllerConfig): ModelController {
  return new ModelController(config);
}
