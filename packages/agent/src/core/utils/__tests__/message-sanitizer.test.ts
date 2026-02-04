/**
 * @fileoverview Message Sanitizer Tests
 *
 * Comprehensive test suite for the message sanitizer - the single source of truth
 * for message validity before API submission.
 *
 * Test categories:
 * 1. Invariant tests - properties that must always hold
 * 2. Edge case tests - boundary conditions and unusual inputs
 * 3. Regression tests - real-world failure scenarios
 * 4. Integration tests - works with provider converters
 */

import { describe, it, expect } from 'vitest';
import type { Message, UserMessage, AssistantMessage, ToolResultMessage } from '@core/types/messages.js';
import { sanitizeMessages, validateMessages, type SanitizationFix } from '../message-sanitizer.js';

// =============================================================================
// Test Helpers
// =============================================================================

function createUserMessage(content: string | object[]): UserMessage {
  return { role: 'user', content: content as UserMessage['content'] };
}

function createAssistantMessage(content: object[]): AssistantMessage {
  return { role: 'assistant', content: content as AssistantMessage['content'] };
}

function createToolResult(toolCallId: string, content: string, isError = false): ToolResultMessage {
  return { role: 'toolResult', toolCallId, content, isError };
}

function createToolUse(id: string, name: string, args: Record<string, unknown> = {}) {
  return { type: 'tool_use' as const, id, name, arguments: args };
}

function createText(text: string) {
  return { type: 'text' as const, text };
}

function createThinking(thinking: string, signature?: string) {
  return { type: 'thinking' as const, thinking, ...(signature && { signature }) };
}

// =============================================================================
// 1. Invariant Tests
// =============================================================================

