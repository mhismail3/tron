/**
 * @fileoverview Tool Result RPC Types
 *
 * Types for interactive tool results (client to server).
 */

// =============================================================================
// Tool Result (Client → Server for interactive tools like AskUserQuestion)
// =============================================================================

/**
 * Parameters for submitting a tool result from the client
 * Used when an interactive tool (like AskUserQuestion) requires user input
 */
export interface ToolResultParams {
  /** Session ID */
  sessionId: string;
  /** Tool call ID to respond to */
  toolCallId: string;
  /** The result content (JSON-stringified for complex types) */
  result: unknown;
}

/**
 * Result of submitting a tool result
 */
export interface ToolResultResult {
  /** Whether the result was accepted */
  success: boolean;
  /** Error message if not successful */
  error?: string;
}
