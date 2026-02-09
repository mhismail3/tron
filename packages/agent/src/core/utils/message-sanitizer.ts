/**
 * @fileoverview Message Sanitizer - Single Source of Truth for API Compliance
 *
 * This module provides the definitive sanitization layer for messages before
 * they are sent to any LLM provider API. It guarantees that the output will
 * be valid for the Anthropic/OpenAI/Google APIs.
 *
 * Properties:
 * - Pure: No side effects, deterministic output
 * - Idempotent: sanitize(sanitize(x)) === sanitize(x)
 * - Total: Handles any input, never throws
 * - Documented: Returns list of all fixes applied
 *
 * Invariants enforced:
 * 1. Every tool_use block has a corresponding toolResult message
 * 2. No empty messages (empty content)
 * 3. No toolResult without valid toolCallId
 * 4. First message is user role (after conversion to API format)
 */

import type {
  Message,
  UserMessage,
  AssistantMessage,
  ToolResultMessage,
  AssistantContent,
  ToolCall,
} from '@core/types/messages.js';
import { isToolCall } from '@core/types/messages.js';
import { createLogger } from '@infrastructure/logging/index.js';

const logger = createLogger('message-sanitizer');

// =============================================================================
// Types
// =============================================================================

export type SanitizationFixType =
  | 'injected_tool_result'
  | 'removed_empty_message'
  | 'removed_thinking_only_message'
  | 'removed_invalid_block'
  | 'removed_duplicate_tool_use'
  | 'merged_consecutive_messages'
  | 'injected_placeholder_user';

export interface SanitizationFix {
  type: SanitizationFixType;
  details: Record<string, unknown>;
}

export interface SanitizationResult {
  /** Sanitized messages array - guaranteed valid for API submission */
  messages: Message[];
  /** List of fixes that were applied */
  fixes: SanitizationFix[];
  /** True if no fixes were needed (input was already valid) */
  isValid: boolean;
}

export type ValidationViolationType =
  | 'missing_tool_result'
  | 'empty_message'
  | 'invalid_tool_result'
  | 'missing_first_user';

export interface ValidationViolation {
  type: ValidationViolationType;
  details: Record<string, unknown>;
}

// =============================================================================
// Constants
// =============================================================================

/** Content for synthetic tool results when execution was interrupted */
const INTERRUPTED_CONTENT = '[Interrupted]';

/** Content for placeholder user message when conversation doesn't start with user */
const PLACEHOLDER_USER_CONTENT = '[Continued]';

// =============================================================================
// Helper Functions
// =============================================================================

/**
 * Deep clone a message to avoid mutating input.
 * Uses JSON serialization for simplicity and to ensure clean serializable output.
 */
function cloneMessage<T extends Message>(msg: T): T {
  try {
    return JSON.parse(JSON.stringify(msg));
  } catch {
    // If serialization fails, return a minimal valid structure
    return { ...msg } as T;
  }
}

/**
 * Check if a user message has valid non-empty content.
 */
function isValidUserMessage(msg: UserMessage): boolean {
  if (typeof msg.content === 'string') {
    return msg.content.trim().length > 0;
  }
  if (Array.isArray(msg.content)) {
    return msg.content.length > 0;
  }
  return false;
}

/**
 * Check if an assistant message has content that will survive API conversion.
 *
 * Thinking blocks without signatures are display-only (used by non-extended thinking
 * models like Haiku/Sonnet) and are filtered out before sending to the API.
 * If a message contains ONLY such thinking blocks, it will become empty after conversion
 * and must be removed to prevent API errors.
 *
 * Content that survives conversion:
 * - text blocks (always)
 * - tool_use blocks (always)
 * - thinking blocks WITH signatures (extended thinking models like Opus 4.5)
 */
function hasContentSurvivingConversion(content: AssistantContent[]): boolean {
  return content.some(block => {
    if (!block || typeof block !== 'object') return false;
    const type = block.type;

    // text and tool_use blocks always survive
    if (type === 'text' || type === 'tool_use') return true;

    // thinking blocks only survive if they have a signature (extended thinking)
    if (type === 'thinking') {
      return typeof (block as { signature?: string }).signature === 'string' &&
             (block as { signature?: string }).signature!.length > 0;
    }

    // Unknown block types - be permissive and keep them
    return true;
  });
}

/**
 * Check if an assistant message has valid non-empty content.
 * Also checks that the content will survive API conversion (thinking-only messages
 * without signatures will become empty and are therefore invalid).
 */
function isValidAssistantMessage(msg: AssistantMessage): boolean {
  if (!Array.isArray(msg.content)) {
    return false;
  }
  if (msg.content.length === 0) {
    return false;
  }
  // Must have content that survives API conversion
  return hasContentSurvivingConversion(msg.content);
}

/**
 * Check if a tool result message has valid required fields.
 */