describe('sanitizeMessages invariants', () => {
  describe('tool_use/toolResult matching', () => {
    it('should ensure every tool_use has a toolResult in output', () => {
      const messages: Message[] = [
        createUserMessage('Hello'),
        createAssistantMessage([
          createText('Let me help'),
          createToolUse('call_1', 'ReadFile', { path: '/test' }),
        ]),
        // Missing toolResult
        createUserMessage('Continue'),
      ];

      const result = sanitizeMessages(messages);

      // Collect all tool_use IDs
      const toolUseIds = new Set<string>();
      for (const msg of result.messages) {
        if (msg.role === 'assistant') {
          for (const block of msg.content as any[]) {
            if (block.type === 'tool_use') {
              toolUseIds.add(block.id);
            }
          }
        }
      }

      // Verify all have corresponding toolResult
      const toolResultIds = new Set<string>();
      for (const msg of result.messages) {
        if (msg.role === 'toolResult') {
          toolResultIds.add((msg as ToolResultMessage).toolCallId);
        }
      }

      for (const id of toolUseIds) {
        expect(toolResultIds.has(id)).toBe(true);
      }
    });

    it('should inject synthetic toolResult for missing tool results', () => {
      const messages: Message[] = [
        createUserMessage('Hello'),
        createAssistantMessage([
          createToolUse('call_missing', 'SomeTool'),
        ]),
        createUserMessage('New message'),
      ];

      const result = sanitizeMessages(messages);

      expect(result.isValid).toBe(false);
      expect(result.fixes.some(f => f.type === 'injected_tool_result')).toBe(true);

      // Should have synthetic toolResult
      const toolResults = result.messages.filter(m => m.role === 'toolResult');
      expect(toolResults.length).toBe(1);
      expect((toolResults[0] as ToolResultMessage).toolCallId).toBe('call_missing');
    });
  });

  describe('idempotency', () => {
    it('should produce same result when called twice', () => {
      const messages: Message[] = [
        createUserMessage('Hello'),
        createAssistantMessage([createToolUse('call_1', 'Tool')]),
        // Missing toolResult
      ];

      const first = sanitizeMessages(messages);
      const second = sanitizeMessages(first.messages);

      expect(second.messages).toEqual(first.messages);
      expect(second.isValid).toBe(true); // Second call should find no issues
    });

    it('should be idempotent for already valid messages', () => {
      const messages: Message[] = [
        createUserMessage('Hello'),
        createAssistantMessage([createText('Hi there')]),
      ];

      const first = sanitizeMessages(messages);
      const second = sanitizeMessages(first.messages);

      expect(second.messages).toEqual(first.messages);
      expect(first.isValid).toBe(true);
      expect(second.isValid).toBe(true);
    });
  });

  describe('never throws', () => {
    it('should handle null input gracefully', () => {
      expect(() => sanitizeMessages(null as any)).not.toThrow();
    });

    it('should handle undefined input gracefully', () => {
      expect(() => sanitizeMessages(undefined as any)).not.toThrow();
    });

    it('should handle non-array input gracefully', () => {
      expect(() => sanitizeMessages('not an array' as any)).not.toThrow();
      expect(() => sanitizeMessages({} as any)).not.toThrow();
      expect(() => sanitizeMessages(123 as any)).not.toThrow();
    });

    it('should handle messages with missing fields', () => {
      const malformed = [
        { role: 'user' }, // missing content
        { content: 'test' }, // missing role
        { role: 'assistant', content: null },
        { role: 'toolResult' }, // missing toolCallId
      ];

      expect(() => sanitizeMessages(malformed as any)).not.toThrow();
    });
  });

  describe('preserves valid messages', () => {
    it('should not modify valid messages', () => {
      const messages: Message[] = [
        createUserMessage('Hello'),
        createAssistantMessage([createText('Hi'), createToolUse('call_1', 'Tool')]),
        createToolResult('call_1', 'Result'),
        createAssistantMessage([createText('Done')]),
      ];

      const result = sanitizeMessages(messages);

      expect(result.isValid).toBe(true);
      expect(result.fixes).toHaveLength(0);
      expect(result.messages).toHaveLength(4);
    });

    it('should preserve message content exactly', () => {
      const originalContent = [
        createText('Complex content'),
        createToolUse('call_1', 'Tool', { nested: { key: 'value' } }),
      ];
      const messages: Message[] = [
        createUserMessage('Start'),
        createAssistantMessage(originalContent),
        createToolResult('call_1', 'Result with special chars: <>&"\''),
      ];

      const result = sanitizeMessages(messages);

      const assistantMsg = result.messages.find(m => m.role === 'assistant') as AssistantMessage;
      expect(assistantMsg.content).toEqual(originalContent);
    });
  });
});

// =============================================================================
// 2. Edge Case Tests
// =============================================================================

