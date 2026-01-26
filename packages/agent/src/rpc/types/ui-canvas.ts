/**
 * @fileoverview UI Canvas RPC Types
 *
 * Types for UI Canvas events (RenderAppUI tool).
 */

// =============================================================================
// UI Canvas Events (for RenderAppUI tool)
// =============================================================================

/**
 * Event data for UI render start (sheet should open)
 */
export interface UIRenderStartEvent {
  /** Unique canvas identifier */
  canvasId: string;
  /** Optional sheet title */
  title?: string;
  /** Tool call ID for correlation */
  toolCallId: string;
}

/**
 * Event data for UI render chunk (progressive JSON streaming)
 */
export interface UIRenderChunkEvent {
  /** Canvas identifier */
  canvasId: string;
  /** Partial JSON chunk */
  chunk: string;
  /** Full JSON accumulated so far */
  accumulated: string;
}

/**
 * Event data for UI render complete (final tree ready)
 */
export interface UIRenderCompleteEvent {
  /** Canvas identifier */
  canvasId: string;
  /** Complete UI component tree */
  ui: Record<string, unknown>;
  /** Initial state bindings */
  state?: Record<string, unknown>;
}

/**
 * Event data for UI action (button tap) - client to server
 */
export interface UIActionEvent {
  /** Canvas that generated the action */
  canvasId: string;
  /** Action identifier from the button */
  actionId: string;
  /** Timestamp of the action */
  timestamp: string;
}

/**
 * Event data for UI state change (form input) - client to server
 */
export interface UIStateChangeEvent {
  /** Canvas that generated the change */
  canvasId: string;
  /** Binding identifier from the component */
  bindingId: string;
  /** New value */
  value: unknown;
  /** Timestamp of the change */
  timestamp: string;
}
