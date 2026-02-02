/**
 * @fileoverview Config Events
 *
 * Events for model, prompt, and reasoning level changes.
 */

import type { BaseEvent } from './base.js';

// =============================================================================
// Config Events
// =============================================================================

/**
 * Model switch event
 */
export interface ConfigModelSwitchEvent extends BaseEvent {
  type: 'config.model_switch';
  payload: {
    previousModel: string;
    newModel: string;
    reason?: string;
  };
}

/**
 * System prompt update
 */
export interface ConfigPromptUpdateEvent extends BaseEvent {
  type: 'config.prompt_update';
  payload: {
    previousHash?: string;
    newHash: string;
    /** Content stored separately in blobs table */
    contentBlobId?: string;
  };
}

/**
 * Reasoning level change event
 * Persists reasoning level changes for session reconstruction
 */
export interface ConfigReasoningLevelEvent extends BaseEvent {
  type: 'config.reasoning_level';
  payload: {
    previousLevel?: 'low' | 'medium' | 'high' | 'xhigh';
    newLevel?: 'low' | 'medium' | 'high' | 'xhigh';
  };
}
