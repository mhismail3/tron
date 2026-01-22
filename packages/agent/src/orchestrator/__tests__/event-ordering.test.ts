/**
 * @fileoverview Event Ordering Tests for Linear Event Chain
 *
 * These tests verify that events are recorded in logical order for proper
 * message reconstruction, especially for forked sessions.
 *
 * The Anthropic API requires:
 * - Assistant messages with tool_use blocks MUST come BEFORE tool.result
 * - Order: message.assistant (with tool_use) → tool.call → tool.result
 *
 * Previously, tool.call/tool.result events were created BEFORE message.assistant
 * because message.assistant was consolidated at turn END. This caused fork
 * reconstruction to fail.
 *
 * The fix: Flush accumulated assistant content as message.assistant BEFORE
 * creating tool.call events (at first tool_execution_start).
 */
import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest';
import { EventStore, SessionId, type TronSessionEvent } from '../../events/event-store.js';
import path from 'path';
import os from 'os';
import fs from 'fs';

// =============================================================================
// Helper Functions
// =============================================================================

/**
 * Get events of specific types in order from a session.
 */
async function getEventsByTypes(
  eventStore: EventStore,
  sessionId: SessionId,
  types: string[]
): Promise<TronSessionEvent[]> {
  const events = await eventStore.getEventsBySession(sessionId);
  return events
    .filter(e => types.includes(e.type))
    .sort((a, b) => a.sequence - b.sequence);
}

/**
 * Verify that message.assistant events with tool_use come before their corresponding
 * tool.call and tool.result events.
 */
function verifyToolCallOrdering(events: TronSessionEvent[]): {
  isValid: boolean;
  violations: string[];
} {
  const violations: string[] = [];

  // Track which tool_use IDs we've seen in message.assistant events
  const seenToolUseIds = new Set<string>();

  for (const event of events) {
    if (event.type === 'message.assistant') {
      const content = (event.payload as any).content;
      if (Array.isArray(content)) {
        for (const block of content) {
          if (block.type === 'tool_use' && block.id) {
            seenToolUseIds.add(block.id);
          }
        }
      }
    } else if (event.type === 'tool.call') {
      const toolCallId = (event.payload as any).toolCallId;
      if (!seenToolUseIds.has(toolCallId)) {
        violations.push(
          `tool.call for ${toolCallId} appears before message.assistant with tool_use`
        );
      }
    } else if (event.type === 'tool.result') {
      const toolCallId = (event.payload as any).toolCallId;
      if (!seenToolUseIds.has(toolCallId)) {
        violations.push(
          `tool.result for ${toolCallId} appears before message.assistant with tool_use`
        );
      }
    }
  }

  return {
    isValid: violations.length === 0,
    violations,
  };
}

/**
 * Get the order of event types (useful for debugging).
 */
function getEventTypeOrder(events: TronSessionEvent[]): string[] {
  return events.map(e => e.type);
}

// =============================================================================
// Event Ordering Tests
// =============================================================================

