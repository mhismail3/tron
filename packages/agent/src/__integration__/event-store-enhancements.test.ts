/**
 * @fileoverview Tests for Event Store Enhancement Plan - Phases 1-4
 *
 * These tests verify the enhanced event storage capabilities:
 * - Phase 1: Enriched message.assistant payload (turn, model, stopReason, latency, hasThinking)
 * - Phase 2: Discrete tool.call and tool.result events
 * - Phase 3: Error events (error.agent, error.provider)
 * - Phase 4: Turn boundary events (stream.turn_start, stream.turn_end)
 */
import { describe, it, expect, beforeEach, afterEach, vi, type Mock } from 'vitest';
import { EventStore, EventId, SessionId, type TronSessionEvent } from '../index.js';
import path from 'path';
import os from 'os';
import fs from 'fs';

describe('Event Store Enhancements', () => {
  let eventStore: EventStore;
  let testDir: string;

  beforeEach(async () => {
    testDir = fs.mkdtempSync(path.join(os.tmpdir(), 'tron-enhancements-test-'));
    const dbPath = path.join(testDir, 'events.db');
    eventStore = new EventStore(dbPath);
    await eventStore.initialize();
  });

  afterEach(async () => {
    await eventStore.close();
    fs.rmSync(testDir, { recursive: true, force: true });
  });

  // ===========================================================================
  // Phase 1: Enriched message.assistant Payload
  // ===========================================================================

  describe('Phase 1: Enriched message.assistant payload', () => {
    let sessionId: SessionId;

    beforeEach(async () => {
      const result = await eventStore.createSession({
        workspacePath: '/test/project',
        workingDirectory: '/test/project',
        model: 'claude-sonnet-4-20250514',
      });
      sessionId = result.session.id;
    });

    it('should store turn number in assistant message', async () => {
      await eventStore.append({
        sessionId,
        type: 'message.user',
        payload: { content: 'Hello' },
      });

      const assistantEvent = await eventStore.append({
        sessionId,
        type: 'message.assistant',
        payload: {
          content: [{ type: 'text', text: 'Hi there!' }],
          tokenUsage: { inputTokens: 100, outputTokens: 50 },
          turn: 1, // NEW field
          model: 'claude-sonnet-4-20250514', // NEW field
          stopReason: 'end_turn', // NEW field
          latency: 1500, // NEW field (ms)
          hasThinking: false, // NEW field
        },
      });

      expect(assistantEvent.payload.turn).toBe(1);
    });

    it('should store model in assistant message', async () => {
      await eventStore.append({
        sessionId,
        type: 'message.user',
        payload: { content: 'Hello' },
      });

      const assistantEvent = await eventStore.append({
        sessionId,
        type: 'message.assistant',
        payload: {
          content: [{ type: 'text', text: 'Response' }],
          tokenUsage: { inputTokens: 100, outputTokens: 50 },
          turn: 1,
          model: 'claude-opus-4-20250514', // Different model
          stopReason: 'end_turn',
        },
      });

      expect(assistantEvent.payload.model).toBe('claude-opus-4-20250514');
    });

    it('should store stopReason in assistant message', async () => {
      await eventStore.append({
        sessionId,
        type: 'message.user',
        payload: { content: 'Read this file' },
      });

      const assistantEvent = await eventStore.append({
        sessionId,
        type: 'message.assistant',
        payload: {
          content: [
            { type: 'text', text: 'I will read the file' },
            { type: 'tool_use', id: 'tc_1', name: 'read', input: { path: 'test.txt' } },
          ],
          tokenUsage: { inputTokens: 150, outputTokens: 75 },
          turn: 1,
          model: 'claude-sonnet-4-20250514',
          stopReason: 'tool_use', // Stopped because of tool use
        },
      });

      expect(assistantEvent.payload.stopReason).toBe('tool_use');
    });

    it('should store latency in assistant message', async () => {
      await eventStore.append({
        sessionId,
        type: 'message.user',
        payload: { content: 'Hello' },
      });

      const assistantEvent = await eventStore.append({
        sessionId,
        type: 'message.assistant',
        payload: {
          content: [{ type: 'text', text: 'Response' }],
          tokenUsage: { inputTokens: 100, outputTokens: 50 },
          turn: 1,
          model: 'claude-sonnet-4-20250514',
          stopReason: 'end_turn',
          latency: 2345, // 2.345 seconds
        },
      });

      expect(assistantEvent.payload.latency).toBe(2345);
    });

    it('should store hasThinking flag when thinking blocks present', async () => {
      await eventStore.append({
        sessionId,
        type: 'message.user',
        payload: { content: 'Complex problem' },
      });

      const assistantEvent = await eventStore.append({
        sessionId,
        type: 'message.assistant',
        payload: {
          content: [
            { type: 'thinking', thinking: 'Let me think about this...' },
            { type: 'text', text: 'Here is my answer' },
          ],
          tokenUsage: { inputTokens: 200, outputTokens: 150 },
          turn: 1,
          model: 'claude-sonnet-4-20250514',
          stopReason: 'end_turn',
          hasThinking: true,
        },
      });

      expect(assistantEvent.payload.hasThinking).toBe(true);
    });

    it('should set hasThinking to false when no thinking blocks', async () => {
      await eventStore.append({
        sessionId,
        type: 'message.user',
        payload: { content: 'Simple question' },
      });

      const assistantEvent = await eventStore.append({
        sessionId,
        type: 'message.assistant',
        payload: {
          content: [{ type: 'text', text: 'Simple answer' }],
          tokenUsage: { inputTokens: 50, outputTokens: 25 },
          turn: 1,
          model: 'claude-sonnet-4-20250514',
          stopReason: 'end_turn',
          hasThinking: false,
        },
      });

      expect(assistantEvent.payload.hasThinking).toBe(false);
    });

    it('should store all enriched fields together', async () => {
      await eventStore.append({
        sessionId,
        type: 'message.user',
        payload: { content: 'Hello' },
      });

      const assistantEvent = await eventStore.append({
        sessionId,
        type: 'message.assistant',
        payload: {
          content: [{ type: 'text', text: 'Response' }],
          tokenUsage: { inputTokens: 100, outputTokens: 50 },
          turn: 3,
          model: 'claude-opus-4-20250514',
          stopReason: 'end_turn',
          latency: 1234,
          hasThinking: false,
        },
      });

      expect(assistantEvent.payload).toMatchObject({
        turn: 3,
        model: 'claude-opus-4-20250514',
        stopReason: 'end_turn',
        latency: 1234,
        hasThinking: false,
      });
    });
  });

  // ===========================================================================
  // Phase 2: Discrete Tool Events
  // ===========================================================================

  describe('Phase 2: Discrete tool events', () => {
    let sessionId: SessionId;

    beforeEach(async () => {
      const result = await eventStore.createSession({
        workspacePath: '/test/project',
        workingDirectory: '/test/project',
        model: 'claude-sonnet-4-20250514',
      });
      sessionId = result.session.id;
    });

    it('should store tool.call event with all required fields', async () => {
      const toolCallEvent = await eventStore.append({
        sessionId,
        type: 'tool.call',
        payload: {
          toolCallId: 'tc_abc123',
          name: 'read',
          arguments: { path: '/test/file.ts', encoding: 'utf-8' },
          turn: 1,
        },
      });

      expect(toolCallEvent.type).toBe('tool.call');
      expect(toolCallEvent.payload.toolCallId).toBe('tc_abc123');
      expect(toolCallEvent.payload.name).toBe('read');
      expect(toolCallEvent.payload.arguments).toEqual({ path: '/test/file.ts', encoding: 'utf-8' });
      expect(toolCallEvent.payload.turn).toBe(1);
    });

    it('should store tool.result event with all required fields', async () => {
      // First create the tool call
      await eventStore.append({
        sessionId,
        type: 'tool.call',
        payload: {
          toolCallId: 'tc_abc123',
          name: 'read',
          arguments: { path: '/test/file.ts' },
          turn: 1,
        },
      });

      // Then store the result
      const toolResultEvent = await eventStore.append({
        sessionId,
        type: 'tool.result',
        payload: {
          toolCallId: 'tc_abc123',
          content: 'File contents here...',
          isError: false,
          duration: 45, // 45ms
        },
      });

      expect(toolResultEvent.type).toBe('tool.result');
      expect(toolResultEvent.payload.toolCallId).toBe('tc_abc123');
      expect(toolResultEvent.payload.content).toBe('File contents here...');
      expect(toolResultEvent.payload.isError).toBe(false);
      expect(toolResultEvent.payload.duration).toBe(45);
    });

    it('should store tool.result with error flag when tool fails', async () => {
      await eventStore.append({
        sessionId,
        type: 'tool.call',
        payload: {
          toolCallId: 'tc_err123',
          name: 'read',
          arguments: { path: '/nonexistent/file.ts' },
          turn: 1,
        },
      });

      const toolResultEvent = await eventStore.append({
        sessionId,
        type: 'tool.result',
        payload: {
          toolCallId: 'tc_err123',
          content: 'Error: File not found',
          isError: true,
          duration: 5,
        },
      });

      expect(toolResultEvent.payload.isError).toBe(true);
      expect(toolResultEvent.payload.content).toContain('Error');
    });

    it('should store tool.result with truncated flag for large results', async () => {
      await eventStore.append({
        sessionId,
        type: 'tool.call',
        payload: {
          toolCallId: 'tc_large',
          name: 'read',
          arguments: { path: '/large/file.ts' },
          turn: 1,
        },
      });

      const toolResultEvent = await eventStore.append({
        sessionId,
        type: 'tool.result',
        payload: {
          toolCallId: 'tc_large',
          content: 'Truncated content...',
          isError: false,
          duration: 100,
          truncated: true,
        },
      });

      expect(toolResultEvent.payload.truncated).toBe(true);
    });

    it('should store tool.result with affectedFiles for write operations', async () => {
      await eventStore.append({
        sessionId,
        type: 'tool.call',
        payload: {
          toolCallId: 'tc_write',
          name: 'write',
          arguments: { path: '/test/output.ts', content: 'new content' },
          turn: 1,
        },
      });

      const toolResultEvent = await eventStore.append({
        sessionId,
        type: 'tool.result',
        payload: {
          toolCallId: 'tc_write',
          content: 'File written successfully',
          isError: false,
          duration: 20,
          affectedFiles: ['/test/output.ts'],
        },
      });

      expect(toolResultEvent.payload.affectedFiles).toEqual(['/test/output.ts']);
    });

    it('should link tool.call and tool.result in query', async () => {
      const toolCall = await eventStore.append({
        sessionId,
        type: 'tool.call',
        payload: {
          toolCallId: 'tc_linked',
          name: 'bash',
          arguments: { command: 'ls -la' },
          turn: 1,
        },
      });

      const toolResult = await eventStore.append({
        sessionId,
        type: 'tool.result',
        payload: {
          toolCallId: 'tc_linked',
          content: 'total 0\ndrwxr-xr-x ...',
          isError: false,
          duration: 150,
        },
      });

      // Get all events for the session
      const events = await eventStore.getEventsBySession(sessionId);
      const toolEvents = events.filter(e => e.type === 'tool.call' || e.type === 'tool.result');

      expect(toolEvents.length).toBe(2);
      expect(toolEvents[0].payload.toolCallId).toBe('tc_linked');
      expect(toolEvents[1].payload.toolCallId).toBe('tc_linked');
    });
  });

  // ===========================================================================
  // Phase 3: Error Events
  // ===========================================================================

  describe('Phase 3: Error events', () => {
    let sessionId: SessionId;

    beforeEach(async () => {
      const result = await eventStore.createSession({
        workspacePath: '/test/project',
        workingDirectory: '/test/project',
        model: 'claude-sonnet-4-20250514',
      });
      sessionId = result.session.id;
    });

    it('should store error.agent event for agent-level errors', async () => {
      const errorEvent = await eventStore.append({
        sessionId,
        type: 'error.agent',
        payload: {
          error: 'Maximum turns exceeded',
          code: 'MAX_TURNS_EXCEEDED',
          recoverable: false,
        },
      });

      expect(errorEvent.type).toBe('error.agent');
      expect(errorEvent.payload.error).toBe('Maximum turns exceeded');
      expect(errorEvent.payload.code).toBe('MAX_TURNS_EXCEEDED');
      expect(errorEvent.payload.recoverable).toBe(false);
    });

    it('should store error.agent event for recoverable errors', async () => {
      const errorEvent = await eventStore.append({
        sessionId,
        type: 'error.agent',
        payload: {
          error: 'Context window approaching limit',
          code: 'CONTEXT_WARNING',
          recoverable: true,
        },
      });

      expect(errorEvent.payload.recoverable).toBe(true);
    });

    it('should store error.provider event for API errors', async () => {
      const errorEvent = await eventStore.append({
        sessionId,
        type: 'error.provider',
        payload: {
          provider: 'anthropic',  // Provider now passed explicitly in event payload
          error: 'Rate limit exceeded',
          code: 'rate_limit_error',
          retryable: true,
          retryAfter: 5000, // 5 seconds
        },
      });

      expect(errorEvent.type).toBe('error.provider');
      expect(errorEvent.payload.provider).toBe('anthropic');
      expect(errorEvent.payload.error).toBe('Rate limit exceeded');
      expect(errorEvent.payload.retryable).toBe(true);
      expect(errorEvent.payload.retryAfter).toBe(5000);
    });

    it('should store error.provider for non-retryable errors', async () => {
      const errorEvent = await eventStore.append({
        sessionId,
        type: 'error.provider',
        payload: {
            error: 'Invalid API key',
          code: 'authentication_error',
          retryable: false,
        },
      });

      expect(errorEvent.payload.retryable).toBe(false);
      expect(errorEvent.payload.retryAfter).toBeUndefined();
    });

    it('should store error.tool event for tool execution errors', async () => {
      const errorEvent = await eventStore.append({
        sessionId,
        type: 'error.tool',
        payload: {
          toolName: 'bash',
          toolCallId: 'tc_failed',
          error: 'Command not found: foobar',
          code: 'COMMAND_NOT_FOUND',
        },
      });

      expect(errorEvent.type).toBe('error.tool');
      expect(errorEvent.payload.toolName).toBe('bash');
      expect(errorEvent.payload.toolCallId).toBe('tc_failed');
      expect(errorEvent.payload.error).toContain('Command not found');
    });

    it('should allow querying error events by type', async () => {
      await eventStore.append({
        sessionId,
        type: 'message.user',
        payload: { content: 'Hello' },
      });

      await eventStore.append({
        sessionId,
        type: 'error.provider',
        payload: {
            error: 'Rate limit',
          code: 'rate_limit',
          retryable: true,
        },
      });

      await eventStore.append({
        sessionId,
        type: 'error.agent',
        payload: {
          error: 'Agent error',
          code: 'AGENT_ERROR',
          recoverable: false,
        },
      });

      const events = await eventStore.getEventsBySession(sessionId);
      const errorEvents = events.filter(e => e.type.startsWith('error.'));

      expect(errorEvents.length).toBe(2);
      expect(errorEvents.map(e => e.type)).toContain('error.provider');
      expect(errorEvents.map(e => e.type)).toContain('error.agent');
    });
  });

  // ===========================================================================
  // Phase 4: Turn Boundary Events
  // ===========================================================================

  describe('Phase 4: Turn boundary events', () => {
    let sessionId: SessionId;

    beforeEach(async () => {
      const result = await eventStore.createSession({
        workspacePath: '/test/project',
        workingDirectory: '/test/project',
        model: 'claude-sonnet-4-20250514',
      });
      sessionId = result.session.id;
    });

    it('should store stream.turn_start event', async () => {
      const turnStartEvent = await eventStore.append({
        sessionId,
        type: 'stream.turn_start',
        payload: {
          turn: 1,
        },
      });

      expect(turnStartEvent.type).toBe('stream.turn_start');
      expect(turnStartEvent.payload.turn).toBe(1);
    });

    it('should store stream.turn_end event with token usage', async () => {
      await eventStore.append({
        sessionId,
        type: 'stream.turn_start',
        payload: { turn: 1 },
      });

      const turnEndEvent = await eventStore.append({
        sessionId,
        type: 'stream.turn_end',
        payload: {
          turn: 1,
          tokenUsage: {
            inputTokens: 500,
            outputTokens: 200,
          },
        },
      });

      expect(turnEndEvent.type).toBe('stream.turn_end');
      expect(turnEndEvent.payload.turn).toBe(1);
      expect(turnEndEvent.payload.tokenUsage).toEqual({
        inputTokens: 500,
        outputTokens: 200,
      });
    });

    it('should store multiple turn boundaries for multi-turn interactions', async () => {
      // Turn 1
      await eventStore.append({
        sessionId,
        type: 'stream.turn_start',
        payload: { turn: 1 },
      });
      await eventStore.append({
        sessionId,
        type: 'stream.turn_end',
        payload: { turn: 1, tokenUsage: { inputTokens: 100, outputTokens: 50 } },
      });

      // Turn 2
      await eventStore.append({
        sessionId,
        type: 'stream.turn_start',
        payload: { turn: 2 },
      });
      await eventStore.append({
        sessionId,
        type: 'stream.turn_end',
        payload: { turn: 2, tokenUsage: { inputTokens: 200, outputTokens: 100 } },
      });

      // Turn 3
      await eventStore.append({
        sessionId,
        type: 'stream.turn_start',
        payload: { turn: 3 },
      });
      await eventStore.append({
        sessionId,
        type: 'stream.turn_end',
        payload: { turn: 3, tokenUsage: { inputTokens: 150, outputTokens: 75 } },
      });

      const events = await eventStore.getEventsBySession(sessionId);
      const turnEvents = events.filter(e =>
        e.type === 'stream.turn_start' || e.type === 'stream.turn_end'
      );

      expect(turnEvents.length).toBe(6); // 3 starts + 3 ends
    });

    it('should allow calculating per-turn token usage from turn events', async () => {
      await eventStore.append({
        sessionId,
        type: 'stream.turn_start',
        payload: { turn: 1 },
      });
      await eventStore.append({
        sessionId,
        type: 'stream.turn_end',
        payload: { turn: 1, tokenUsage: { inputTokens: 100, outputTokens: 50 } },
      });

      await eventStore.append({
        sessionId,
        type: 'stream.turn_start',
        payload: { turn: 2 },
      });
      await eventStore.append({
        sessionId,
        type: 'stream.turn_end',
        payload: { turn: 2, tokenUsage: { inputTokens: 200, outputTokens: 100 } },
      });

      const events = await eventStore.getEventsBySession(sessionId);
      const turnEndEvents = events.filter(e => e.type === 'stream.turn_end');

      const totalInputTokens = turnEndEvents.reduce(
        (sum, e) => sum + (e.payload.tokenUsage?.inputTokens ?? 0),
        0
      );
      const totalOutputTokens = turnEndEvents.reduce(
        (sum, e) => sum + (e.payload.tokenUsage?.outputTokens ?? 0),
        0
      );

      expect(totalInputTokens).toBe(300);
      expect(totalOutputTokens).toBe(150);
    });
  });

  // ===========================================================================
  // Backward Compatibility Tests
  // ===========================================================================

  describe('Backward compatibility', () => {
    let sessionId: SessionId;

    beforeEach(async () => {
      const result = await eventStore.createSession({
        workspacePath: '/test/project',
        workingDirectory: '/test/project',
        model: 'claude-sonnet-4-20250514',
      });
      sessionId = result.session.id;
    });

    it('should still accept assistant messages without new fields (optional fields)', async () => {
      // Old-style assistant message without the new enriched fields
      const assistantEvent = await eventStore.append({
        sessionId,
        type: 'message.assistant',
        payload: {
          content: [{ type: 'text', text: 'Response' }],
          tokenUsage: { inputTokens: 100, outputTokens: 50 },
          // No turn, model, stopReason, latency, hasThinking
        },
      });

      expect(assistantEvent.type).toBe('message.assistant');
      expect(assistantEvent.payload.content).toBeDefined();
      // New fields should be undefined but event should still be valid
      expect(assistantEvent.payload.turn).toBeUndefined();
      expect(assistantEvent.payload.model).toBeUndefined();
    });

    it('should reconstruct messages correctly with new event types present', async () => {
      // User message
      await eventStore.append({
        sessionId,
        type: 'message.user',
        payload: { content: 'Hello' },
      });

      // Turn start (new)
      await eventStore.append({
        sessionId,
        type: 'stream.turn_start',
        payload: { turn: 1 },
      });

      // Tool call (new)
      await eventStore.append({
        sessionId,
        type: 'tool.call',
        payload: {
          toolCallId: 'tc_1',
          name: 'read',
          arguments: { path: 'test.txt' },
          turn: 1,
        },
      });

      // Tool result (new)
      await eventStore.append({
        sessionId,
        type: 'tool.result',
        payload: {
          toolCallId: 'tc_1',
          content: 'file contents',
          isError: false,
          duration: 50,
        },
      });

      // Assistant message (with enriched fields)
      await eventStore.append({
        sessionId,
        type: 'message.assistant',
        payload: {
          content: [{ type: 'text', text: 'I read the file' }],
          tokenUsage: { inputTokens: 100, outputTokens: 50 },
          turn: 1,
          model: 'claude-sonnet-4-20250514',
          stopReason: 'end_turn',
        },
      });

      // Turn end (new)
      await eventStore.append({
        sessionId,
        type: 'stream.turn_end',
        payload: { turn: 1, tokenUsage: { inputTokens: 100, outputTokens: 50 } },
      });

      // Reconstruct messages - tool.result events are NOT reconstructed as separate messages
      // Tool results are stored in message.user events (at turn end) for proper sequencing
      // This test only has tool.result events without corresponding message.user events,
      // so we expect just user + assistant messages
      const messages = await eventStore.getMessagesAtHead(sessionId);
      expect(messages.length).toBe(2);
      expect(messages[0].role).toBe('user');
      expect(messages[1].role).toBe('assistant');
    });

    it('should not affect existing session queries with new event types', async () => {
      // Mix of old and new event types
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
      await eventStore.append({
        sessionId,
        type: 'message.assistant',
        payload: { content: 'Hi!' },
      });
      await eventStore.append({
        sessionId,
        type: 'stream.turn_end',
        payload: { turn: 1, tokenUsage: { inputTokens: 50, outputTokens: 25 } },
      });

      // Session should still report correct counts
      const session = await eventStore.getSession(sessionId);
      expect(session).not.toBeNull();
      expect(session!.eventCount).toBe(5); // root + 4 appended
      expect(session!.messageCount).toBe(2); // Only user + assistant
    });
  });

  // ===========================================================================
  // Integration: Full Agent Turn Simulation
  // ===========================================================================

  describe('Integration: Full agent turn with all new events', () => {
    let sessionId: SessionId;

    beforeEach(async () => {
      const result = await eventStore.createSession({
        workspacePath: '/test/project',
        workingDirectory: '/test/project',
        model: 'claude-sonnet-4-20250514',
      });
      sessionId = result.session.id;
    });

    it('should store complete agent interaction with all event types', async () => {
      // Simulate a complete agent interaction

      // 1. User prompt
      await eventStore.append({
        sessionId,
        type: 'message.user',
        payload: { content: 'Read README.md and summarize it' },
      });

      // 2. Turn 1 starts
      await eventStore.append({
        sessionId,
        type: 'stream.turn_start',
        payload: { turn: 1 },
      });

      // 3. Tool call
      await eventStore.append({
        sessionId,
        type: 'tool.call',
        payload: {
          toolCallId: 'tc_read_1',
          name: 'read',
          arguments: { path: 'README.md' },
          turn: 1,
        },
      });

      // 4. Tool result
      await eventStore.append({
        sessionId,
        type: 'tool.result',
        payload: {
          toolCallId: 'tc_read_1',
          content: '# Project\n\nThis is a test project.',
          isError: false,
          duration: 25,
        },
      });

      // 5. First assistant message (with tool_use, stopped for tool)
      await eventStore.append({
        sessionId,
        type: 'message.assistant',
        payload: {
          content: [
            { type: 'text', text: 'Let me read that file.' },
            { type: 'tool_use', id: 'tc_read_1', name: 'read', input: { path: 'README.md' } },
          ],
          tokenUsage: { inputTokens: 100, outputTokens: 60 },
          turn: 1,
          model: 'claude-sonnet-4-20250514',
          stopReason: 'tool_use',
          latency: 1200,
          hasThinking: false,
        },
      });

      // 6. Turn 1 ends
      await eventStore.append({
        sessionId,
        type: 'stream.turn_end',
        payload: { turn: 1, tokenUsage: { inputTokens: 100, outputTokens: 60 } },
      });

      // 6b. Tool result as user message (for proper API sequencing)
      await eventStore.append({
        sessionId,
        type: 'message.user',
        payload: {
          content: [
            {
              type: 'tool_result',
              tool_use_id: 'tc_read_1',
              content: '# Project\n\nThis is a test project.',
            },
          ],
        },
      });

      // 7. Turn 2 starts (after tool execution)
      await eventStore.append({
        sessionId,
        type: 'stream.turn_start',
        payload: { turn: 2 },
      });

      // 8. Final assistant message (summary)
      await eventStore.append({
        sessionId,
        type: 'message.assistant',
        payload: {
          content: [
            { type: 'thinking', thinking: 'The README shows this is a test project...' },
            { type: 'text', text: 'The README describes a test project.' },
          ],
          tokenUsage: { inputTokens: 200, outputTokens: 80 },
          turn: 2,
          model: 'claude-sonnet-4-20250514',
          stopReason: 'end_turn',
          latency: 2500,
          hasThinking: true,
        },
      });

      // 9. Turn 2 ends
      await eventStore.append({
        sessionId,
        type: 'stream.turn_end',
        payload: { turn: 2, tokenUsage: { inputTokens: 200, outputTokens: 80 } },
      });

      // Verify all events are stored
      const events = await eventStore.getEventsBySession(sessionId);

      // Count by type
      const eventCounts = events.reduce((acc, e) => {
        acc[e.type] = (acc[e.type] || 0) + 1;
        return acc;
      }, {} as Record<string, number>);

      expect(eventCounts['session.start']).toBe(1);
      expect(eventCounts['message.user']).toBe(2); // Original + tool result
      expect(eventCounts['message.assistant']).toBe(2);
      expect(eventCounts['stream.turn_start']).toBe(2);
      expect(eventCounts['stream.turn_end']).toBe(2);
      expect(eventCounts['tool.call']).toBe(1);
      expect(eventCounts['tool.result']).toBe(1);

      // Verify messages reconstruction
      // Tool results are stored in message.user events for proper API sequencing
      const messages = await eventStore.getMessagesAtHead(sessionId);
      expect(messages.length).toBe(4); // 1 user + 1 assistant + 1 user (tool_result) + 1 assistant

      // Verify state includes correct token totals
      const state = await eventStore.getStateAtHead(sessionId);
      expect(state.tokenUsage.inputTokens).toBe(300); // 100 + 200
      expect(state.tokenUsage.outputTokens).toBe(140); // 60 + 80
    });

    it('should store error events in failure scenario', async () => {
      await eventStore.append({
        sessionId,
        type: 'message.user',
        payload: { content: 'Do something' },
      });

      await eventStore.append({
        sessionId,
        type: 'stream.turn_start',
        payload: { turn: 1 },
      });

      // Provider error with retry
      await eventStore.append({
        sessionId,
        type: 'error.provider',
        payload: {
            error: 'Rate limit exceeded',
          code: 'rate_limit',
          retryable: true,
          retryAfter: 1000,
        },
      });

      // Retry succeeds, continue
      await eventStore.append({
        sessionId,
        type: 'message.assistant',
        payload: {
          content: [{ type: 'text', text: 'Done!' }],
          tokenUsage: { inputTokens: 50, outputTokens: 10 },
          turn: 1,
          model: 'claude-sonnet-4-20250514',
          stopReason: 'end_turn',
        },
      });

      await eventStore.append({
        sessionId,
        type: 'stream.turn_end',
        payload: { turn: 1, tokenUsage: { inputTokens: 50, outputTokens: 10 } },
      });

      const events = await eventStore.getEventsBySession(sessionId);
      const errorEvents = events.filter(e => e.type === 'error.provider');

      expect(errorEvents.length).toBe(1);
      expect(errorEvents[0].payload.retryable).toBe(true);
    });
  });
});