function isValidToolResultMessage(msg: ToolResultMessage): boolean {
  return typeof msg.toolCallId === 'string' && msg.toolCallId.length > 0;
}

/**
 * Check if a message is valid (non-empty and well-formed).
 */
function isValidMessage(msg: Message): boolean {
  if (!msg || typeof msg !== 'object' || !msg.role) {
    return false;
  }

  switch (msg.role) {
    case 'user':
      return isValidUserMessage(msg as UserMessage);
    case 'assistant':
      return isValidAssistantMessage(msg as AssistantMessage);
    case 'toolResult':
      return isValidToolResultMessage(msg as ToolResultMessage);
    default:
      return false;
  }
}

/**
 * Extract all tool_use IDs from an assistant message.
 */
function extractToolUseIds(msg: AssistantMessage): string[] {
  if (!Array.isArray(msg.content)) {
    return [];
  }

  return msg.content
    .filter((block): block is ToolCall =>
      block != null &&
      isToolCall(block) &&
      block.id.length > 0
    )
    .map(block => block.id);
}

// =============================================================================
// Main Functions
// =============================================================================

/**
 * Sanitize messages to guarantee API compliance.
 *
 * This is the SINGLE SOURCE OF TRUTH for message validity.
 * It can accept ANY input (including completely malformed) and
 * will always produce a valid Message[] that can be converted
 * to any provider format.
 *
 * @param messages - Input messages (may be malformed)
 * @returns Sanitized messages with list of fixes applied
 */
export function sanitizeMessages(messages: Message[]): SanitizationResult {
  const fixes: SanitizationFix[] = [];

  // Handle invalid input gracefully
  if (!Array.isArray(messages)) {
    logger.warn('sanitizeMessages received non-array input', { type: typeof messages });
    return { messages: [], fixes: [], isValid: true };
  }

  // PHASE 1: Filter invalid messages, deduplicate tool_use IDs, and build valid message list
  const validMessages: Message[] = [];
  const toolUseLocations = new Map<string, number>(); // toolUseId → index in validMessages where assistant is
  const seenToolUseIds = new Set<string>(); // For deduplication across messages

  for (const msg of messages) {
    if (!isValidMessage(msg)) {
      // Determine the specific reason for removal
      let fixType: SanitizationFixType = 'removed_empty_message';

      // Check if this is a thinking-only assistant message
      if (msg?.role === 'assistant' && Array.isArray((msg as AssistantMessage).content)) {
        const content = (msg as AssistantMessage).content;
        if (content.length > 0 && !hasContentSurvivingConversion(content)) {
          fixType = 'removed_thinking_only_message';
          logger.warn('Removed assistant message with only thinking blocks (no signature)', {
            blockCount: content.length,
            blockTypes: content.map((b: AssistantContent) => b?.type),
          });
        }
      }

      fixes.push({
        type: fixType,
        details: { role: msg?.role ?? 'unknown' },
      });
      continue;
    }

    const cloned = cloneMessage(msg);

    // Deduplicate tool_use blocks within assistant messages
    if (cloned.role === 'assistant') {
      const assistantMsg = cloned as AssistantMessage;
      const originalLength = assistantMsg.content.length;
      assistantMsg.content = assistantMsg.content.filter(block => {
        if (isToolCall(block)) {
          if (seenToolUseIds.has(block.id)) {
            fixes.push({
              type: 'removed_duplicate_tool_use',
              details: { toolUseId: block.id },
            });
            logger.warn('Removed duplicate tool_use block', { toolUseId: block.id });
            return false;
          }
          seenToolUseIds.add(block.id);
        }
        return true;
      });

      // If message became empty after dedup, skip it
      if (!isValidAssistantMessage(assistantMsg)) {
        if (originalLength > 0) {
          fixes.push({
            type: 'removed_empty_message',
            details: { role: 'assistant', reason: 'empty_after_dedup' },
          });
        }
        continue;
      }
    }

    const index = validMessages.length;
    validMessages.push(cloned);

    // Track tool_use locations for later injection
    if (cloned.role === 'assistant') {
      const toolUseIds = extractToolUseIds(cloned as AssistantMessage);
      for (const id of toolUseIds) {
        toolUseLocations.set(id, index);
      }
    }
  }

  // PHASE 2: Collect existing tool result IDs
  const existingToolResultIds = new Set<string>();
  for (const msg of validMessages) {
    if (msg.role === 'toolResult') {
      existingToolResultIds.add((msg as ToolResultMessage).toolCallId);
    }
  }

  // PHASE 3: Find missing tool results and inject synthetic ones
  // We need to inject after each assistant message that has unmatched tool_use blocks
  // Work backwards to maintain correct indices during insertion
  const missingByAssistantIndex = new Map<number, string[]>();

  for (const [toolUseId, assistantIndex] of toolUseLocations) {
    if (!existingToolResultIds.has(toolUseId)) {
      const existing = missingByAssistantIndex.get(assistantIndex) || [];
      existing.push(toolUseId);
      missingByAssistantIndex.set(assistantIndex, existing);
    }
  }

  // Sort by assistant index descending so we can insert without shifting issues
  const sortedIndices = [...missingByAssistantIndex.keys()].sort((a, b) => b - a);

  for (const assistantIndex of sortedIndices) {
    const missingIds = missingByAssistantIndex.get(assistantIndex)!;

    // Insert synthetic tool results immediately after the assistant message
    // Insert in reverse order of the missing IDs to maintain original tool_use order
    for (let i = missingIds.length - 1; i >= 0; i--) {
      const toolCallId = missingIds[i]!;
      const syntheticResult: ToolResultMessage = {
        role: 'toolResult',
        toolCallId,
        content: INTERRUPTED_CONTENT,
        isError: false,
      };

      validMessages.splice(assistantIndex + 1, 0, syntheticResult);

      fixes.push({
        type: 'injected_tool_result',
        details: { toolCallId, afterIndex: assistantIndex },
      });

      logger.warn('Injected synthetic tool result for interrupted execution', { toolCallId });
    }
  }

  // PHASE 4: Ensure first message is user (for API compliance after conversion)
  if (validMessages.length > 0 && validMessages[0]!.role !== 'user') {
    validMessages.unshift({
      role: 'user',
      content: PLACEHOLDER_USER_CONTENT,
    });

    fixes.push({
      type: 'injected_placeholder_user',
      details: {},
    });

    logger.warn('Injected placeholder user message at start');
  }

  // PHASE 5: Merge consecutive same-role messages (except toolResult)
  // This catches any source of consecutive same-role messages, including
  // those created by removing thinking-only messages or dedup operations.
  const mergedMessages: Message[] = [];
  for (const msg of validMessages) {
    const prev = mergedMessages[mergedMessages.length - 1];
    if (prev && prev.role === msg.role && msg.role !== 'toolResult') {
      if (msg.role === 'assistant') {
        // Merge assistant: concatenate content arrays
        const prevAssistant = prev as AssistantMessage;
        const curAssistant = msg as AssistantMessage;
        prevAssistant.content = [...prevAssistant.content, ...curAssistant.content];
      } else if (msg.role === 'user') {
        // Merge user: normalize both to array format then concatenate
        const prevUser = prev as UserMessage;
        const curUser = msg as UserMessage;
        const prevContent = typeof prevUser.content === 'string'
          ? [{ type: 'text' as const, text: prevUser.content }]
          : Array.isArray(prevUser.content) ? prevUser.content : [];
        const curContent = typeof curUser.content === 'string'
          ? [{ type: 'text' as const, text: curUser.content }]
          : Array.isArray(curUser.content) ? curUser.content : [];
        prevUser.content = [...prevContent, ...curContent] as UserMessage['content'];
      }
      fixes.push({
        type: 'merged_consecutive_messages',
        details: { role: msg.role },
      });
      logger.warn('Merged consecutive same-role messages', { role: msg.role });
    } else {
      mergedMessages.push(msg);
    }
  }

  return {
    messages: mergedMessages,
    fixes,
    isValid: fixes.length === 0,
  };
}

