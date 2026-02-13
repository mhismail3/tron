/**
 * @fileoverview Tests for event fixtures
 *
 * TDD: Verify that event factory functions produce properly typed objects
 */

import { describe, it, expect } from 'vitest';
import type { SessionEvent, SessionId, WorkspaceId, EventId } from '@infrastructure/events/types.js';
import {
  createSessionStartEvent,
  createSessionForkEvent,
  createUserMessageEvent,
  createAssistantMessageEvent,
  createToolCallEvent,
  createToolResultEvent,
  createConfigModelSwitchEvent,
  createMessageDeletedEvent,
  createCompactBoundaryEvent,
  createStreamTurnStartEvent,
  createStreamTurnEndEvent,
  createGenericEvent,
  createEventChain,
  createBasicConversationChain,
  createToolUseChain,
} from '../index.js';

describe('event fixtures', () => {
  describe('session events', () => {
    describe('createSessionStartEvent', () => {
      it('should create a valid session.start event with defaults', () => {
        const event = createSessionStartEvent();

        expect(event.type).toBe('session.start');
        expect(event.id).toMatch(/^evt_/);
        expect(event.sessionId).toMatch(/^sess_/);
        expect(event.workspaceId).toMatch(/^ws_/);
        expect(event.parentId).toBeNull();
        expect(event.sequence).toBe(0);
        expect(event.payload.workingDirectory).toBeDefined();
        expect(event.payload.model).toBeDefined();
      });

      it('should allow overriding properties', () => {
        const event = createSessionStartEvent({
          workingDirectory: '/custom/path',
          model: 'gpt-4',
          provider: 'openai',
          title: 'Test Session',
        });

        expect(event.payload.workingDirectory).toBe('/custom/path');
        expect(event.payload.model).toBe('gpt-4');
        expect(event.payload.provider).toBe('openai');
        expect(event.payload.title).toBe('Test Session');
      });

      it('should be assignable to SessionEvent type', () => {
        const event: SessionEvent = createSessionStartEvent();
        expect(event.type).toBe('session.start');
      });
    });

    describe('createSessionForkEvent', () => {
      it('should create a valid session.fork event', () => {
        const event = createSessionForkEvent({
          sourceSessionId: 'sess_source' as SessionId,
          sourceEventId: 'evt_source' as EventId,
          name: 'Fork Branch',
        });

        expect(event.type).toBe('session.fork');
        expect(event.payload.sourceSessionId).toBe('sess_source');
        expect(event.payload.sourceEventId).toBe('evt_source');
        expect(event.payload.name).toBe('Fork Branch');
      });
    });
  });

  describe('message events', () => {
    describe('createUserMessageEvent', () => {
      it('should create a valid message.user event with defaults', () => {
        const event = createUserMessageEvent();

        expect(event.type).toBe('message.user');
        expect(event.payload.content).toBeDefined();
        expect(event.payload.turn).toBe(1);
      });

      it('should allow overriding content and turn', () => {
        const event = createUserMessageEvent({
          content: 'Hello world',
          turn: 3,
        });

        expect(event.payload.content).toBe('Hello world');
        expect(event.payload.turn).toBe(3);
      });
    });

    describe('createAssistantMessageEvent', () => {
      it('should create a valid message.assistant event with defaults', () => {
        const event = createAssistantMessageEvent();

        expect(event.type).toBe('message.assistant');
        expect(event.payload.content).toBeInstanceOf(Array);
        expect(event.payload.turn).toBe(1);
      });

      it('should allow custom content blocks', () => {
        const event = createAssistantMessageEvent({
          content: [
            { type: 'text', text: 'First part' },
            { type: 'tool_use', id: 'call_123', name: 'TestTool', input: {} },
          ],
          model: 'claude-3',
          stopReason: 'tool_use',
        });

        expect(event.payload.content).toHaveLength(2);
        expect(event.payload.content[0]!.type).toBe('text');
        expect(event.payload.content[1]!.type).toBe('tool_use');
        expect(event.payload.model).toBe('claude-3');
        expect(event.payload.stopReason).toBe('tool_use');
      });
    });
  });

  describe('tool events', () => {
    describe('createToolCallEvent', () => {
      it('should create a valid tool.call event', () => {
        const event = createToolCallEvent({
          toolCallId: 'call_abc',
          name: 'ReadFile',
          arguments: { path: '/test.txt' },
        });

        expect(event.type).toBe('tool.call');
        expect(event.payload.toolCallId).toBe('call_abc');
        expect(event.payload.name).toBe('ReadFile');
        expect(event.payload.arguments).toEqual({ path: '/test.txt' });
      });
    });

    describe('createToolResultEvent', () => {
      it('should create a valid tool.result event', () => {
        const event = createToolResultEvent({
          toolCallId: 'call_abc',
          content: 'File content here',
          isError: false,
        });

        expect(event.type).toBe('tool.result');
        expect(event.payload.toolCallId).toBe('call_abc');
        expect(event.payload.content).toBe('File content here');
        expect(event.payload.isError).toBe(false);
      });

      it('should handle error results', () => {
        const event = createToolResultEvent({
          toolCallId: 'call_abc',
          content: 'File not found',
          isError: true,
        });

        expect(event.payload.isError).toBe(true);
      });
    });
  });

  describe('config events', () => {
    describe('createConfigModelSwitchEvent', () => {
      it('should create a valid config.model_switch event', () => {
        const event = createConfigModelSwitchEvent({
          previousModel: 'claude-2',
          newModel: 'claude-3',
          reason: 'user_request',
        });

        expect(event.type).toBe('config.model_switch');
        expect(event.payload.previousModel).toBe('claude-2');
        expect(event.payload.newModel).toBe('claude-3');
        expect(event.payload.reason).toBe('user_request');
      });
    });
  });

  describe('message operations events', () => {
    describe('createMessageDeletedEvent', () => {
      it('should create a valid message.deleted event', () => {
        const targetEventId = 'evt_target' as EventId;
        const event = createMessageDeletedEvent({
          targetEventId,
          targetType: 'message.user',
          targetTurn: 2,
          reason: 'user_request',
        });

        expect(event.type).toBe('message.deleted');
        expect(event.payload.targetEventId).toBe(targetEventId);
        expect(event.payload.targetType).toBe('message.user');
        expect(event.payload.targetTurn).toBe(2);
        expect(event.payload.reason).toBe('user_request');
      });
    });
  });

  describe('compaction events', () => {
    describe('createCompactBoundaryEvent', () => {
      it('should create a valid compact.boundary event', () => {
        const event = createCompactBoundaryEvent({
          originalTokens: 50000,
          compactedTokens: 5000,
        });

        expect(event.type).toBe('compact.boundary');
        expect(event.payload.originalTokens).toBe(50000);
        expect(event.payload.compactedTokens).toBe(5000);
      });
    });
  });

  describe('streaming events', () => {
    describe('createStreamTurnStartEvent', () => {
      it('should create a valid stream.turn_start event', () => {
        const event = createStreamTurnStartEvent({
          turn: 5,
        });

        expect(event.type).toBe('stream.turn_start');
        expect(event.payload.turn).toBe(5);
      });
    });

    describe('createStreamTurnEndEvent', () => {
      it('should create a valid stream.turn_end event', () => {
        const event = createStreamTurnEndEvent({
          turn: 5,
          tokenUsage: { inputTokens: 500, outputTokens: 200 },
        });

        expect(event.type).toBe('stream.turn_end');
        expect(event.payload.turn).toBe(5);
        expect(event.payload.tokenUsage).toEqual({ inputTokens: 500, outputTokens: 200 });
      });
    });
  });

  describe('generic event factory', () => {
    describe('createGenericEvent', () => {
      it('should create an event with any type', () => {
        const event = createGenericEvent('message.user', { content: 'test' });

        expect(event.type).toBe('message.user');
        expect(event.payload).toEqual({ content: 'test' });
      });
    });
  });

  describe('event chain builders', () => {
    describe('createEventChain', () => {
      it('should link events with parent references', () => {
        const events = [
          createSessionStartEvent(),
          createUserMessageEvent(),
          createAssistantMessageEvent(),
        ];

        const chain = createEventChain(events);

        expect(chain[0]!.parentId).toBeNull();
        expect(chain[1]!.parentId).toBe(chain[0]!.id);
        expect(chain[2]!.parentId).toBe(chain[1]!.id);
      });

      it('should set consistent session and workspace IDs', () => {
        const sessionId = 'sess_shared' as SessionId;
        const workspaceId = 'ws_shared' as WorkspaceId;

        const events = [
          createSessionStartEvent({ sessionId, workspaceId }),
          createUserMessageEvent({ sessionId: 'sess_other' as SessionId }),
          createAssistantMessageEvent(),
        ];

        const chain = createEventChain(events);

        expect(chain[0]!.sessionId).toBe(sessionId);
        expect(chain[1]!.sessionId).toBe(sessionId);
        expect(chain[2]!.sessionId).toBe(sessionId);
        expect(chain[0]!.workspaceId).toBe(workspaceId);
        expect(chain[1]!.workspaceId).toBe(workspaceId);
        expect(chain[2]!.workspaceId).toBe(workspaceId);
      });

      it('should handle empty array', () => {
        const chain = createEventChain([]);
        expect(chain).toEqual([]);
      });
    });

    describe('createBasicConversationChain', () => {
      it('should create a valid conversation chain', () => {
        const chain = createBasicConversationChain({
          userContent: 'Hello',
          assistantContent: 'Hi there!',
        });

        expect(chain).toHaveLength(3);
        expect(chain[0]!.type).toBe('session.start');
        expect(chain[1]!.type).toBe('message.user');
        expect(chain[2]!.type).toBe('message.assistant');

        // Verify parent links
        expect(chain[0]!.parentId).toBeNull();
        expect(chain[1]!.parentId).toBe(chain[0]!.id);
        expect(chain[2]!.parentId).toBe(chain[1]!.id);

        // Verify content
        expect((chain[1]!.payload as any).content).toBe('Hello');
        expect((chain[2]!.payload as any).content[0].text).toBe('Hi there!');
      });
    });

    describe('createToolUseChain', () => {
      it('should create a valid tool use chain', () => {
        const chain = createToolUseChain({
          userContent: 'Read a file',
          toolName: 'ReadFile',
          toolInput: { path: '/test.txt' },
          toolResult: 'File contents',
          finalAssistantContent: 'Here is the file content',
        });

        expect(chain).toHaveLength(5);
        expect(chain[0]!.type).toBe('session.start');
        expect(chain[1]!.type).toBe('message.user');
        expect(chain[2]!.type).toBe('message.assistant');
        expect(chain[3]!.type).toBe('tool.result');
        expect(chain[4]!.type).toBe('message.assistant');

        // Verify parent links form a chain
        expect(chain[0]!.parentId).toBeNull();
        expect(chain[1]!.parentId).toBe(chain[0]!.id);
        expect(chain[2]!.parentId).toBe(chain[1]!.id);
        expect(chain[3]!.parentId).toBe(chain[2]!.id);
        expect(chain[4]!.parentId).toBe(chain[3]!.id);

        // Verify tool_use block in assistant message
        const assistantContent = (chain[2]!.payload as any).content;
        expect(assistantContent.some((c: any) => c.type === 'tool_use')).toBe(true);

        // Verify tool result matches tool call ID
        const toolUseBlock = assistantContent.find((c: any) => c.type === 'tool_use');
        expect((chain[3]!.payload as any).toolCallId).toBe(toolUseBlock.id);
      });
    });
  });

  describe('type safety', () => {
    it('all event factories should be assignable to SessionEvent', () => {
      const events: SessionEvent[] = [
        createSessionStartEvent(),
        createSessionForkEvent(),
        createUserMessageEvent(),
        createAssistantMessageEvent(),
        createToolCallEvent(),
        createToolResultEvent(),
        createConfigModelSwitchEvent(),
        createMessageDeletedEvent(),
        createCompactBoundaryEvent(),
        createStreamTurnStartEvent(),
        createStreamTurnEndEvent(),
      ];

      expect(events).toHaveLength(11);
      events.forEach(event => {
        expect(event.id).toMatch(/^evt_/);
        expect(event.type).toBeDefined();
      });
    });
  });
});
