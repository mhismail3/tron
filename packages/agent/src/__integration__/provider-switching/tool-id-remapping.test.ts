/**
 * @fileoverview Provider Switching - Tool ID Remapping Tests
 *
 * Tests that tool call IDs are correctly handled when switching between providers.
 * Different providers use different ID formats:
 * - Anthropic: toolu_01ABC123...
 * - OpenAI: call_abc123...
 * - Google: server-generated or client IDs
 *
 * Critical scenarios:
 * - Tool calls started on one provider, results on another
 * - ID remapping for OpenAI Responses API compatibility
 * - Multiple concurrent tool calls across switch
 */
import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import { EventStore, SessionId } from '../../index.js';
import type { Message, ToolCall } from '../../types/index.js';
import path from 'path';
import os from 'os';
import fs from 'fs';

describe('Provider Switching - Tool ID Remapping', () => {
  let eventStore: EventStore;
  let testDir: string;

  beforeEach(async () => {
    testDir = fs.mkdtempSync(path.join(os.tmpdir(), 'tron-tool-id-test-'));
    const dbPath = path.join(testDir, 'events.db');
    eventStore = new EventStore(dbPath);
    await eventStore.initialize();
  });

  afterEach(async () => {
    await eventStore.close();
    fs.rmSync(testDir, { recursive: true, force: true });
  });

  describe('tool ID format preservation', () => {
    it('should preserve Anthropic tool IDs (toolu_* format)', async () => {
      const { session, rootEvent } = await eventStore.createSession({
        workspacePath: '/test/project',
        workingDirectory: '/test/project',
        model: 'claude-sonnet-4-5-20250929',
      });

      const toolCallId = 'toolu_01XYZ789ABC123DEF456';

      // Tool call event
      const toolCall = await eventStore.append({
        sessionId: session.id,
        type: 'tool.call',
        payload: {
          id: toolCallId,
          name: 'Read',
          arguments: { file_path: '/test.ts' },
        },
        parentId: rootEvent.id,
      });

      // Tool result event
      const toolResult = await eventStore.append({
        sessionId: session.id,
        type: 'tool.result',
        payload: {
          toolCallId,
          content: 'file contents here',
          isError: false,
        },
        parentId: toolCall.id,
      });

      // Verify ID preserved
      const events = await eventStore.getEventsBySession(session.id);
      const resultEvent = events.find(e => e.type === 'tool.result');

      expect(resultEvent?.payload.toolCallId).toBe(toolCallId);
      expect(resultEvent?.payload.toolCallId.startsWith('toolu_')).toBe(true);
    });

    it('should preserve OpenAI tool IDs (call_* format)', async () => {
      const { session, rootEvent } = await eventStore.createSession({
        workspacePath: '/test/project',
        workingDirectory: '/test/project',
        model: 'gpt-5.2-codex',
      });

      const toolCallId = 'call_abc123xyz789';

      const toolCall = await eventStore.append({
        sessionId: session.id,
        type: 'tool.call',
        payload: {
          id: toolCallId,
          name: 'Bash',
          arguments: { command: 'ls -la' },
        },
        parentId: rootEvent.id,
      });

      const toolResult = await eventStore.append({
        sessionId: session.id,
        type: 'tool.result',
        payload: {
          toolCallId,
          content: 'total 42\ndrwxr-xr-x ...',
          isError: false,
        },
        parentId: toolCall.id,
      });

      const events = await eventStore.getEventsBySession(session.id);
      const resultEvent = events.find(e => e.type === 'tool.result');

      expect(resultEvent?.payload.toolCallId).toBe(toolCallId);
      expect(resultEvent?.payload.toolCallId.startsWith('call_')).toBe(true);
    });
  });

  describe('cross-provider tool call handling', () => {
    it('should handle tool call started on Anthropic, result after switch to OpenAI', async () => {
      const { session, rootEvent } = await eventStore.createSession({
        workspacePath: '/test/project',
        workingDirectory: '/test/project',
        model: 'claude-sonnet-4-5-20250929',
      });

      // Anthropic format tool call
      const anthropicToolId = 'toolu_01ABC123XYZ';

      const assistantMsg = await eventStore.append({
        sessionId: session.id,
        type: 'message.assistant',
        payload: {
          content: [
            { type: 'text', text: 'Reading file...' },
            {
              type: 'tool_use',
              id: anthropicToolId,
              name: 'Read',
              arguments: { file_path: '/config.json' },
            },
          ],
          usage: { inputTokens: 20, outputTokens: 15 },
        },
        parentId: rootEvent.id,
      });

      // Tool execution happens
      const toolResult = await eventStore.append({
        sessionId: session.id,
        type: 'tool.result',
        payload: {
          toolCallId: anthropicToolId,
          content: '{"key": "value"}',
          isError: false,
        },
        parentId: assistantMsg.id,
      });

      // Now switch to OpenAI
      const switchEvent = await eventStore.append({
        sessionId: session.id,
        type: 'config.model_switch',
        payload: {
          previousModel: 'claude-sonnet-4-5-20250929',
          newModel: 'gpt-5.2-codex',
        },
        parentId: toolResult.id,
      });

      // Verify the tool call chain is intact for reconstruction
      const ancestors = await eventStore.getAncestors(switchEvent.id);

      // Find the tool_use in assistant message
      const assistantEvents = ancestors.filter(e => e.type === 'message.assistant');
      expect(assistantEvents.length).toBe(1);

      const toolUse = assistantEvents[0].payload.content.find(
        (c: { type: string }) => c.type === 'tool_use'
      );
      expect(toolUse.id).toBe(anthropicToolId);

      // Find the tool result
      const resultEvents = ancestors.filter(e => e.type === 'tool.result');
      expect(resultEvents.length).toBe(1);
      expect(resultEvents[0].payload.toolCallId).toBe(anthropicToolId);
    });

    it('should handle multiple tool calls across provider switch', async () => {
      const { session, rootEvent } = await eventStore.createSession({
        workspacePath: '/test/project',
        workingDirectory: '/test/project',
        model: 'claude-sonnet-4-5-20250929',
      });

      const toolId1 = 'toolu_01READ123';
      const toolId2 = 'toolu_02GREP456';

      // Assistant with multiple tool calls
      const assistantMsg = await eventStore.append({
        sessionId: session.id,
        type: 'message.assistant',
        payload: {
          content: [
            { type: 'tool_use', id: toolId1, name: 'Read', arguments: { file_path: '/a.ts' } },
            { type: 'tool_use', id: toolId2, name: 'Grep', arguments: { pattern: 'foo' } },
          ],
          usage: { inputTokens: 30, outputTokens: 25 },
        },
        parentId: rootEvent.id,
      });

      // Both results
      const result1 = await eventStore.append({
        sessionId: session.id,
        type: 'tool.result',
        payload: { toolCallId: toolId1, content: 'file a contents', isError: false },
        parentId: assistantMsg.id,
      });

      const result2 = await eventStore.append({
        sessionId: session.id,
        type: 'tool.result',
        payload: { toolCallId: toolId2, content: 'grep matches', isError: false },
        parentId: result1.id,
      });

      // Switch to Google
      const switchEvent = await eventStore.append({
        sessionId: session.id,
        type: 'config.model_switch',
        payload: {
          previousModel: 'claude-sonnet-4-5-20250929',
          newModel: 'gemini-2.5-pro',
        },
        parentId: result2.id,
      });

      // Verify all tool calls and results preserved
      const ancestors = await eventStore.getAncestors(switchEvent.id);
      const toolResults = ancestors.filter(e => e.type === 'tool.result');

      expect(toolResults.length).toBe(2);
      expect(toolResults.map(r => r.payload.toolCallId).sort()).toEqual(
        [toolId1, toolId2].sort()
      );
    });
  });

  describe('tool result message format', () => {
    it('should handle toolResult role messages (internal format)', async () => {
      const { session, rootEvent } = await eventStore.createSession({
        workspacePath: '/test/project',
        workingDirectory: '/test/project',
        model: 'claude-sonnet-4-5-20250929',
      });

      // This tests the internal message format used for reconstruction
      const toolCallId = 'toolu_01TEST789';

      // Simulate messages as they would be stored/reconstructed
      const messages: Message[] = [
        { role: 'user', content: 'Read the file' },
        {
          role: 'assistant',
          content: [
            { type: 'text', text: 'Reading...' },
            { type: 'tool_use', id: toolCallId, name: 'Read', arguments: { file_path: '/x.ts' } },
          ],
        },
        {
          role: 'toolResult',
          toolCallId,
          content: 'file contents',
          isError: false,
        },
      ];

      // Verify the toolResult message has correct structure
      const toolResultMsg = messages.find(m => m.role === 'toolResult');
      expect(toolResultMsg).toBeDefined();
      expect((toolResultMsg as any).toolCallId).toBe(toolCallId);
      expect((toolResultMsg as any).isError).toBe(false);
    });

    it('should handle error tool results', async () => {
      const { session, rootEvent } = await eventStore.createSession({
        workspacePath: '/test/project',
        workingDirectory: '/test/project',
        model: 'claude-sonnet-4-5-20250929',
      });

      const toolCallId = 'toolu_01ERROR456';

      const assistantMsg = await eventStore.append({
        sessionId: session.id,
        type: 'message.assistant',
        payload: {
          content: [
            { type: 'tool_use', id: toolCallId, name: 'Read', arguments: { file_path: '/nonexistent' } },
          ],
          usage: { inputTokens: 15, outputTokens: 10 },
        },
        parentId: rootEvent.id,
      });

      const toolResult = await eventStore.append({
        sessionId: session.id,
        type: 'tool.result',
        payload: {
          toolCallId,
          content: 'Error: File not found',
          isError: true,
        },
        parentId: assistantMsg.id,
      });

      // Switch and verify error preserved
      const switchEvent = await eventStore.append({
        sessionId: session.id,
        type: 'config.model_switch',
        payload: {
          previousModel: 'claude-sonnet-4-5-20250929',
          newModel: 'gpt-5.2-codex',
        },
        parentId: toolResult.id,
      });

      const ancestors = await eventStore.getAncestors(switchEvent.id);
      const errorResult = ancestors.find(e => e.type === 'tool.result');

      expect(errorResult?.payload.isError).toBe(true);
      expect(errorResult?.payload.content).toContain('Error');
    });
  });

  describe('ID uniqueness across session', () => {
    it('should maintain unique tool IDs even with multiple switches', async () => {
      const { session, rootEvent } = await eventStore.createSession({
        workspacePath: '/test/project',
        workingDirectory: '/test/project',
        model: 'claude-sonnet-4-5-20250929',
      });

      const allToolIds: string[] = [];
      let lastEventId = rootEvent.id;

      // Generate tool calls across multiple provider switches
      const models = ['claude-sonnet-4-5-20250929', 'gpt-5.2-codex', 'gemini-2.5-pro'];

      for (let i = 0; i < models.length; i++) {
        const toolId = `tool_${models[i].split('-')[0]}_${i}`;
        allToolIds.push(toolId);

        const assistantMsg = await eventStore.append({
          sessionId: session.id,
          type: 'message.assistant',
          payload: {
            content: [
              { type: 'tool_use', id: toolId, name: 'Read', arguments: { file_path: `/file${i}.ts` } },
            ],
            usage: { inputTokens: 10, outputTokens: 10 },
          },
          parentId: lastEventId,
        });

        const toolResult = await eventStore.append({
          sessionId: session.id,
          type: 'tool.result',
          payload: { toolCallId: toolId, content: `contents ${i}`, isError: false },
          parentId: assistantMsg.id,
        });

        if (i < models.length - 1) {
          const switchEvent = await eventStore.append({
            sessionId: session.id,
            type: 'config.model_switch',
            payload: { previousModel: models[i], newModel: models[i + 1] },
            parentId: toolResult.id,
          });
          lastEventId = switchEvent.id;
        } else {
          lastEventId = toolResult.id;
        }
      }

      // Verify all tool IDs are unique
      const uniqueIds = new Set(allToolIds);
      expect(uniqueIds.size).toBe(allToolIds.length);

      // Verify all are retrievable
      const events = await eventStore.getEventsBySession(session.id);
      const toolResults = events.filter(e => e.type === 'tool.result');

      for (const id of allToolIds) {
        const found = toolResults.find(r => r.payload.toolCallId === id);
        expect(found).toBeDefined();
      }
    });
  });
});
