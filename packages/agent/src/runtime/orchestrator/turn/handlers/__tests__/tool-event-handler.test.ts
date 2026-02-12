/**
 * @fileoverview Tests for ToolEventHandler
 *
 * ToolEventHandler uses EventContext for automatic metadata injection.
 * It handles tool execution events: tool_use_batch, tool_execution_start, tool_execution_end.
 */

import { describe, it, expect, vi, beforeEach } from 'vitest';
import { ToolEventHandler, createToolEventHandler, type ToolEventHandlerDeps } from '../tool-event-handler.js';
import { createTestEventContext, type TestEventContext } from '../../event-context.js';
import type { SessionId } from '../../../../events/types.js';
import type { TronEvent } from '../../../../types/events.js';
import type { ActiveSession } from '../../../types.js';

// =============================================================================
// Test Helpers
// =============================================================================

function createMockUIRenderHandler() {
  return {
    handleToolStart: vi.fn(),
    handleToolEnd: vi.fn(),
    handleToolCallDelta: vi.fn(),
    cleanup: vi.fn(),
  };
}

function createMockDeps(): ToolEventHandlerDeps {
  return {
    uiRenderHandler: createMockUIRenderHandler() as unknown as ToolEventHandlerDeps['uiRenderHandler'],
  };
}

function createMockActiveSession(overrides: Partial<ActiveSession> = {}): ActiveSession {
  return {
    sessionId: 'test-session' as SessionId,
    model: 'claude-sonnet-4-20250514',
    agent: {} as ActiveSession['agent'],
    sessionContext: {
      registerToolIntents: vi.fn(),
      startToolCall: vi.fn(),
      endToolCall: vi.fn(),
      flushPreToolContent: vi.fn().mockReturnValue(null),
      getCurrentTurn: vi.fn().mockReturnValue(1),
      getTurnStartTime: vi.fn().mockReturnValue(Date.now() - 1000),
      getLastTurnTokenUsage: vi.fn().mockReturnValue({ inputTokens: 100, outputTokens: 50 }),
      getLastTokenRecord: vi.fn().mockReturnValue({
        source: {
          provider: 'anthropic',
          timestamp: new Date().toISOString(),
          rawInputTokens: 100,
          rawOutputTokens: 50,
          rawCacheReadTokens: 0,
          rawCacheCreationTokens: 0,
        },
        computed: {
          contextWindowTokens: 1000,
          newInputTokens: 100,
          previousContextBaseline: 0,
          calculationMethod: 'anthropic_cache_aware',
        },
        meta: {
          turn: 1,
          sessionId: 'test-session',
          extractedAt: new Date().toISOString(),
          normalizedAt: new Date().toISOString(),
        },
      }),
      addMessageEventId: vi.fn(),
    } as unknown as ActiveSession['sessionContext'],
    ...overrides,
  } as ActiveSession;
}

function createTestContext(options: {
  sessionId?: SessionId;
  runId?: string;
  active?: ActiveSession;
} = {}): TestEventContext {
  return createTestEventContext({
    sessionId: options.sessionId ?? ('test-session' as SessionId),
    runId: options.runId,
    active: options.active,
  });
}

// =============================================================================
// Tests
// =============================================================================