describe('sanitizeMessages edge cases', () => {
  describe('empty and minimal inputs', () => {
    it('should handle empty array', () => {
      const result = sanitizeMessages([]);
      expect(result.messages).toEqual([]);
      expect(result.isValid).toBe(true);
    });

    it('should handle single user message', () => {
      const messages: Message[] = [createUserMessage('Hello')];
      const result = sanitizeMessages(messages);

      expect(result.messages).toHaveLength(1);
      expect(result.isValid).toBe(true);
    });

    it('should handle single assistant message', () => {
      const messages: Message[] = [createAssistantMessage([createText('Hi')])];
      const result = sanitizeMessages(messages);

      // Should inject placeholder user message at start
      expect(result.messages[0].role).toBe('user');
      expect(result.fixes.some(f => f.type === 'injected_placeholder_user')).toBe(true);
    });
  });

  describe('multiple tool calls', () => {
    it('should handle assistant with multiple tool_use, all missing results', () => {
      const messages: Message[] = [
        createUserMessage('Do multiple things'),
        createAssistantMessage([
          createToolUse('call_1', 'Tool1'),
          createToolUse('call_2', 'Tool2'),
          createToolUse('call_3', 'Tool3'),
        ]),
        createUserMessage('Next'),
      ];

      const result = sanitizeMessages(messages);

      // Should inject 3 synthetic toolResults
      const toolResults = result.messages.filter(m => m.role === 'toolResult');
      expect(toolResults.length).toBe(3);

      const ids = toolResults.map(m => (m as ToolResultMessage).toolCallId);
      expect(ids).toContain('call_1');
      expect(ids).toContain('call_2');
      expect(ids).toContain('call_3');
    });

    it('should handle partial missing results', () => {
      const messages: Message[] = [
        createUserMessage('Do things'),
        createAssistantMessage([
          createToolUse('call_1', 'Tool1'),
          createToolUse('call_2', 'Tool2'),
        ]),
        createToolResult('call_1', 'Result 1'), // Only first has result
        createUserMessage('Next'),
      ];

      const result = sanitizeMessages(messages);

      // Should inject 1 synthetic toolResult for call_2
      const toolResults = result.messages.filter(m => m.role === 'toolResult');
      expect(toolResults.length).toBe(2);

      const realResult = toolResults.find(m => (m as ToolResultMessage).toolCallId === 'call_1');
      const syntheticResult = toolResults.find(m => (m as ToolResultMessage).toolCallId === 'call_2');

      expect((realResult as ToolResultMessage).content).toBe('Result 1');
      expect((syntheticResult as ToolResultMessage).content).toContain('Interrupted');
    });
  });

  describe('empty messages', () => {
    it('should remove empty user messages', () => {
      const messages: Message[] = [
        createUserMessage(''),
        createUserMessage('Valid'),
      ];

      const result = sanitizeMessages(messages);

      expect(result.messages).toHaveLength(1);
      expect((result.messages[0] as UserMessage).content).toBe('Valid');
      expect(result.fixes.some(f => f.type === 'removed_empty_message')).toBe(true);
    });

    it('should remove assistant messages with empty content array', () => {
      const messages: Message[] = [
        createUserMessage('Hello'),
        createAssistantMessage([]),
        createAssistantMessage([createText('Valid')]),
      ];

      const result = sanitizeMessages(messages);

      expect(result.messages).toHaveLength(2);
      expect(result.fixes.some(f => f.type === 'removed_empty_message')).toBe(true);
    });

    it('should remove toolResult with empty toolCallId', () => {
      const messages: Message[] = [
        createUserMessage('Hello'),
        createToolResult('', 'Some result'),
      ];

      const result = sanitizeMessages(messages);

      expect(result.messages.filter(m => m.role === 'toolResult')).toHaveLength(0);
    });
  });

  describe('ordering', () => {
    it('should place synthetic toolResult after assistant message', () => {
      const messages: Message[] = [
        createUserMessage('Hello'),
        createAssistantMessage([createToolUse('call_1', 'Tool')]),
        createUserMessage('Continue'),
      ];

      const result = sanitizeMessages(messages);

      // Order should be: user, assistant, toolResult, user
      expect(result.messages[0].role).toBe('user');
      expect(result.messages[1].role).toBe('assistant');
      expect(result.messages[2].role).toBe('toolResult');
      expect(result.messages[3].role).toBe('user');
    });
  });

  describe('complex scenarios', () => {
    it('should handle agentic loop with multiple turns', () => {
      const messages: Message[] = [
        createUserMessage('Start'),
        createAssistantMessage([createToolUse('call_1', 'Tool1')]),
        createToolResult('call_1', 'Result 1'),
        createAssistantMessage([createToolUse('call_2', 'Tool2')]),
        createToolResult('call_2', 'Result 2'),
        createAssistantMessage([createText('Done')]),
      ];

      const result = sanitizeMessages(messages);

      expect(result.isValid).toBe(true);
      expect(result.messages).toHaveLength(6);
    });

    it('should handle interrupted mid-agentic-loop', () => {
      const messages: Message[] = [
        createUserMessage('Start'),
        createAssistantMessage([createToolUse('call_1', 'Tool1')]),
        createToolResult('call_1', 'Result 1'),
        createAssistantMessage([createToolUse('call_2', 'Tool2')]),
        // Interrupted here - no result for call_2
        createUserMessage('New prompt'),
      ];

      const result = sanitizeMessages(messages);

      // Should inject synthetic result for call_2
      expect(result.messages).toHaveLength(6);
      const toolResults = result.messages.filter(m => m.role === 'toolResult');
      expect(toolResults.length).toBe(2);
    });
  });
});

