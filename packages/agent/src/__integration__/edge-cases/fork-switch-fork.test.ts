/**
 * @fileoverview Combined Edge Cases - Fork + Switch + Fork
 *
 * Tests for complex combined operations:
 * - Fork → provider switch → fork again
 * - Concurrent forks with different providers
 * - Tool calls spanning fork + switch combinations
 * - Context preservation through combined operations
 */
import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import { EventStore, SessionId, EventId } from '../../index.js';
import path from 'path';
import os from 'os';
import fs from 'fs';

describe('Combined Edge Cases - Fork + Switch + Fork', () => {
  let eventStore: EventStore;
  let testDir: string;

  beforeEach(async () => {
    testDir = fs.mkdtempSync(path.join(os.tmpdir(), 'tron-edge-case-test-'));
    const dbPath = path.join(testDir, 'events.db');
    eventStore = new EventStore(dbPath);
    await eventStore.initialize();
  });

  afterEach(async () => {
    await eventStore.close();
    fs.rmSync(testDir, { recursive: true, force: true });
  });

  describe('fork → switch → fork chain', () => {
    it('should handle fork → switch provider → fork again', async () => {
      // Session A on Anthropic
      const { session: sessionA, rootEvent: rootA } = await eventStore.createSession({
        workspacePath: '/test/project',
        workingDirectory: '/test/project',
        model: 'claude-sonnet-4-5-20250929',
      });

      const msgA = await eventStore.append({
        sessionId: sessionA.id,
        type: 'message.user',
        payload: { content: 'Started on Claude' },
        parentId: rootA.id,
      });

      // Fork to Session B
      const forkB = await eventStore.fork(msgA.id, { name: 'Fork B' });

      // Switch B to OpenAI
      const switchB = await eventStore.append({
        sessionId: forkB.session.id,
        type: 'config.model_switch',
        payload: {
          previousModel: 'claude-sonnet-4-5-20250929',
          newModel: 'gpt-5.2-codex',
        },
        parentId: forkB.rootEvent.id,
      });

      const msgB = await eventStore.append({
        sessionId: forkB.session.id,
        type: 'message.user',
        payload: { content: 'Now on GPT in B' },
        parentId: switchB.id,
      });

      // Fork B to Session C (on OpenAI)
      const forkC = await eventStore.fork(msgB.id, { name: 'Fork C from B' });

      // Add message to C
      const msgC = await eventStore.append({
        sessionId: forkC.session.id,
        type: 'message.user',
        payload: { content: 'In C, still on GPT' },
        parentId: forkC.rootEvent.id,
      });

      // Verify C has full history
      const ancestorsC = await eventStore.getAncestors(msgC.id);

      // Should have all messages
      const userMsgs = ancestorsC.filter(e => e.type === 'message.user');
      expect(userMsgs.length).toBe(3);

      // Should have the model switch
      const switches = ancestorsC.filter(e => e.type === 'config.model_switch');
      expect(switches.length).toBe(1);
      expect(switches[0].payload.newModel).toBe('gpt-5.2-codex');

      // Reconstruct current model in C
      let currentModel = 'claude-sonnet-4-5-20250929';
      for (const event of ancestorsC) {
        if (event.type === 'config.model_switch') {
          currentModel = event.payload.newModel as string;
        }
      }
      expect(currentModel).toBe('gpt-5.2-codex');
    });

    it('should handle switch → fork → switch → fork', async () => {
      const { session, rootEvent } = await eventStore.createSession({
        workspacePath: '/test/project',
        workingDirectory: '/test/project',
        model: 'claude-haiku-4-5-20251001',
      });

      // First switch
      const switch1 = await eventStore.append({
        sessionId: session.id,
        type: 'config.model_switch',
        payload: { previousModel: 'claude-haiku-4-5-20251001', newModel: 'gpt-5.2-codex' },
        parentId: rootEvent.id,
      });

      // Fork after first switch
      const fork1 = await eventStore.fork(switch1.id, { name: 'Fork 1' });

      // Switch in fork
      const switch2 = await eventStore.append({
        sessionId: fork1.session.id,
        type: 'config.model_switch',
        payload: { previousModel: 'gpt-5.2-codex', newModel: 'gemini-2.5-pro' },
        parentId: fork1.rootEvent.id,
      });

      // Fork again
      const fork2 = await eventStore.fork(switch2.id, { name: 'Fork 2' });

      // Verify model history in fork2
      const ancestors = await eventStore.getAncestors(fork2.rootEvent.id);
      const switches = ancestors.filter(e => e.type === 'config.model_switch');

      expect(switches.length).toBe(2);

      // Reconstruct model
      let model = 'claude-haiku-4-5-20251001';
      for (const event of ancestors) {
        if (event.type === 'config.model_switch') {
          model = event.payload.newModel as string;
        }
      }
      expect(model).toBe('gemini-2.5-pro');
    });
  });

  describe('concurrent forks with different providers', () => {
    it('should handle parallel forks switched to different providers', async () => {
      const { session, rootEvent } = await eventStore.createSession({
        workspacePath: '/test/project',
        workingDirectory: '/test/project',
        model: 'claude-sonnet-4-5-20250929',
      });

      const baseMsg = await eventStore.append({
        sessionId: session.id,
        type: 'message.user',
        payload: { content: 'Common starting point' },
        parentId: rootEvent.id,
      });

      // Fork to A
      const forkA = await eventStore.fork(baseMsg.id, { name: 'Fork A' });

      // Fork to B (from same point)
      const forkB = await eventStore.fork(baseMsg.id, { name: 'Fork B' });

      // Switch A to OpenAI
      const switchA = await eventStore.append({
        sessionId: forkA.session.id,
        type: 'config.model_switch',
        payload: { previousModel: 'claude-sonnet-4-5-20250929', newModel: 'gpt-5.2-codex' },
        parentId: forkA.rootEvent.id,
      });

      // Switch B to Google
      const switchB = await eventStore.append({
        sessionId: forkB.session.id,
        type: 'config.model_switch',
        payload: { previousModel: 'claude-sonnet-4-5-20250929', newModel: 'gemini-2.5-pro' },
        parentId: forkB.rootEvent.id,
      });

      // Add unique messages
      const msgA = await eventStore.append({
        sessionId: forkA.session.id,
        type: 'message.user',
        payload: { content: 'Running on OpenAI' },
        parentId: switchA.id,
      });

      const msgB = await eventStore.append({
        sessionId: forkB.session.id,
        type: 'message.user',
        payload: { content: 'Running on Google' },
        parentId: switchB.id,
      });

      // Verify A's model
      const ancestorsA = await eventStore.getAncestors(msgA.id);
      let modelA = 'claude-sonnet-4-5-20250929';
      for (const e of ancestorsA) {
        if (e.type === 'config.model_switch') modelA = e.payload.newModel as string;
      }
      expect(modelA).toBe('gpt-5.2-codex');

      // Verify B's model
      const ancestorsB = await eventStore.getAncestors(msgB.id);
      let modelB = 'claude-sonnet-4-5-20250929';
      for (const e of ancestorsB) {
        if (e.type === 'config.model_switch') modelB = e.payload.newModel as string;
      }
      expect(modelB).toBe('gemini-2.5-pro');

      // Verify isolation
      expect(ancestorsA.find(e => e.payload?.content === 'Running on Google')).toBeUndefined();
      expect(ancestorsB.find(e => e.payload?.content === 'Running on OpenAI')).toBeUndefined();
    });
  });

  describe('tool calls spanning fork + switch', () => {
    it('should handle tool call before fork, switch in fork, then more tools', async () => {
      const { session, rootEvent } = await eventStore.createSession({
        workspacePath: '/test/project',
        workingDirectory: '/test/project',
        model: 'claude-sonnet-4-5-20250929',
      });

      const toolId1 = 'toolu_01ANTHROPIC';

      // Tool call on Anthropic
      const assistant1 = await eventStore.append({
        sessionId: session.id,
        type: 'message.assistant',
        payload: {
          content: [
            { type: 'tool_use', id: toolId1, name: 'Read', arguments: { file_path: '/a.ts' } },
          ],
          usage: { inputTokens: 15, outputTokens: 12 },
        },
        parentId: rootEvent.id,
      });

      const result1 = await eventStore.append({
        sessionId: session.id,
        type: 'tool.result',
        payload: { toolCallId: toolId1, content: 'a content', isError: false },
        parentId: assistant1.id,
      });

      // Fork
      const fork = await eventStore.fork(result1.id, { name: 'Tool Fork' });

      // Switch to OpenAI in fork
      const switchEvt = await eventStore.append({
        sessionId: fork.session.id,
        type: 'config.model_switch',
        payload: { previousModel: 'claude-sonnet-4-5-20250929', newModel: 'gpt-5.2-codex' },
        parentId: fork.rootEvent.id,
      });

      // Another tool call (OpenAI format ID)
      const toolId2 = 'call_openai_xyz123';

      const assistant2 = await eventStore.append({
        sessionId: fork.session.id,
        type: 'message.assistant',
        payload: {
          content: [
            { type: 'tool_use', id: toolId2, name: 'Write', arguments: { file_path: '/b.ts' } },
          ],
          usage: { inputTokens: 20, outputTokens: 15 },
        },
        parentId: switchEvt.id,
      });

      const result2 = await eventStore.append({
        sessionId: fork.session.id,
        type: 'tool.result',
        payload: { toolCallId: toolId2, content: 'written', isError: false },
        parentId: assistant2.id,
      });

      // Verify full history
      const ancestors = await eventStore.getAncestors(result2.id);

      // Both tool IDs present
      const toolResults = ancestors.filter(e => e.type === 'tool.result');
      expect(toolResults.length).toBe(2);

      const ids = toolResults.map(r => r.payload.toolCallId);
      expect(ids).toContain(toolId1);
      expect(ids).toContain(toolId2);

      // Model switch present
      const switches = ancestors.filter(e => e.type === 'config.model_switch');
      expect(switches.length).toBe(1);
    });
  });

  describe('context preservation through operations', () => {
    it('should preserve thinking blocks through fork + switch', async () => {
      const { session, rootEvent } = await eventStore.createSession({
        workspacePath: '/test/project',
        workingDirectory: '/test/project',
        model: 'claude-opus-4-5-20251101',
      });

      // Assistant with thinking
      const assistant = await eventStore.append({
        sessionId: session.id,
        type: 'message.assistant',
        payload: {
          content: [
            { type: 'thinking', thinking: 'Deep analysis of the problem...' },
            { type: 'text', text: 'Here is my conclusion.' },
          ],
          usage: { inputTokens: 50, outputTokens: 100 },
        },
        parentId: rootEvent.id,
      });

      // Fork
      const fork = await eventStore.fork(assistant.id, { name: 'Thinking Fork' });

      // Switch to non-thinking model
      const switchEvt = await eventStore.append({
        sessionId: fork.session.id,
        type: 'config.model_switch',
        payload: { previousModel: 'claude-opus-4-5-20251101', newModel: 'gpt-5.2-codex' },
        parentId: fork.rootEvent.id,
      });

      // Verify thinking is preserved in history
      const ancestors = await eventStore.getAncestors(switchEvt.id);
      const assistantMsgs = ancestors.filter(e => e.type === 'message.assistant');

      expect(assistantMsgs.length).toBe(1);
      const content = assistantMsgs[0].payload.content;
      const thinking = content.find((c: any) => c.type === 'thinking');
      expect(thinking).toBeDefined();
      expect(thinking.thinking).toBe('Deep analysis of the problem...');
    });

    it('should preserve image content through fork + switch', async () => {
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
            { type: 'text', text: 'Describe this:' },
            { type: 'image', source: { type: 'base64', media_type: 'image/png', data: 'abc...' } },
          ],
        },
        parentId: rootEvent.id,
      });

      // Fork
      const fork = await eventStore.fork(userMsg.id, { name: 'Image Fork' });

      // Switch
      const switchEvt = await eventStore.append({
        sessionId: fork.session.id,
        type: 'config.model_switch',
        payload: { previousModel: 'claude-sonnet-4-5-20250929', newModel: 'gemini-2.5-pro' },
        parentId: fork.rootEvent.id,
      });

      // Verify image preserved
      const ancestors = await eventStore.getAncestors(switchEvt.id);
      const userMsgs = ancestors.filter(e => e.type === 'message.user');

      expect(userMsgs.length).toBe(1);
      const content = userMsgs[0].payload.content;
      const image = content.find((c: any) => c.type === 'image');
      expect(image).toBeDefined();
      expect(image.source.type).toBe('base64');
    });
  });

  describe('session state consistency', () => {
    it('should maintain consistent head after fork + switch', async () => {
      const { session, rootEvent } = await eventStore.createSession({
        workspacePath: '/test/project',
        workingDirectory: '/test/project',
        model: 'claude-sonnet-4-5-20250929',
      });

      const msg = await eventStore.append({
        sessionId: session.id,
        type: 'message.user',
        payload: { content: 'test' },
        parentId: rootEvent.id,
      });

      const fork = await eventStore.fork(msg.id, { name: 'Head Test Fork' });

      const switchEvt = await eventStore.append({
        sessionId: fork.session.id,
        type: 'config.model_switch',
        payload: { previousModel: 'claude-sonnet-4-5-20250929', newModel: 'gpt-5.2-codex' },
        parentId: fork.rootEvent.id,
      });

      const finalMsg = await eventStore.append({
        sessionId: fork.session.id,
        type: 'message.user',
        payload: { content: 'final' },
        parentId: switchEvt.id,
      });

      // Verify session head is updated
      const forkedSession = await eventStore.getSession(fork.session.id);
      expect(forkedSession?.headEventId).toBe(finalMsg.id);
    });
  });
});