describe('ToolEventHandler', () => {
  let deps: ToolEventHandlerDeps;
  let handler: ToolEventHandler;

  beforeEach(() => {
    deps = createMockDeps();
    handler = createToolEventHandler(deps);
  });

  describe('handleToolUseBatch', () => {
    it('should register tool intents when active session exists', () => {
      const mockActive = createMockActiveSession({ currentRunId: 'run-123' });
      const ctx = createTestContext({ active: mockActive });
      const event = {
        type: 'tool_use_batch',
        toolCalls: [
          { id: 'call-1', name: 'Read', arguments: { file_path: '/test.txt' } },
          { id: 'call-2', name: 'Write', arguments: { file_path: '/out.txt', content: 'hello' } },
        ],
      } as unknown as TronEvent;

      handler.handleToolUseBatch(ctx, event);

      expect(mockActive.sessionContext!.registerToolIntents).toHaveBeenCalledWith([
        { id: 'call-1', name: 'Read', arguments: { file_path: '/test.txt' } },
        { id: 'call-2', name: 'Write', arguments: { file_path: '/out.txt', content: 'hello' } },
      ]);
    });

    it('should handle input field as arguments', () => {
      const mockActive = createMockActiveSession({ currentRunId: 'run-456' });
      const ctx = createTestContext({ active: mockActive });
      const event = {
        type: 'tool_use_batch',
        toolCalls: [
          { id: 'call-1', name: 'Read', input: { file_path: '/test.txt' } },
        ],
      } as unknown as TronEvent;

      handler.handleToolUseBatch(ctx, event);

      expect(mockActive.sessionContext!.registerToolIntents).toHaveBeenCalledWith([
        { id: 'call-1', name: 'Read', arguments: { file_path: '/test.txt' } },
      ]);
    });

    it('should do nothing when no active session', () => {
      const ctx = createTestContext(); // No active session
      const event = {
        type: 'tool_use_batch',
        toolCalls: [{ id: 'call-1', name: 'Read', arguments: {} }],
      } as unknown as TronEvent;

      handler.handleToolUseBatch(ctx, event);

      // Should not throw, no emits
      expect(ctx.emitCalls).toHaveLength(0);
    });
  });

  describe('handleToolExecutionStart', () => {
    it('should emit agent.tool_start event via context', () => {
      const mockActive = createMockActiveSession({ currentRunId: 'run-123' });
      const ctx = createTestContext({ active: mockActive });
      const event = {
        type: 'tool_execution_start',
        toolCallId: 'call-1',
        toolName: 'Read',
        arguments: { file_path: '/test.txt' },
      } as unknown as TronEvent;

      handler.handleToolExecutionStart(ctx, event);

      expect(ctx.emitCalls).toHaveLength(1);
      expect(ctx.emitCalls[0]).toEqual({
        type: 'agent.tool_start',
        data: {
          toolCallId: 'call-1',
          toolName: 'Read',
          arguments: { file_path: '/test.txt' },
        },
      });
    });

    it('should persist tool.call event via context', () => {
      const mockActive = createMockActiveSession({ currentRunId: 'run-456' });
      const ctx = createTestContext({ active: mockActive });
      const event = {
        type: 'tool_execution_start',
        toolCallId: 'call-1',
        toolName: 'Read',
        arguments: { file_path: '/test.txt' },
      } as unknown as TronEvent;

      handler.handleToolExecutionStart(ctx, event);

      // Find the tool.call persist call
      const toolCallPersist = ctx.persistCalls.find(c => c.type === 'tool.call');
      expect(toolCallPersist).toBeDefined();
      expect(toolCallPersist!.payload).toMatchObject({
        toolCallId: 'call-1',
        name: 'Read',
        arguments: { file_path: '/test.txt' },
        runId: 'run-456',
      });
    });

    it('should track tool call on session context', () => {
      const mockActive = createMockActiveSession({ currentRunId: 'run-789' });
      const ctx = createTestContext({ active: mockActive });
      const event = {
        type: 'tool_execution_start',
        toolCallId: 'call-1',
        toolName: 'Read',
        arguments: { file_path: '/test.txt' },
      } as unknown as TronEvent;

      handler.handleToolExecutionStart(ctx, event);

      expect(mockActive.sessionContext!.startToolCall).toHaveBeenCalledWith(
        'call-1',
        'Read',
        { file_path: '/test.txt' }
      );
    });

    it('should flush pre-tool content when it exists', () => {
      const mockActive = createMockActiveSession({ currentRunId: 'run-000' });
      // Return content to flush
      (mockActive.sessionContext!.flushPreToolContent as ReturnType<typeof vi.fn>).mockReturnValue([
        { type: 'text', text: 'Analyzing the file...' },
      ]);

      const ctx = createTestContext({ active: mockActive });
      const event = {
        type: 'tool_execution_start',
        toolCallId: 'call-1',
        toolName: 'Read',
        arguments: {},
      } as unknown as TronEvent;

      handler.handleToolExecutionStart(ctx, event);

      // Should create message.assistant before tool.call
      expect(ctx.persistCalls).toHaveLength(2);
      expect(ctx.persistCalls[0].type).toBe('message.assistant');
      expect(ctx.persistCalls[1].type).toBe('tool.call');
    });

    it('should delegate RenderAppUI to UIRenderHandler', () => {
      const mockActive = createMockActiveSession({ currentRunId: 'run-111' });
      const ctx = createTestContext({ active: mockActive });
      const event = {
        type: 'tool_execution_start',
        toolCallId: 'call-1',
        toolName: 'RenderAppUI',
        arguments: { component: 'test' },
      } as unknown as TronEvent;

      handler.handleToolExecutionStart(ctx, event);

      expect(deps.uiRenderHandler.handleToolStart).toHaveBeenCalledWith(
        ctx.sessionId,
        'call-1',
        { component: 'test' },
        ctx.timestamp,
        'run-111'
      );
    });

    it('should handle undefined active session', () => {
      const ctx = createTestContext(); // No active session
      const event = {
        type: 'tool_execution_start',
        toolCallId: 'call-1',
        toolName: 'Read',
        arguments: {},
      } as unknown as TronEvent;

      handler.handleToolExecutionStart(ctx, event);

      // Should still emit and persist
      expect(ctx.emitCalls).toHaveLength(1);
      expect(ctx.persistCalls).toHaveLength(1);
    });
  });

  describe('handleToolExecutionUpdate', () => {
    it('should emit agent.tool_output with toolCallId and output', () => {
      const ctx = createTestContext();
      const event = {
        type: 'tool_execution_update',
        toolCallId: 'call-1',
        update: 'partial output chunk',
      } as unknown as TronEvent;

      handler.handleToolExecutionUpdate(ctx, event);

      expect(ctx.emitCalls).toHaveLength(1);
      expect(ctx.emitCalls[0]).toEqual({
        type: 'agent.tool_output',
        data: {
          toolCallId: 'call-1',
          output: 'partial output chunk',
        },
      });
    });

    it('should not persist anything', () => {
      const ctx = createTestContext();
      const event = {
        type: 'tool_execution_update',
        toolCallId: 'call-1',
        update: 'chunk',
      } as unknown as TronEvent;

      handler.handleToolExecutionUpdate(ctx, event);

      expect(ctx.persistCalls).toHaveLength(0);
    });
  });

  describe('handleToolExecutionEnd', () => {
    it('should emit agent.tool_end event on success via context', () => {
      const mockActive = createMockActiveSession({ currentRunId: 'run-123' });
      const ctx = createTestContext({ active: mockActive });
      const event = {
        type: 'tool_execution_end',
        toolCallId: 'call-1',
        toolName: 'Read',
        result: { content: 'file contents here' },
        isError: false,
        duration: 150,
      } as unknown as TronEvent;

      handler.handleToolExecutionEnd(ctx, event);

      expect(ctx.emitCalls).toHaveLength(1);
      expect(ctx.emitCalls[0]).toEqual({
        type: 'agent.tool_end',
        data: expect.objectContaining({
          toolCallId: 'call-1',
          toolName: 'Read',
          success: true,
          output: 'file contents here',
          duration: 150,
        }),
      });
    });

    it('should emit agent.tool_end event on error via context', () => {
      const mockActive = createMockActiveSession({ currentRunId: 'run-456' });
      const ctx = createTestContext({ active: mockActive });
      const event = {
        type: 'tool_execution_end',
        toolCallId: 'call-1',
        toolName: 'Read',
        result: { content: 'File not found' },
        isError: true,
        duration: 50,
      } as unknown as TronEvent;

      handler.handleToolExecutionEnd(ctx, event);

      expect(ctx.emitCalls).toHaveLength(1);
      expect(ctx.emitCalls[0]).toEqual({
        type: 'agent.tool_end',
        data: expect.objectContaining({
          toolCallId: 'call-1',
          toolName: 'Read',
          success: false,
          error: 'File not found',
          duration: 50,
        }),
      });
    });

    it('should persist tool.result event via context', () => {
      const mockActive = createMockActiveSession({ currentRunId: 'run-789' });
      const ctx = createTestContext({ active: mockActive });
      const event = {
        type: 'tool_execution_end',
        toolCallId: 'call-1',
        toolName: 'Read',
        result: { content: 'file contents' },
        isError: false,
        duration: 100,
      } as unknown as TronEvent;

      handler.handleToolExecutionEnd(ctx, event);

      // Find the tool.result persist call
      const toolResultPersist = ctx.persistCalls.find(c => c.type === 'tool.result');
      expect(toolResultPersist).toBeDefined();
      expect(toolResultPersist!.payload).toMatchObject({
        toolCallId: 'call-1',
        content: 'file contents',
        isError: false,
        runId: 'run-789',
      });
      // Should have callback for event ID tracking
      expect(toolResultPersist!.onCreated).toBeDefined();
    });

    it('should track tool result on session context', () => {
      const mockActive = createMockActiveSession({ currentRunId: 'run-000' });
      const ctx = createTestContext({ active: mockActive });
      const event = {
        type: 'tool_execution_end',
        toolCallId: 'call-1',
        toolName: 'Read',
        result: { content: 'file contents' },
        isError: false,
        duration: 100,
      } as unknown as TronEvent;

      handler.handleToolExecutionEnd(ctx, event);

      expect(mockActive.sessionContext!.endToolCall).toHaveBeenCalledWith(
        'call-1',
        'file contents',
        false
      );
    });

    it('should extract content from array blocks', () => {
      const mockActive = createMockActiveSession({ currentRunId: 'run-111' });
      const ctx = createTestContext({ active: mockActive });
      const event = {
        type: 'tool_execution_end',
        toolCallId: 'call-1',
        toolName: 'Read',
        result: {
          content: [
            { type: 'text', text: 'Line 1' },
            { type: 'text', text: 'Line 2' },
            { type: 'image', data: 'base64...' },
          ],
        },
        isError: false,
        duration: 100,
      } as unknown as TronEvent;

      handler.handleToolExecutionEnd(ctx, event);

      expect(mockActive.sessionContext!.endToolCall).toHaveBeenCalledWith(
        'call-1',
        'Line 1\nLine 2',
        false
      );
    });

    it('should delegate RenderAppUI to UIRenderHandler', () => {
      const mockActive = createMockActiveSession({ currentRunId: 'run-222' });
      const ctx = createTestContext({ active: mockActive });
      const event = {
        type: 'tool_execution_end',
        toolCallId: 'call-1',
        toolName: 'RenderAppUI',
        result: { content: 'success', details: { html: '<div/>' } },
        isError: false,
        duration: 100,
      } as unknown as TronEvent;

      handler.handleToolExecutionEnd(ctx, event);

      expect(deps.uiRenderHandler.handleToolEnd).toHaveBeenCalledWith(
        ctx.sessionId,
        'call-1',
        'success',
        false,
        { html: '<div/>' },
        ctx.timestamp,
        'run-222'
      );
    });

    it('should handle undefined active session', () => {
      const ctx = createTestContext(); // No active session
      const event = {
        type: 'tool_execution_end',
        toolCallId: 'call-1',
        toolName: 'Read',
        result: { content: 'file contents' },
        isError: false,
        duration: 100,
      } as unknown as TronEvent;

      handler.handleToolExecutionEnd(ctx, event);

      // Should still emit and persist
      expect(ctx.emitCalls).toHaveLength(1);
      expect(ctx.persistCalls).toHaveLength(1);
    });
  });

  describe('factory function', () => {
    it('should create ToolEventHandler instance', () => {
      const handler = createToolEventHandler(deps);
      expect(handler).toBeInstanceOf(ToolEventHandler);
    });
  });

  describe('blob storage', () => {
    function createMockBlobStore() {
      const storage = new Map<string, string>();
      let counter = 0;
      return {
        store: vi.fn((content: string) => {
          const blobId = `blob_${++counter}`;
          storage.set(blobId, content);
          return blobId;
        }),
        getContent: vi.fn((blobId: string) => storage.get(blobId) ?? null),
        _storage: storage,
      };
    }

    it('should store large results (> 2KB) to blob', () => {
      const mockActive = createMockActiveSession({ currentRunId: 'run-blob-1' });
      const ctx = createTestContext({ active: mockActive });
      const blobStore = createMockBlobStore();
      handler.setBlobStore(blobStore);

      // Create content > 2KB but < 10KB (shouldn't truncate)
      const largeContent = 'x'.repeat(3000);
      const event = {
        type: 'tool_execution_end',
        toolCallId: 'call-1',
        toolName: 'Read',
        result: { content: largeContent },
        isError: false,
        duration: 100,
      } as unknown as TronEvent;

      handler.handleToolExecutionEnd(ctx, event);

      // Blob should be stored
      expect(blobStore.store).toHaveBeenCalledWith(largeContent, 'text/plain');

      // Content should NOT be truncated (under 10KB threshold)
      const toolResultPersist = ctx.persistCalls.find(c => c.type === 'tool.result');
      expect(toolResultPersist!.payload.content).toBe(largeContent);
      expect(toolResultPersist!.payload.blobId).toBe('blob_1');
      expect(toolResultPersist!.payload.truncated).toBe(false);
    });

    it('should truncate and add blob reference for very large results (> 10KB)', () => {
      const mockActive = createMockActiveSession({ currentRunId: 'run-blob-2' });
      const ctx = createTestContext({ active: mockActive });
      const blobStore = createMockBlobStore();
      handler.setBlobStore(blobStore);

      // Create content > 10KB
      const veryLargeContent = 'y'.repeat(15000);
      const event = {
        type: 'tool_execution_end',
        toolCallId: 'call-2',
        toolName: 'Read',
        result: { content: veryLargeContent },
        isError: false,
        duration: 100,
      } as unknown as TronEvent;

      handler.handleToolExecutionEnd(ctx, event);

      // Blob should be stored
      expect(blobStore.store).toHaveBeenCalledWith(veryLargeContent, 'text/plain');

      // Content should be truncated with blob reference
      const toolResultPersist = ctx.persistCalls.find(c => c.type === 'tool.result');
      expect(toolResultPersist!.payload.content.length).toBeLessThan(veryLargeContent.length);
      expect(toolResultPersist!.payload.content).toContain('blob_1');
      expect(toolResultPersist!.payload.content).toContain('truncated');
      expect(toolResultPersist!.payload.content).toContain('Remember');
      expect(toolResultPersist!.payload.blobId).toBe('blob_1');
      expect(toolResultPersist!.payload.truncated).toBe(true);
    });

    it('should truncate without blob reference when no blob store', () => {
      const mockActive = createMockActiveSession({ currentRunId: 'run-blob-3' });
      const ctx = createTestContext({ active: mockActive });
      // No blob store set

      // Create content > 10KB
      const veryLargeContent = 'z'.repeat(15000);
      const event = {
        type: 'tool_execution_end',
        toolCallId: 'call-3',
        toolName: 'Read',
        result: { content: veryLargeContent },
        isError: false,
        duration: 100,
      } as unknown as TronEvent;

      handler.handleToolExecutionEnd(ctx, event);

      // Content should be truncated without blob reference
      const toolResultPersist = ctx.persistCalls.find(c => c.type === 'tool.result');
      expect(toolResultPersist!.payload.content.length).toBeLessThan(veryLargeContent.length);
      expect(toolResultPersist!.payload.content).toContain('truncated');
      expect(toolResultPersist!.payload.content).not.toContain('blob_');
      expect(toolResultPersist!.payload.blobId).toBeUndefined();
      expect(toolResultPersist!.payload.truncated).toBe(true);
    });

    it('should not store small results (< 2KB) to blob', () => {
      const mockActive = createMockActiveSession({ currentRunId: 'run-blob-4' });
      const ctx = createTestContext({ active: mockActive });
      const blobStore = createMockBlobStore();
      handler.setBlobStore(blobStore);

      // Create small content (< 2KB)
      const smallContent = 'small file contents';
      const event = {
        type: 'tool_execution_end',
        toolCallId: 'call-4',
        toolName: 'Read',
        result: { content: smallContent },
        isError: false,
        duration: 100,
      } as unknown as TronEvent;

      handler.handleToolExecutionEnd(ctx, event);

      // Blob should NOT be stored
      expect(blobStore.store).not.toHaveBeenCalled();

      // Content should be stored as-is
      const toolResultPersist = ctx.persistCalls.find(c => c.type === 'tool.result');
      expect(toolResultPersist!.payload.content).toBe(smallContent);
      expect(toolResultPersist!.payload.blobId).toBeUndefined();
      expect(toolResultPersist!.payload.truncated).toBe(false);
    });
  });
});