// =============================================================================
// 2b. Thinking Block Tests
// =============================================================================

describe('sanitizeMessages thinking blocks', () => {
  describe('thinking-only messages (no signature)', () => {
    it('should remove assistant messages with only thinking blocks (no signature)', () => {
      // This is the exact bug from session forking:
      // An interrupted session may have an assistant message with ONLY a thinking block
      // When this thinking block has no signature (non-extended thinking models like Haiku),
      // it will be filtered out during conversion, leaving empty content.
      const messages: Message[] = [
        createUserMessage('Hello'),
        createAssistantMessage([createThinking('I am pondering this...')]),
        createAssistantMessage([createText('Valid response')]),
      ];

      const result = sanitizeMessages(messages);

      expect(result.messages).toHaveLength(2);
      expect(result.messages[0]!.role).toBe('user');
      expect(result.messages[1]!.role).toBe('assistant');
      // The remaining assistant message should be the valid one with text
      expect((result.messages[1] as AssistantMessage).content).toEqual([createText('Valid response')]);
      expect(result.fixes.some(f => f.type === 'removed_thinking_only_message')).toBe(true);
    });

    it('should remove thinking-only messages in the middle of a conversation', () => {
      // Real scenario from forked session: thinking-only message sandwiched between valid messages
      const messages: Message[] = [
        createUserMessage('Hey'),
        createAssistantMessage([createThinking('Greeting...'), createText('Hi there!')]),
        createUserMessage('What\'s up'),
        createAssistantMessage([createThinking('Just thinking...')]), // This was interrupted
        createUserMessage('New prompt'),
        createAssistantMessage([createText('I can help with that')]),
      ];

      const result = sanitizeMessages(messages);

      // Should have 5 messages (thinking-only removed)
      expect(result.messages).toHaveLength(5);
      expect(result.messages.map(m => m.role)).toEqual([
        'user', 'assistant', 'user', 'user', 'assistant',
      ]);
      expect(result.fixes.some(f => f.type === 'removed_thinking_only_message')).toBe(true);
    });

    it('should NOT remove assistant messages with thinking that has a signature', () => {
      // Extended thinking models (Opus 4.5) provide signatures - these MUST be preserved
      const messages: Message[] = [
        createUserMessage('Hello'),
        createAssistantMessage([createThinking('Deep thinking...', 'sig_abc123')]),
      ];

      const result = sanitizeMessages(messages);

      expect(result.messages).toHaveLength(2);
      expect(result.isValid).toBe(true);
      expect(result.fixes).toHaveLength(0);
    });

    it('should preserve messages with both thinking and text', () => {
      const messages: Message[] = [
        createUserMessage('Hello'),
        createAssistantMessage([
          createThinking('Let me think...'),
          createText('Here is my response'),
        ]),
      ];

      const result = sanitizeMessages(messages);

      expect(result.messages).toHaveLength(2);
      expect(result.isValid).toBe(true);
      expect(result.fixes).toHaveLength(0);
    });

    it('should preserve messages with thinking and tool_use', () => {
      const messages: Message[] = [
        createUserMessage('Read a file'),
        createAssistantMessage([
          createThinking('I should read the file...'),
          createToolUse('call_1', 'ReadFile', { path: '/test' }),
        ]),
        createToolResult('call_1', 'file contents'),
      ];

      const result = sanitizeMessages(messages);

      expect(result.messages).toHaveLength(3);
      expect(result.isValid).toBe(true);
    });

    it('should handle multiple consecutive thinking-only messages', () => {
      const messages: Message[] = [
        createUserMessage('Start'),
        createAssistantMessage([createThinking('Thinking 1...')]),
        createAssistantMessage([createThinking('Thinking 2...')]),
        createAssistantMessage([createThinking('Thinking 3...')]),
        createAssistantMessage([createText('Finally a response')]),
      ];

      const result = sanitizeMessages(messages);

      expect(result.messages).toHaveLength(2);
      expect(result.fixes.filter(f => f.type === 'removed_thinking_only_message')).toHaveLength(3);
    });
  });

  describe('forked session regression', () => {
    it('should handle the exact forked session scenario', () => {
      // This reproduces the exact scenario from sess_303ac47a2c6a (fork of sess_696cd493332b)
      // Parent session had an interrupted assistant message with only thinking content
      const messages: Message[] = [
        createUserMessage('Hey'),
        createAssistantMessage([
          createThinking('The user just said "Hey" - a greeting'),
          createText('Hey! What\'s up?'),
        ]),
        createUserMessage('What\'s up'), // Merged consecutive user messages
        createAssistantMessage([
          createThinking('The user is just greeting me casually'), // NO TEXT - this was interrupted
        ]),
        createUserMessage('What can you do'),
        createAssistantMessage([
          createThinking('The user is asking what I can do'),
          createText('I can help with many things...'),
        ]),
      ];

      const result = sanitizeMessages(messages);

      // The thinking-only message should be removed
      expect(result.messages).toHaveLength(5);
      expect(result.fixes.some(f => f.type === 'removed_thinking_only_message')).toBe(true);

      // Verify the structure is valid for API
      const roles = result.messages.map(m => m.role);
      // User messages will be merged since they're consecutive after removal
      expect(roles[0]).toBe('user');
      expect(roles[1]).toBe('assistant');
    });
  });
});

