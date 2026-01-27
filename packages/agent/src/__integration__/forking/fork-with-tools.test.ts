/**
 * @fileoverview Fork with Tools Tests
 *
 * Tests forking scenarios involving tool calls:
 * - Fork with active/pending tool calls
 * - Tool result after fork
 * - Multiple tool calls spanning fork point
 * - Error tool results in forked sessions
 */
import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import { EventStore, SessionId, EventId } from '../../index.js';
import path from 'path';
import os from 'os';
import fs from 'fs';

describe('Fork Integration - Fork with Tools', () => {
  let eventStore: EventStore;
  let testDir: string;

  beforeEach(async () => {
    testDir = fs.mkdtempSync(path.join(os.tmpdir(), 'tron-fork-tools-test-'));
    const dbPath = path.join(testDir, 'events.db');
    eventStore = new EventStore(dbPath);
    await eventStore.initialize();
  });

  afterEach(async () => {
    await eventStore.close();
    fs.rmSync(testDir, { recursive: true, force: true });
  });

  describe('fork with completed tool calls', () => {
    it('should preserve completed tool call/result pairs in fork', async () => {
      const { session, rootEvent } = await eventStore.createSession({
        workspacePath: '/test/project',
        workingDirectory: '/test/project',
        model: 'claude-sonnet-4-5-20250929',
      });

      const toolCallId = 'toolu_01COMPLETED';

      const userMsg = await eventStore.append({
        sessionId: session.id,
        type: 'message.user',
        payload: { content: 'Read file' },
        parentId: rootEvent.id,
      });

      const assistantMsg = await eventStore.append({
        sessionId: session.id,
        type: 'message.assistant',
        payload: {
          content: [
            { type: 'text', text: 'Reading...' },
            { type: 'tool_use', id: toolCallId, name: 'Read', arguments: { file_path: '/x.ts' } },
          ],
          usage: { inputTokens: 15, outputTokens: 12 },
        },
        parentId: userMsg.id,
      });

      const toolResult = await eventStore.append({
        sessionId: session.id,
        type: 'tool.result',
        payload: { toolCallId, content: 'export const x = 1;', isError: false },
        parentId: assistantMsg.id,
      });

      // Fork after tool is complete
      const fork = await eventStore.fork(toolResult.id, { name: 'After Tool Fork' });

      // Verify fork has access to the tool call/result
      const ancestors = await eventStore.getAncestors(fork.rootEvent.id);

      const toolCalls = ancestors.filter(e => e.type === 'message.assistant');
      const toolResults = ancestors.filter(e => e.type === 'tool.result');

      expect(toolCalls.length).toBe(1);
      expect(toolResults.length).toBe(1);
      expect(toolResults[0].payload.toolCallId).toBe(toolCallId);
    });

    it('should handle fork after multiple tool calls', async () => {
      const { session, rootEvent } = await eventStore.createSession({
        workspacePath: '/test/project',
        workingDirectory: '/test/project',
        model: 'claude-sonnet-4-5-20250929',
      });

      const toolId1 = 'toolu_01MULTI_A';
      const toolId2 = 'toolu_01MULTI_B';

      const userMsg = await eventStore.append({
        sessionId: session.id,
        type: 'message.user',
        payload: { content: 'Read two files' },
        parentId: rootEvent.id,
      });

      const assistantMsg = await eventStore.append({
        sessionId: session.id,
        type: 'message.assistant',
        payload: {
          content: [
            { type: 'tool_use', id: toolId1, name: 'Read', arguments: { file_path: '/a.ts' } },
            { type: 'tool_use', id: toolId2, name: 'Read', arguments: { file_path: '/b.ts' } },
          ],
          usage: { inputTokens: 20, outputTokens: 18 },
        },
        parentId: userMsg.id,
      });

      const result1 = await eventStore.append({
        sessionId: session.id,
        type: 'tool.result',
        payload: { toolCallId: toolId1, content: 'a content', isError: false },
        parentId: assistantMsg.id,
      });

      const result2 = await eventStore.append({
        sessionId: session.id,
        type: 'tool.result',
        payload: { toolCallId: toolId2, content: 'b content', isError: false },
        parentId: result1.id,
      });

      // Fork after both tools complete
      const fork = await eventStore.fork(result2.id, { name: 'Multi-tool Fork' });

      const ancestors = await eventStore.getAncestors(fork.rootEvent.id);
      const toolResults = ancestors.filter(e => e.type === 'tool.result');

      expect(toolResults.length).toBe(2);
      expect(toolResults.map(r => r.payload.toolCallId).sort()).toEqual([toolId1, toolId2].sort());
    });
  });

  describe('fork at tool call event', () => {
    it('should fork at point where tool call was made but not yet executed', async () => {
      const { session, rootEvent } = await eventStore.createSession({
        workspacePath: '/test/project',
        workingDirectory: '/test/project',
        model: 'claude-sonnet-4-5-20250929',
      });

      const toolCallId = 'toolu_01PENDING';

      const userMsg = await eventStore.append({
        sessionId: session.id,
        type: 'message.user',
        payload: { content: 'Do something' },
        parentId: rootEvent.id,
      });

      const assistantMsg = await eventStore.append({
        sessionId: session.id,
        type: 'message.assistant',
        payload: {
          content: [
            { type: 'tool_use', id: toolCallId, name: 'Bash', arguments: { command: 'echo test' } },
          ],
          usage: { inputTokens: 12, outputTokens: 10 },
        },
        parentId: userMsg.id,
      });

      // Fork BEFORE tool result is added (simulating fork at tool call point)
      const fork = await eventStore.fork(assistantMsg.id, { name: 'Pre-Result Fork' });

      // Now add result to original session
      const result = await eventStore.append({
        sessionId: session.id,
        type: 'tool.result',
        payload: { toolCallId, content: 'test', isError: false },
        parentId: assistantMsg.id,
      });

      // The fork should NOT have the result (it was added after fork)
      const forkAncestors = await eventStore.getAncestors(fork.rootEvent.id);
      const forkToolResults = forkAncestors.filter(e => e.type === 'tool.result');
      expect(forkToolResults.length).toBe(0);

      // But original session has the result
      const origEvents = await eventStore.getEventsBySession(session.id);
      const origResults = origEvents.filter(e => e.type === 'tool.result');
      expect(origResults.length).toBe(1);
    });

    it('should allow independent tool results in fork vs original', async () => {
      const { session, rootEvent } = await eventStore.createSession({
        workspacePath: '/test/project',
        workingDirectory: '/test/project',
        model: 'claude-sonnet-4-5-20250929',
      });

      const toolCallId = 'toolu_01DIVERGE';

      const userMsg = await eventStore.append({
        sessionId: session.id,
        type: 'message.user',
        payload: { content: 'Run command' },
        parentId: rootEvent.id,
      });

      const assistantMsg = await eventStore.append({
        sessionId: session.id,
        type: 'message.assistant',
        payload: {
          content: [
            { type: 'tool_use', id: toolCallId, name: 'Bash', arguments: { command: 'ls' } },
          ],
          usage: { inputTokens: 10, outputTokens: 8 },
        },
        parentId: userMsg.id,
      });

      // Fork at the tool call
      const fork = await eventStore.fork(assistantMsg.id, { name: 'Divergent Fork' });

      // Original gets success result
      await eventStore.append({
        sessionId: session.id,
        type: 'tool.result',
        payload: { toolCallId, content: 'file1.ts\nfile2.ts', isError: false },
        parentId: assistantMsg.id,
      });

      // Fork gets error result (simulating different execution)
      await eventStore.append({
        sessionId: fork.session.id,
        type: 'tool.result',
        payload: { toolCallId, content: 'Permission denied', isError: true },
        parentId: fork.rootEvent.id,
      });

      // Verify different results
      const origEvents = await eventStore.getEventsBySession(session.id);
      const forkEvents = await eventStore.getEventsBySession(fork.session.id);

      const origResult = origEvents.find(e => e.type === 'tool.result');
      const forkResult = forkEvents.find(e => e.type === 'tool.result');

      expect(origResult?.payload.isError).toBe(false);
      expect(forkResult?.payload.isError).toBe(true);
    });
  });

  describe('tool chains in fork', () => {
    it('should handle tool chain continued after fork', async () => {
      const { session, rootEvent } = await eventStore.createSession({
        workspacePath: '/test/project',
        workingDirectory: '/test/project',
        model: 'claude-sonnet-4-5-20250929',
      });

      const toolId1 = 'toolu_01CHAIN_A';
      const toolId2 = 'toolu_01CHAIN_B';

      // First tool call/result
      const msg1 = await eventStore.append({
        sessionId: session.id,
        type: 'message.assistant',
        payload: {
          content: [{ type: 'tool_use', id: toolId1, name: 'Read', arguments: { file_path: '/x' } }],
          usage: { inputTokens: 10, outputTokens: 8 },
        },
        parentId: rootEvent.id,
      });

      const result1 = await eventStore.append({
        sessionId: session.id,
        type: 'tool.result',
        payload: { toolCallId: toolId1, content: 'x content', isError: false },
        parentId: msg1.id,
      });

      // Fork after first tool
      const fork = await eventStore.fork(result1.id, { name: 'Chain Fork' });

      // Continue chain in fork with second tool
      const forkMsg2 = await eventStore.append({
        sessionId: fork.session.id,
        type: 'message.assistant',
        payload: {
          content: [{ type: 'tool_use', id: toolId2, name: 'Write', arguments: { file_path: '/y' } }],
          usage: { inputTokens: 15, outputTokens: 12 },
        },
        parentId: fork.rootEvent.id,
      });

      const forkResult2 = await eventStore.append({
        sessionId: fork.session.id,
        type: 'tool.result',
        payload: { toolCallId: toolId2, content: 'written', isError: false },
        parentId: forkMsg2.id,
      });

      // Fork should have both tools in ancestry
      const ancestors = await eventStore.getAncestors(forkResult2.id);
      const toolResults = ancestors.filter(e => e.type === 'tool.result');

      expect(toolResults.length).toBe(2);
      expect(toolResults.map(r => r.payload.toolCallId).sort()).toEqual([toolId1, toolId2].sort());
    });
  });

  describe('tool ID uniqueness across fork', () => {
    it('should maintain unique tool IDs when same tool called in fork', async () => {
      const { session, rootEvent } = await eventStore.createSession({
        workspacePath: '/test/project',
        workingDirectory: '/test/project',
        model: 'claude-sonnet-4-5-20250929',
      });

      const origToolId = 'toolu_01ORIG';

      const msg1 = await eventStore.append({
        sessionId: session.id,
        type: 'message.assistant',
        payload: {
          content: [{ type: 'tool_use', id: origToolId, name: 'Read', arguments: { file_path: '/a' } }],
          usage: { inputTokens: 10, outputTokens: 8 },
        },
        parentId: rootEvent.id,
      });

      const result1 = await eventStore.append({
        sessionId: session.id,
        type: 'tool.result',
        payload: { toolCallId: origToolId, content: 'a', isError: false },
        parentId: msg1.id,
      });

      // Fork
      const fork = await eventStore.fork(result1.id, { name: 'Same Tool Fork' });

      // Use same tool in fork with different ID
      const forkToolId = 'toolu_02FORK';

      const forkMsg = await eventStore.append({
        sessionId: fork.session.id,
        type: 'message.assistant',
        payload: {
          content: [{ type: 'tool_use', id: forkToolId, name: 'Read', arguments: { file_path: '/b' } }],
          usage: { inputTokens: 10, outputTokens: 8 },
        },
        parentId: fork.rootEvent.id,
      });

      const forkResult = await eventStore.append({
        sessionId: fork.session.id,
        type: 'tool.result',
        payload: { toolCallId: forkToolId, content: 'b', isError: false },
        parentId: forkMsg.id,
      });

      // Verify both tool IDs are distinct and correctly paired
      const ancestors = await eventStore.getAncestors(forkResult.id);
      const toolResults = ancestors.filter(e => e.type === 'tool.result');

      expect(toolResults.length).toBe(2);
      expect(toolResults.find(r => r.payload.toolCallId === origToolId)).toBeDefined();
      expect(toolResults.find(r => r.payload.toolCallId === forkToolId)).toBeDefined();
    });
  });

  describe('error tool results', () => {
    it('should preserve error state in forked session', async () => {
      const { session, rootEvent } = await eventStore.createSession({
        workspacePath: '/test/project',
        workingDirectory: '/test/project',
        model: 'claude-sonnet-4-5-20250929',
      });

      const toolCallId = 'toolu_01ERROR';

      const msg = await eventStore.append({
        sessionId: session.id,
        type: 'message.assistant',
        payload: {
          content: [{ type: 'tool_use', id: toolCallId, name: 'Bash', arguments: { command: 'fail' } }],
          usage: { inputTokens: 10, outputTokens: 8 },
        },
        parentId: rootEvent.id,
      });

      const errorResult = await eventStore.append({
        sessionId: session.id,
        type: 'tool.result',
        payload: { toolCallId, content: 'Command failed with exit code 1', isError: true },
        parentId: msg.id,
      });

      // Fork after error
      const fork = await eventStore.fork(errorResult.id, { name: 'Error Fork' });

      // Verify error is in fork's history
      const ancestors = await eventStore.getAncestors(fork.rootEvent.id);
      const toolResult = ancestors.find(e => e.type === 'tool.result');

      expect(toolResult).toBeDefined();
      expect(toolResult!.payload.isError).toBe(true);
      expect(toolResult!.payload.content).toContain('failed');
    });
  });
});