describe('Event Ordering - Linear Chain', () => {
  let eventStore: EventStore;
  let testDir: string;
  let sessionId: SessionId;

  beforeEach(async () => {
    testDir = fs.mkdtempSync(path.join(os.tmpdir(), 'tron-event-ordering-test-'));
    const dbPath = path.join(testDir, 'events.db');
    eventStore = new EventStore(dbPath);
    await eventStore.initialize();

    const result = await eventStore.createSession({
      workspacePath: '/test/project',
      workingDirectory: '/test/project',
      model: 'claude-sonnet-4-20250514',
    });
    sessionId = result.session.id;
  });

  afterEach(async () => {
    await eventStore.close();
    fs.rmSync(testDir, { recursive: true, force: true });
  });

  describe('Single tool call ordering', () => {
    it('should create message.assistant before tool.call for single tool', async () => {
      // User prompt
      await eventStore.append({
        sessionId,
        type: 'message.user',
        payload: { content: 'Read the file' },
      });

      // Turn start
      await eventStore.append({
        sessionId,
        type: 'stream.turn_start',
        payload: { turn: 1 },
      });

      // CORRECT ORDER: message.assistant (with tool_use) FIRST
      await eventStore.append({
        sessionId,
        type: 'message.assistant',
        payload: {
          content: [
            { type: 'text', text: 'Let me read that file.' },
            { type: 'tool_use', id: 'tc_1', name: 'Read', input: { file_path: 'test.ts' } },
          ],
          turn: 1,
          stopReason: 'tool_use',
        },
      });

      // THEN tool.call
      await eventStore.append({
        sessionId,
        type: 'tool.call',
        payload: {
          toolCallId: 'tc_1',
          name: 'Read',
          arguments: { file_path: 'test.ts' },
          turn: 1,
        },
      });

      // THEN tool.result
      await eventStore.append({
        sessionId,
        type: 'tool.result',
        payload: {
          toolCallId: 'tc_1',
          content: 'File contents here',
          isError: false,
        },
      });

      // Turn end
      await eventStore.append({
        sessionId,
        type: 'stream.turn_end',
        payload: { turn: 1, tokenUsage: { inputTokens: 100, outputTokens: 50 } },
      });

      // Verify ordering
      const events = await getEventsByTypes(eventStore, sessionId, [
        'message.assistant',
        'tool.call',
        'tool.result',
      ]);

      const result = verifyToolCallOrdering(events);
      expect(result.isValid).toBe(true);
      expect(result.violations).toEqual([]);

      // Verify the specific order
      const order = getEventTypeOrder(events);
      expect(order).toEqual(['message.assistant', 'tool.call', 'tool.result']);
    });
  });

  describe('Multiple tool calls ordering', () => {
    it('should create one message.assistant before all tool.calls', async () => {
      await eventStore.append({
        sessionId,
        type: 'message.user',
        payload: { content: 'Read multiple files' },
      });

      await eventStore.append({
        sessionId,
        type: 'stream.turn_start',
        payload: { turn: 1 },
      });

      // CORRECT ORDER: message.assistant with ALL tool_use blocks FIRST
      await eventStore.append({
        sessionId,
        type: 'message.assistant',
        payload: {
          content: [
            { type: 'text', text: 'Reading files...' },
            { type: 'tool_use', id: 'tc_1', name: 'Read', input: { file_path: 'a.ts' } },
            { type: 'tool_use', id: 'tc_2', name: 'Read', input: { file_path: 'b.ts' } },
            { type: 'tool_use', id: 'tc_3', name: 'Read', input: { file_path: 'c.ts' } },
          ],
          turn: 1,
          stopReason: 'tool_use',
        },
      });

      // THEN all tool.call events
      await eventStore.append({
        sessionId,
        type: 'tool.call',
        payload: { toolCallId: 'tc_1', name: 'Read', arguments: { file_path: 'a.ts' }, turn: 1 },
      });
      await eventStore.append({
        sessionId,
        type: 'tool.call',
        payload: { toolCallId: 'tc_2', name: 'Read', arguments: { file_path: 'b.ts' }, turn: 1 },
      });
      await eventStore.append({
        sessionId,
        type: 'tool.call',
        payload: { toolCallId: 'tc_3', name: 'Read', arguments: { file_path: 'c.ts' }, turn: 1 },
      });

      // THEN all tool.result events
      await eventStore.append({
        sessionId,
        type: 'tool.result',
        payload: { toolCallId: 'tc_1', content: 'Contents A', isError: false },
      });
      await eventStore.append({
        sessionId,
        type: 'tool.result',
        payload: { toolCallId: 'tc_2', content: 'Contents B', isError: false },
      });
      await eventStore.append({
        sessionId,
        type: 'tool.result',
        payload: { toolCallId: 'tc_3', content: 'Contents C', isError: false },
      });

      await eventStore.append({
        sessionId,
        type: 'stream.turn_end',
        payload: { turn: 1, tokenUsage: { inputTokens: 200, outputTokens: 100 } },
      });

      // Verify ordering
      const events = await getEventsByTypes(eventStore, sessionId, [
        'message.assistant',
        'tool.call',
        'tool.result',
      ]);

      const result = verifyToolCallOrdering(events);
      expect(result.isValid).toBe(true);
      expect(result.violations).toEqual([]);

      // Verify the specific order: assistant first, then all calls, then all results
      const order = getEventTypeOrder(events);
      expect(order).toEqual([
        'message.assistant',
        'tool.call',
        'tool.call',
        'tool.call',
        'tool.result',
        'tool.result',
        'tool.result',
      ]);
    });
  });

  describe('Agentic multi-turn loop ordering', () => {
    it('should maintain correct ordering across agentic turns', async () => {
      await eventStore.append({
        sessionId,
        type: 'message.user',
        payload: { content: 'Do a multi-step task' },
      });

      // Turn 1
      await eventStore.append({
        sessionId,
        type: 'stream.turn_start',
        payload: { turn: 1 },
      });

      await eventStore.append({
        sessionId,
        type: 'message.assistant',
        payload: {
          content: [
            { type: 'text', text: 'Starting step 1...' },
            { type: 'tool_use', id: 'tc_1', name: 'Read', input: { file_path: 'config.json' } },
          ],
          turn: 1,
          stopReason: 'tool_use',
        },
      });

      await eventStore.append({
        sessionId,
        type: 'tool.call',
        payload: { toolCallId: 'tc_1', name: 'Read', arguments: { file_path: 'config.json' }, turn: 1 },
      });

      await eventStore.append({
        sessionId,
        type: 'tool.result',
        payload: { toolCallId: 'tc_1', content: '{"key": "value"}', isError: false },
      });

      await eventStore.append({
        sessionId,
        type: 'stream.turn_end',
        payload: { turn: 1, tokenUsage: { inputTokens: 100, outputTokens: 50 } },
      });

      // Turn 2 (agentic continuation)
      await eventStore.append({
        sessionId,
        type: 'stream.turn_start',
        payload: { turn: 2 },
      });

      await eventStore.append({
        sessionId,
        type: 'message.assistant',
        payload: {
          content: [
            { type: 'text', text: 'Now step 2...' },
            { type: 'tool_use', id: 'tc_2', name: 'Write', input: { file_path: 'output.json' } },
          ],
          turn: 2,
          stopReason: 'tool_use',
        },
      });

      await eventStore.append({
        sessionId,
        type: 'tool.call',
        payload: { toolCallId: 'tc_2', name: 'Write', arguments: { file_path: 'output.json' }, turn: 2 },
      });

      await eventStore.append({
        sessionId,
        type: 'tool.result',
        payload: { toolCallId: 'tc_2', content: 'File written', isError: false },
      });

      await eventStore.append({
        sessionId,
        type: 'stream.turn_end',
        payload: { turn: 2, tokenUsage: { inputTokens: 150, outputTokens: 75 } },
      });

      // Turn 3 (final response, no tools)
      await eventStore.append({
        sessionId,
        type: 'stream.turn_start',
        payload: { turn: 3 },
      });

      await eventStore.append({
        sessionId,
        type: 'message.assistant',
        payload: {
          content: [{ type: 'text', text: 'Task complete!' }],
          turn: 3,
          stopReason: 'end_turn',
        },
      });

      await eventStore.append({
        sessionId,
        type: 'stream.turn_end',
        payload: { turn: 3, tokenUsage: { inputTokens: 200, outputTokens: 100 } },
      });

      // Verify ordering across all turns
      const events = await getEventsByTypes(eventStore, sessionId, [
        'message.assistant',
        'tool.call',
        'tool.result',
      ]);

      const result = verifyToolCallOrdering(events);
      expect(result.isValid).toBe(true);
      expect(result.violations).toEqual([]);

      // Verify there are 3 assistant messages (one per turn)
      const assistantEvents = events.filter(e => e.type === 'message.assistant');
      expect(assistantEvents.length).toBe(3);
    });
  });

  describe('Forked session message reconstruction', () => {
    it('should reconstruct messages correctly for forked session with tools', async () => {
      // Create original session with tool calls
      await eventStore.append({
        sessionId,
        type: 'message.user',
        payload: { content: 'Read a file' },
      });

      await eventStore.append({
        sessionId,
        type: 'stream.turn_start',
        payload: { turn: 1 },
      });

      await eventStore.append({
        sessionId,
        type: 'message.assistant',
        payload: {
          content: [
            { type: 'text', text: 'Reading...' },
            { type: 'tool_use', id: 'tc_fork', name: 'Read', input: { file_path: 'test.ts' } },
          ],
          turn: 1,
          stopReason: 'tool_use',
        },
      });

      await eventStore.append({
        sessionId,
        type: 'tool.call',
        payload: { toolCallId: 'tc_fork', name: 'Read', arguments: { file_path: 'test.ts' }, turn: 1 },
      });

      await eventStore.append({
        sessionId,
        type: 'tool.result',
        payload: { toolCallId: 'tc_fork', content: 'File contents', isError: false },
      });

      await eventStore.append({
        sessionId,
        type: 'stream.turn_end',
        payload: { turn: 1, tokenUsage: { inputTokens: 100, outputTokens: 50 } },
      });

      // Agentic continuation
      await eventStore.append({
        sessionId,
        type: 'stream.turn_start',
        payload: { turn: 2 },
      });

      await eventStore.append({
        sessionId,
        type: 'message.assistant',
        payload: {
          content: [{ type: 'text', text: 'Here are the contents.' }],
          turn: 2,
          stopReason: 'end_turn',
        },
      });

      const turnEndEvent = await eventStore.append({
        sessionId,
        type: 'stream.turn_end',
        payload: { turn: 2, tokenUsage: { inputTokens: 150, outputTokens: 75 } },
      });

      // Fork from the turn_end event
      const forkResult = await eventStore.fork(turnEndEvent.id, { name: 'Test Fork' });

      // Get messages for the forked session
      const messages = await eventStore.getMessagesAtHead(forkResult.session.id);

      // Verify messages reconstruct properly for API
      // Expected: user → assistant(tool_use) → user(tool_result) → assistant
      expect(messages.length).toBe(4);

      expect(messages[0].role).toBe('user');
      expect(messages[0].content).toBe('Read a file');

      expect(messages[1].role).toBe('assistant');
      const assistantContent1 = messages[1].content as any[];
      expect(assistantContent1.some(b => b.type === 'tool_use')).toBe(true);

      expect(messages[2].role).toBe('user');
      const userToolResult = messages[2].content as any[];
      expect(userToolResult[0].type).toBe('tool_result');

      expect(messages[3].role).toBe('assistant');
      const assistantContent2 = messages[3].content as any[];
      expect(assistantContent2[0].text).toContain('contents');

      // Verify proper role alternation
      const roles = messages.map(m => m.role);
      for (let i = 0; i < roles.length - 1; i++) {
        expect(roles[i]).not.toBe(roles[i + 1]);
      }
    });
  });

  describe('No tools (no regression)', () => {
    it('should create message.assistant at turn_end when no tools', async () => {
      await eventStore.append({
        sessionId,
        type: 'message.user',
        payload: { content: 'Hello' },
      });

      await eventStore.append({
        sessionId,
        type: 'stream.turn_start',
        payload: { turn: 1 },
      });

      // No tools - just text response
      await eventStore.append({
        sessionId,
        type: 'message.assistant',
        payload: {
          content: [{ type: 'text', text: 'Hello! How can I help?' }],
          turn: 1,
          stopReason: 'end_turn',
        },
      });

      await eventStore.append({
        sessionId,
        type: 'stream.turn_end',
        payload: { turn: 1, tokenUsage: { inputTokens: 50, outputTokens: 25 } },
      });

      // Verify message reconstruction
      const messages = await eventStore.getMessagesAtHead(sessionId);

      expect(messages.length).toBe(2);
      expect(messages[0].role).toBe('user');
      expect(messages[1].role).toBe('assistant');
      expect((messages[1].content as any[])[0].text).toBe('Hello! How can I help?');
    });
  });

  describe('Resume session (no regression)', () => {
    it('should resume session with tool history correctly', async () => {
      // Create session with tool calls
      await eventStore.append({
        sessionId,
        type: 'message.user',
        payload: { content: 'Initial request' },
      });

      await eventStore.append({
        sessionId,
        type: 'stream.turn_start',
        payload: { turn: 1 },
      });

      await eventStore.append({
        sessionId,
        type: 'message.assistant',
        payload: {
          content: [
            { type: 'tool_use', id: 'tc_resume', name: 'Bash', input: { command: 'ls' } },
          ],
          turn: 1,
          stopReason: 'tool_use',
        },
      });

      await eventStore.append({
        sessionId,
        type: 'tool.call',
        payload: { toolCallId: 'tc_resume', name: 'Bash', arguments: { command: 'ls' }, turn: 1 },
      });

      await eventStore.append({
        sessionId,
        type: 'tool.result',
        payload: { toolCallId: 'tc_resume', content: 'file1.txt\nfile2.txt', isError: false },
      });

      await eventStore.append({
        sessionId,
        type: 'stream.turn_end',
        payload: { turn: 1, tokenUsage: { inputTokens: 100, outputTokens: 50 } },
      });

      // Agentic continuation
      await eventStore.append({
        sessionId,
        type: 'stream.turn_start',
        payload: { turn: 2 },
      });

      await eventStore.append({
        sessionId,
        type: 'message.assistant',
        payload: {
          content: [{ type: 'text', text: 'Found the files.' }],
          turn: 2,
          stopReason: 'end_turn',
        },
      });

      await eventStore.append({
        sessionId,
        type: 'stream.turn_end',
        payload: { turn: 2, tokenUsage: { inputTokens: 150, outputTokens: 75 } },
      });

      // "Resume" - add new user message
      await eventStore.append({
        sessionId,
        type: 'message.user',
        payload: { content: 'Now read file1.txt' },
      });

      // Verify messages can be reconstructed
      const messages = await eventStore.getMessagesAtHead(sessionId);

      // user → assistant(tool_use) → user(tool_result) → assistant → user
      expect(messages.length).toBe(5);

      const roles = messages.map(m => m.role);
      expect(roles).toEqual(['user', 'assistant', 'user', 'assistant', 'user']);

      // Verify last message is the new one
      expect(messages[4].content).toBe('Now read file1.txt');
    });
  });

  describe('Interleaved text and tools', () => {
    it('should handle text before and after tool_use in same message', async () => {
      await eventStore.append({
        sessionId,
        type: 'message.user',
        payload: { content: 'Check the config' },
      });

      await eventStore.append({
        sessionId,
        type: 'stream.turn_start',
        payload: { turn: 1 },
      });

      // Message with text → tool_use → text pattern
      await eventStore.append({
        sessionId,
        type: 'message.assistant',
        payload: {
          content: [
            { type: 'text', text: 'Let me check that config file.' },
            { type: 'tool_use', id: 'tc_interleave', name: 'Read', input: { file_path: 'config.json' } },
          ],
          turn: 1,
          stopReason: 'tool_use',
        },
      });

      await eventStore.append({
        sessionId,
        type: 'tool.call',
        payload: { toolCallId: 'tc_interleave', name: 'Read', arguments: { file_path: 'config.json' }, turn: 1 },
      });

      await eventStore.append({
        sessionId,
        type: 'tool.result',
        payload: { toolCallId: 'tc_interleave', content: '{"setting": true}', isError: false },
      });

      await eventStore.append({
        sessionId,
        type: 'stream.turn_end',
        payload: { turn: 1, tokenUsage: { inputTokens: 100, outputTokens: 50 } },
      });

      // Verify ordering
      const events = await getEventsByTypes(eventStore, sessionId, [
        'message.assistant',
        'tool.call',
        'tool.result',
      ]);

      const result = verifyToolCallOrdering(events);
      expect(result.isValid).toBe(true);

      // Verify message content has both text and tool_use
      const assistantEvent = events.find(e => e.type === 'message.assistant');
      const content = (assistantEvent?.payload as any).content;
      expect(content[0].type).toBe('text');
      expect(content[1].type).toBe('tool_use');
    });
  });
});