// =============================================================================
// 3. Regression Tests
// =============================================================================

describe('sanitizeMessages regressions', () => {
  describe('interrupted blocking subagent scenario', () => {
    it('should handle the original bug: assistant with tool_use, no result, then user message', () => {
      // This is the exact scenario that caused the original bug:
      // 1. User sends prompt
      // 2. Agent calls SpawnSubagent tool (blocking)
      // 3. User interrupts (presses stop)
      // 4. User sends new prompt
      // 5. No tool.result was ever persisted
      // Result: API error "tool_use without tool_result"

      const messages: Message[] = [
        createUserMessage('Research something'),
        createAssistantMessage([
          createText('I will research this for you.'),
          createToolUse('toolu_01ABC', 'SpawnSubagent', {
            prompt: 'Research topic',
            blocking: true,
          }),
        ]),
        // NO toolResult - session was interrupted
        createUserMessage('Actually, do something else'),
      ];

      const result = sanitizeMessages(messages);

      // Must have synthetic toolResult
      expect(result.messages.some(m =>
        m.role === 'toolResult' &&
        (m as ToolResultMessage).toolCallId === 'toolu_01ABC'
      )).toBe(true);

      // Must be valid for API
      expect(result.isValid).toBe(false); // Had to fix something
      expect(result.fixes.some(f => f.type === 'injected_tool_result')).toBe(true);
    });
  });

  describe('preserves existing behavior', () => {
    it('should preserve normal agentic flow unchanged', () => {
      // Normal flow: user -> assistant(tool_use) -> toolResult -> assistant
      const messages: Message[] = [
        createUserMessage('Read a file'),
        createAssistantMessage([
          createText('I will read the file.'),
          createToolUse('call_123', 'ReadFile', { path: '/test.txt' }),
        ]),
        createToolResult('call_123', 'File contents here'),
        createAssistantMessage([createText('The file contains...')]),
      ];

      const result = sanitizeMessages(messages);

      expect(result.isValid).toBe(true);
      expect(result.messages).toEqual(messages);
    });

    it('should preserve user message that replaces agentic continuation', () => {
      // When user sends a message after tool execution but before agent processes result,
      // the user's message "replaces" the agentic continuation
      const messages: Message[] = [
        createUserMessage('Read a file'),
        createAssistantMessage([createToolUse('call_1', 'ReadFile')]),
        createToolResult('call_1', 'File contents'),
        // User sends new message instead of letting agent continue
        createUserMessage('Actually, write to the file instead'),
      ];

      const result = sanitizeMessages(messages);

      expect(result.isValid).toBe(true);
      expect(result.messages).toHaveLength(4);
    });
  });
});

