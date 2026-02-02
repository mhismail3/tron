/**
 * @fileoverview Canvas RPC Types
 *
 * Types for canvas artifact methods.
 */

// =============================================================================
// Canvas Methods
// =============================================================================

/**
 * Get a canvas artifact by ID
 */
export interface CanvasGetParams {
  /** Canvas ID to fetch */
  canvasId: string;
}

/**
 * Canvas artifact data returned from server
 */
export interface CanvasArtifactData {
  /** Unique canvas identifier */
  canvasId: string;
  /** Session that created this canvas */
  sessionId: string;
  /** Optional title for the canvas */
  title?: string;
  /** Complete UI component tree */
  ui: Record<string, unknown>;
  /** Initial state bindings */
  state?: Record<string, unknown>;
  /** ISO timestamp when saved */
  savedAt: string;
}

export interface CanvasGetResult {
  /** Whether the canvas was found */
  found: boolean;
  /** Canvas data if found */
  canvas?: CanvasArtifactData;
}
