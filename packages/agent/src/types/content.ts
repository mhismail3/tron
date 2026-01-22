/**
 * @fileoverview Basic content block types
 *
 * Extracted to break circular dependency between messages.ts and tools.ts
 */

// =============================================================================
// Content Types
// =============================================================================

/**
 * Text content block
 */
export interface TextContent {
  type: 'text';
  text: string;
}

/**
 * Image content block (base64 encoded)
 */
export interface ImageContent {
  type: 'image';
  data: string; // base64 encoded
  mimeType: string;
}

/**
 * Document content block (PDFs, base64 encoded)
 */
export interface DocumentContent {
  type: 'document';
  data: string; // base64 encoded
  mimeType: string; // e.g., 'application/pdf'
  fileName?: string;
}

/**
 * Thinking content block (Claude extended thinking)
 */
export interface ThinkingContent {
  type: 'thinking';
  thinking: string;
  signature?: string; // For verification
}