// =============================================================================
// 4. validateMessages Tests
// =============================================================================

describe('validateMessages', () => {
  it('should return empty array for valid messages', () => {
    const messages: Message[] = [
      createUserMessage('Hello'),
      createAssistantMessage([createText('Hi')]),
    ];

    const violations = validateMessages(messages);
    expect(violations).toHaveLength(0);
  });

  it('should detect missing tool results', () => {
    const messages: Message[] = [
      createUserMessage('Hello'),
      createAssistantMessage([createToolUse('call_1', 'Tool')]),
      createUserMessage('Next'),
    ];

    const violations = validateMessages(messages);
    expect(violations.some(v => v.type === 'missing_tool_result')).toBe(true);
  });

  it('should detect empty messages', () => {
    const messages: Message[] = [
      createUserMessage(''),
      createAssistantMessage([]),
    ];

    const violations = validateMessages(messages);
    expect(violations.some(v => v.type === 'empty_message')).toBe(true);
  });
});

// =============================================================================
// 5. Integration with Reconstructor Output
// =============================================================================

describe('integration with message reconstruction', () => {
  it('should fix reconstruction output where tool result was discarded by user interruption', () => {
    // This simulates what the reconstructor outputs when:
    // 1. Assistant called a tool
    // 2. Tool executed (tool.result event exists)
    // 3. User sent a new message, causing tool result to be discarded
    //
    // Reconstructor output: [user, assistant(tool_use), user]
    // The sanitizer must inject a synthetic tool result for API compliance
    const reconstructorOutput: Message[] = [
      createUserMessage('Use a tool'),
      createAssistantMessage([
        createText('I will use a tool.'),
        createToolUse('call_123', 'ReadFile', { path: '/test' }),
      ]),
      // Note: NO toolResult - reconstructor discarded it when user message arrived
      createUserMessage('Actually, do something else'),
    ];

    const result = sanitizeMessages(reconstructorOutput);

    // Should inject synthetic tool result
    expect(result.isValid).toBe(false);
    expect(result.fixes.some(f => f.type === 'injected_tool_result')).toBe(true);

    // Output should be: user, assistant, toolResult, user
    expect(result.messages).toHaveLength(4);
    expect(result.messages[0]!.role).toBe('user');
    expect(result.messages[1]!.role).toBe('assistant');
    expect(result.messages[2]!.role).toBe('toolResult');
    expect(result.messages[3]!.role).toBe('user');

    // The synthetic result should have the correct toolCallId
    const toolResult = result.messages[2] as ToolResultMessage;
    expect(toolResult.toolCallId).toBe('call_123');
  });

  it('should handle reconstruction output with multiple consecutive assistant messages', () => {
    // Edge case: reconstructor might merge assistant messages
    const reconstructorOutput: Message[] = [
      createUserMessage('Start'),
      createAssistantMessage([
        createText('First part'),
        createToolUse('call_1', 'Tool1'),
        createText('Second part'),
        createToolUse('call_2', 'Tool2'),
      ]),
      createUserMessage('Continue'),
    ];

    const result = sanitizeMessages(reconstructorOutput);

    // Should inject 2 synthetic tool results
    expect(result.messages.filter(m => m.role === 'toolResult')).toHaveLength(2);
  });
});