// =============================================================================
// Additional Edge Case Tests
// =============================================================================

describe('Event Ordering - Edge Cases', () => {
  let eventStore: EventStore;
  let testDir: string;
  let sessionId: SessionId;

  beforeEach(async () => {
    testDir = fs.mkdtempSync(path.join(os.tmpdir(), 'tron-event-ordering-edge-'));
    const dbPath = path.join(testDir, 'events.db');
    eventStore = new EventStore(dbPath);
    await eventStore.initialize();

    const result = await eventStore.createSession({
      workspacePath: '/test/project',
      workingDirectory: '/test/project',
      model: 'claude-sonnet-4-20250514',
    });
    sessionId = result.session.id;
  });

  afterEach(async () => {
    await eventStore.close();
    fs.rmSync(testDir, { recursive: true, force: true });
  });

  describe('Tool errors', () => {
    it('should maintain ordering for tool error results', async () => {
      await eventStore.append({
        sessionId,
        type: 'message.user',
        payload: { content: 'Run a bad command' },
      });

      await eventStore.append({
        sessionId,
        type: 'stream.turn_start',
        payload: { turn: 1 },
      });

      await eventStore.append({
        sessionId,
        type: 'message.assistant',
        payload: {
          content: [
            { type: 'tool_use', id: 'tc_error', name: 'Bash', input: { command: 'nonexistent' } },
          ],
          turn: 1,
          stopReason: 'tool_use',
        },
      });

      await eventStore.append({
        sessionId,
        type: 'tool.call',
        payload: { toolCallId: 'tc_error', name: 'Bash', arguments: { command: 'nonexistent' }, turn: 1 },
      });

      await eventStore.append({
        sessionId,
        type: 'tool.result',
        payload: { toolCallId: 'tc_error', content: 'Command not found: nonexistent', isError: true },
      });

      await eventStore.append({
        sessionId,
        type: 'stream.turn_end',
        payload: { turn: 1, tokenUsage: { inputTokens: 100, outputTokens: 50 } },
      });

      const events = await getEventsByTypes(eventStore, sessionId, [
        'message.assistant',
        'tool.call',
        'tool.result',
      ]);

      const result = verifyToolCallOrdering(events);
      expect(result.isValid).toBe(true);

      // Verify error flag is preserved
      const toolResult = events.find(e => e.type === 'tool.result');
      expect((toolResult?.payload as any).isError).toBe(true);
    });
  });

  describe('Empty tool result', () => {
    it('should handle empty tool result content', async () => {
      await eventStore.append({
        sessionId,
        type: 'message.user',
        payload: { content: 'Write an empty file' },
      });

      await eventStore.append({
        sessionId,
        type: 'stream.turn_start',
        payload: { turn: 1 },
      });

      await eventStore.append({
        sessionId,
        type: 'message.assistant',
        payload: {
          content: [
            { type: 'tool_use', id: 'tc_empty', name: 'Write', input: { file_path: 'empty.txt', content: '' } },
          ],
          turn: 1,
          stopReason: 'tool_use',
        },
      });

      await eventStore.append({
        sessionId,
        type: 'tool.call',
        payload: { toolCallId: 'tc_empty', name: 'Write', arguments: { file_path: 'empty.txt', content: '' }, turn: 1 },
      });

      await eventStore.append({
        sessionId,
        type: 'tool.result',
        payload: { toolCallId: 'tc_empty', content: '', isError: false },
      });

      await eventStore.append({
        sessionId,
        type: 'stream.turn_end',
        payload: { turn: 1, tokenUsage: { inputTokens: 100, outputTokens: 50 } },
      });

      const events = await getEventsByTypes(eventStore, sessionId, [
        'message.assistant',
        'tool.call',
        'tool.result',
      ]);

      const result = verifyToolCallOrdering(events);
      expect(result.isValid).toBe(true);

      // Verify empty content is preserved
      const toolResult = events.find(e => e.type === 'tool.result');
      expect((toolResult?.payload as any).content).toBe('');
    });
  });

  describe('Multiple forks from same point', () => {
    it('should maintain correct ordering in each fork', async () => {
      await eventStore.append({
        sessionId,
        type: 'message.user',
        payload: { content: 'Original request' },
      });

      await eventStore.append({
        sessionId,
        type: 'stream.turn_start',
        payload: { turn: 1 },
      });

      await eventStore.append({
        sessionId,
        type: 'message.assistant',
        payload: {
          content: [
            { type: 'tool_use', id: 'tc_multi', name: 'Read', input: { file_path: 'test.ts' } },
          ],
          turn: 1,
          stopReason: 'tool_use',
        },
      });

      await eventStore.append({
        sessionId,
        type: 'tool.call',
        payload: { toolCallId: 'tc_multi', name: 'Read', arguments: { file_path: 'test.ts' }, turn: 1 },
      });

      await eventStore.append({
        sessionId,
        type: 'tool.result',
        payload: { toolCallId: 'tc_multi', content: 'File content', isError: false },
      });

      const forkPoint = await eventStore.append({
        sessionId,
        type: 'stream.turn_end',
        payload: { turn: 1, tokenUsage: { inputTokens: 100, outputTokens: 50 } },
      });

      // Create two forks
      const fork1 = await eventStore.fork(forkPoint.id, { name: 'Fork 1' });
      const fork2 = await eventStore.fork(forkPoint.id, { name: 'Fork 2' });

      // Both forks should have valid message reconstruction
      const messages1 = await eventStore.getMessagesAtHead(fork1.session.id);
      const messages2 = await eventStore.getMessagesAtHead(fork2.session.id);

      // Both should have: user → assistant(tool_use) → user(tool_result)
      expect(messages1.length).toBe(3);
      expect(messages2.length).toBe(3);

      // Verify role alternation in both
      const roles1 = messages1.map(m => m.role);
      const roles2 = messages2.map(m => m.role);

      expect(roles1).toEqual(['user', 'assistant', 'user']);
      expect(roles2).toEqual(['user', 'assistant', 'user']);
    });
  });
});