/**
 * Validate messages without fixing.
 * Returns list of violations found.
 *
 * Use this for diagnostics/logging without modifying messages.
 *
 * @param messages - Messages to validate
 * @returns List of validation violations
 */
export function validateMessages(messages: Message[]): ValidationViolation[] {
  const violations: ValidationViolation[] = [];

  if (!Array.isArray(messages)) {
    return violations;
  }

  // Collect tool_use IDs and existing tool result IDs
  const toolUseIds = new Set<string>();
  const toolResultIds = new Set<string>();

  for (const msg of messages) {
    if (!isValidMessage(msg)) {
      violations.push({
        type: 'empty_message',
        details: { role: msg?.role ?? 'unknown' },
      });
      continue;
    }

    if (msg.role === 'assistant') {
      const ids = extractToolUseIds(msg as AssistantMessage);
      for (const id of ids) {
        toolUseIds.add(id);
      }
    }

    if (msg.role === 'toolResult') {
      const trMsg = msg as ToolResultMessage;
      if (!trMsg.toolCallId) {
        violations.push({
          type: 'invalid_tool_result',
          details: { reason: 'missing toolCallId' },
        });
      } else {
        toolResultIds.add(trMsg.toolCallId);
      }
    }
  }

  // Check for missing tool results
  for (const id of toolUseIds) {
    if (!toolResultIds.has(id)) {
      violations.push({
        type: 'missing_tool_result',
        details: { toolCallId: id },
      });
    }
  }

  // Check first message is user
  const validMessages = messages.filter(isValidMessage);
  if (validMessages.length > 0 && validMessages[0]!.role !== 'user') {
    violations.push({
      type: 'missing_first_user',
      details: { firstRole: validMessages[0]!.role },
    });
  }

  return violations;
}
