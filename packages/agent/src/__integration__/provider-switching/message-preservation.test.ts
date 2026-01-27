/**
 * @fileoverview Provider Switching - Message Preservation Tests
 *
 * Tests that conversation history is correctly preserved when switching
 * between providers (Anthropic, OpenAI, Google).
 *
 * Critical scenarios:
 * - User/assistant message roundtrip preservation
 * - Tool call/result pairing across switches
 * - Image content preservation
 * - System prompts handled correctly
 */
import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import { EventStore, SessionId, type Message } from '../../index.js';
import path from 'path';
import os from 'os';
import fs from 'fs';

describe('Provider Switching - Message Preservation', () => {
  let eventStore: EventStore;
  let testDir: string;

  beforeEach(async () => {
    testDir = fs.mkdtempSync(path.join(os.tmpdir(), 'tron-provider-switch-test-'));
    const dbPath = path.join(testDir, 'events.db');
    eventStore = new EventStore(dbPath);
    await eventStore.initialize();
  });

  afterEach(async () => {
    await eventStore.close();
    fs.rmSync(testDir, { recursive: true, force: true });
  });

  describe('conversation history preservation', () => {
    it('should preserve user messages across model switch', async () => {
      const { session, rootEvent } = await eventStore.createSession({
        workspacePath: '/test/project',
        workingDirectory: '/test/project',
        model: 'claude-sonnet-4-5-20250929',
      });

      // Add user message
      const userMsg = await eventStore.append({
        sessionId: session.id,
        type: 'message.user',
        payload: { content: 'Hello from user' },
        parentId: rootEvent.id,
      });

      // Add assistant response
      const assistantMsg = await eventStore.append({
        sessionId: session.id,
        type: 'message.assistant',
        payload: {
          content: [{ type: 'text', text: 'Hello! How can I help?' }],
          usage: { inputTokens: 10, outputTokens: 5 },
        },
        parentId: userMsg.id,
      });

      // Switch model (Anthropic → OpenAI)
      const switchEvent = await eventStore.append({
        sessionId: session.id,
        type: 'config.model_switch',
        payload: {
          previousModel: 'claude-sonnet-4-5-20250929',
          newModel: 'gpt-5.2-codex',
        },
        parentId: assistantMsg.id,
      });

      // Add another user message after switch
      const userMsg2 = await eventStore.append({
        sessionId: session.id,
        type: 'message.user',
        payload: { content: 'Now using a different model' },
        parentId: switchEvent.id,
      });

      // Verify all events are in the correct chain
      const ancestors = await eventStore.getAncestors(userMsg2.id);
      const userMsgs = ancestors.filter(e => e.type === 'message.user');

      expect(userMsgs.length).toBe(2);
      expect(userMsgs.find(m => m.payload.content === 'Hello from user')).toBeDefined();
      expect(userMsgs.find(m => m.payload.content === 'Now using a different model')).toBeDefined();
    });

    it('should preserve assistant responses with tool calls across switch', async () => {
      const { session, rootEvent } = await eventStore.createSession({
        workspacePath: '/test/project',
        workingDirectory: '/test/project',
        model: 'claude-sonnet-4-5-20250929',
      });

      // User asks for file read
      const userMsg = await eventStore.append({
        sessionId: session.id,
        type: 'message.user',
        payload: { content: 'Read the config file' },
        parentId: rootEvent.id,
      });

      // Assistant responds with tool call (Anthropic format ID)
      const toolCallId = 'toolu_01ABC123XYZ';
      const assistantMsg = await eventStore.append({
        sessionId: session.id,
        type: 'message.assistant',
        payload: {
          content: [
            { type: 'text', text: 'I will read the file.' },
            {
              type: 'tool_use',
              id: toolCallId,
              name: 'Read',
              arguments: { file_path: '/config.json' },
            },
          ],
          usage: { inputTokens: 15, outputTokens: 20 },
        },
        parentId: userMsg.id,
      });

      // Tool result
      const toolResult = await eventStore.append({
        sessionId: session.id,
        type: 'tool.result',
        payload: {
          toolCallId,
          content: '{"key": "value"}',
          isError: false,
        },
        parentId: assistantMsg.id,
      });

      // Switch to Google
      const switchEvent = await eventStore.append({
        sessionId: session.id,
        type: 'config.model_switch',
        payload: {
          previousModel: 'claude-sonnet-4-5-20250929',
          newModel: 'gemini-2.5-pro',
        },
        parentId: toolResult.id,
      });

      // Verify tool call chain is intact
      const ancestors = await eventStore.getAncestors(switchEvent.id);

      const toolCalls = ancestors.filter(e => e.type === 'message.assistant');
      expect(toolCalls.length).toBe(1);

      const toolResults = ancestors.filter(e => e.type === 'tool.result');
      expect(toolResults.length).toBe(1);
      expect(toolResults[0].payload.toolCallId).toBe(toolCallId);
    });

    it('should handle multiple model switches in sequence', async () => {
      const { session, rootEvent } = await eventStore.createSession({
        workspacePath: '/test/project',
        workingDirectory: '/test/project',
        model: 'claude-sonnet-4-5-20250929',
      });

      let lastEventId = rootEvent.id;
      const models = [
        'claude-sonnet-4-5-20250929',
        'gpt-5.2-codex',
        'gemini-2.5-pro',
        'claude-opus-4-5-20251101',
      ];

      // Add messages and switch models
      for (let i = 1; i < models.length; i++) {
        // User message
        const userMsg = await eventStore.append({
          sessionId: session.id,
          type: 'message.user',
          payload: { content: `Message ${i} on ${models[i - 1]}` },
          parentId: lastEventId,
        });

        // Assistant response
        const assistantMsg = await eventStore.append({
          sessionId: session.id,
          type: 'message.assistant',
          payload: {
            content: [{ type: 'text', text: `Response ${i}` }],
            usage: { inputTokens: 10 + i, outputTokens: 5 + i },
          },
          parentId: userMsg.id,
        });

        // Model switch
        const switchEvent = await eventStore.append({
          sessionId: session.id,
          type: 'config.model_switch',
          payload: {
            previousModel: models[i - 1],
            newModel: models[i],
          },
          parentId: assistantMsg.id,
        });

        lastEventId = switchEvent.id;
      }

      // Verify all switches are recorded
      const events = await eventStore.getEventsBySession(session.id);
      const switches = events.filter(e => e.type === 'config.model_switch');
      expect(switches.length).toBe(3);

      // Verify model progression
      expect(switches[0].payload.previousModel).toBe('claude-sonnet-4-5-20250929');
      expect(switches[0].payload.newModel).toBe('gpt-5.2-codex');
      expect(switches[1].payload.newModel).toBe('gemini-2.5-pro');
      expect(switches[2].payload.newModel).toBe('claude-opus-4-5-20251101');
    });
  });

  describe('message format normalization', () => {
    it('should preserve complex content arrays', async () => {
      const { session, rootEvent } = await eventStore.createSession({
        workspacePath: '/test/project',
        workingDirectory: '/test/project',
        model: 'claude-sonnet-4-5-20250929',
      });

      // User message with image
      const userMsg = await eventStore.append({
        sessionId: session.id,
        type: 'message.user',
        payload: {
          content: [
            { type: 'text', text: 'What is in this image?' },
            {
              type: 'image',
              source: { type: 'base64', media_type: 'image/png', data: 'abc123...' },
            },
          ],
        },
        parentId: rootEvent.id,
      });

      // Switch and verify content is preserved
      const switchEvent = await eventStore.append({
        sessionId: session.id,
        type: 'config.model_switch',
        payload: {
          previousModel: 'claude-sonnet-4-5-20250929',
          newModel: 'gemini-2.5-pro',
        },
        parentId: userMsg.id,
      });

      const ancestors = await eventStore.getAncestors(switchEvent.id);
      const userMsgEvent = ancestors.find(e => e.type === 'message.user');

      expect(userMsgEvent).toBeDefined();
      expect(Array.isArray(userMsgEvent!.payload.content)).toBe(true);
      expect(userMsgEvent!.payload.content.length).toBe(2);
      expect(userMsgEvent!.payload.content[1].type).toBe('image');
    });

    it('should preserve thinking blocks from Claude', async () => {
      const { session, rootEvent } = await eventStore.createSession({
        workspacePath: '/test/project',
        workingDirectory: '/test/project',
        model: 'claude-opus-4-5-20251101',
      });

      const userMsg = await eventStore.append({
        sessionId: session.id,
        type: 'message.user',
        payload: { content: 'Complex reasoning task' },
        parentId: rootEvent.id,
      });

      // Assistant response with thinking
      const assistantMsg = await eventStore.append({
        sessionId: session.id,
        type: 'message.assistant',
        payload: {
          content: [
            { type: 'thinking', thinking: 'Let me think step by step...' },
            { type: 'text', text: 'The answer is 42.' },
          ],
          usage: { inputTokens: 50, outputTokens: 100 },
        },
        parentId: userMsg.id,
      });

      // Switch to non-thinking model
      const switchEvent = await eventStore.append({
        sessionId: session.id,
        type: 'config.model_switch',
        payload: {
          previousModel: 'claude-opus-4-5-20251101',
          newModel: 'gpt-5.2-codex',
        },
        parentId: assistantMsg.id,
      });

      // Verify thinking is preserved in event history
      const ancestors = await eventStore.getAncestors(switchEvent.id);
      const assistantEvents = ancestors.filter(e => e.type === 'message.assistant');

      expect(assistantEvents.length).toBe(1);
      const thinkingBlock = assistantEvents[0].payload.content.find(
        (c: { type: string }) => c.type === 'thinking'
      );
      expect(thinkingBlock).toBeDefined();
      expect(thinkingBlock.thinking).toBe('Let me think step by step...');
    });
  });

  describe('model reconstruction from events', () => {
    it('should determine current model from event chain', async () => {
      const { session, rootEvent } = await eventStore.createSession({
        workspacePath: '/test/project',
        workingDirectory: '/test/project',
        model: 'claude-haiku-4-5-20251001',
      });

      // Switch models multiple times
      const switch1 = await eventStore.append({
        sessionId: session.id,
        type: 'config.model_switch',
        payload: { previousModel: 'claude-haiku-4-5-20251001', newModel: 'gpt-5.2-codex' },
        parentId: rootEvent.id,
      });

      const switch2 = await eventStore.append({
        sessionId: session.id,
        type: 'config.model_switch',
        payload: { previousModel: 'gpt-5.2-codex', newModel: 'gemini-2.5-pro' },
        parentId: switch1.id,
      });

      const switch3 = await eventStore.append({
        sessionId: session.id,
        type: 'config.model_switch',
        payload: { previousModel: 'gemini-2.5-pro', newModel: 'claude-opus-4-5-20251101' },
        parentId: switch2.id,
      });

      // Reconstruct current model from ancestors
      const ancestors = await eventStore.getAncestors(switch3.id);

      let currentModel = 'claude-haiku-4-5-20251001'; // Default from session.start
      for (const event of ancestors) {
        if (event.type === 'session.start') {
          currentModel = event.payload.model as string;
        } else if (event.type === 'config.model_switch') {
          currentModel = event.payload.newModel as string;
        }
      }

      expect(currentModel).toBe('claude-opus-4-5-20251101');
    });
  });
});
