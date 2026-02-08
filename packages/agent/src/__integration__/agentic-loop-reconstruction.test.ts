/**
 * @fileoverview Tests for agentic loop message reconstruction
 *
 * These tests verify that message reconstruction properly handles agentic loops
 * where the assistant makes multiple tool calls across turns. The key scenarios:
 *
 * 1. Agentic loop: assistant(tool_use) -> tool.result -> assistant(continuation)
 *    - Must inject tool_result as user message between consecutive assistant messages
 *
 * 2. User response flow: assistant(tool_use) -> tool.result -> user(response)
 *    - Must NOT inject tool_result - user's message is the response
 *
 * 3. Session resume: When resuming a session with agentic history
 *    - Must reconstruct proper message alternation for API
 *
 * The Anthropic API requires:
 * - Messages must alternate between user and assistant roles
 * - tool_use blocks in assistant messages MUST be followed by user messages with tool_result
 */
import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import { EventStore, SessionId } from '../index.js';
import path from 'path';
import os from 'os';
import fs from 'fs';

describe('Agentic Loop Message Reconstruction', () => {
  let eventStore: EventStore;
  let testDir: string;
  let sessionId: SessionId;

  beforeEach(async () => {
    testDir = fs.mkdtempSync(path.join(os.tmpdir(), 'tron-agentic-loop-test-'));
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

  describe('Agentic loops (consecutive assistant messages)', () => {
    it('should inject tool_result user message between consecutive assistant messages', async () => {
      // User prompt
      await eventStore.append({
        sessionId,
        type: 'message.user',
        payload: { content: 'Read two files for me' },
      });

      // Turn 1: Assistant with tool_use
      await eventStore.append({
        sessionId,
        type: 'message.assistant',
        payload: {
          content: [
            { type: 'text', text: 'I\'ll read the first file.' },
            { type: 'tool_use', id: 'tc_1', name: 'Read', input: { file_path: 'file1.txt' } },
          ],
          turn: 1,
        },
      });

      // Tool result for turn 1
      await eventStore.append({
        sessionId,
        type: 'tool.result',
        payload: {
          toolCallId: 'tc_1',
          content: 'Contents of file1',
          isError: false,
        },
      });

      // Turn 2: Assistant continues (this would cause consecutive assistants without fix)
      await eventStore.append({
        sessionId,
        type: 'message.assistant',
        payload: {
          content: [
            { type: 'text', text: 'Now let me read the second file.' },
            { type: 'tool_use', id: 'tc_2', name: 'Read', input: { file_path: 'file2.txt' } },
          ],
          turn: 2,
        },
      });

      // Tool result for turn 2
      await eventStore.append({
        sessionId,
        type: 'tool.result',
        payload: {
          toolCallId: 'tc_2',
          content: 'Contents of file2',
          isError: false,
        },
      });

      // Turn 3: Assistant finishes
      await eventStore.append({
        sessionId,
        type: 'message.assistant',
        payload: {
          content: [{ type: 'text', text: 'I\'ve read both files for you.' }],
          turn: 3,
        },
      });

      // Reconstruct messages
      const messages = await eventStore.getMessagesAtHead(sessionId);

      // Expected: 6 messages with proper alternation
      // user -> assistant -> user(tool_result) -> assistant -> user(tool_result) -> assistant
      expect(messages.length).toBe(6);

      expect(messages[0].role).toBe('user');
      expect(messages[0].content).toBe('Read two files for me');

      expect(messages[1].role).toBe('assistant');
      expect((messages[1].content as any[])[0].type).toBe('text');
      expect((messages[1].content as any[])[1].type).toBe('tool_use');

      expect(messages[2].role).toBe('toolResult');
      expect((messages[2] as any).toolCallId).toBe('tc_1');
      expect((messages[2] as any).content).toBe('Contents of file1');

      expect(messages[3].role).toBe('assistant');
      expect((messages[3].content as any[])[1].type).toBe('tool_use');

      expect(messages[4].role).toBe('toolResult');
      expect((messages[4] as any).toolCallId).toBe('tc_2');
      expect((messages[4] as any).content).toBe('Contents of file2');

      expect(messages[5].role).toBe('assistant');
      expect((messages[5].content as any[])[0].text).toContain('both files');
    });

    it('should handle multiple tool calls in single turn followed by continuation', async () => {
      // User prompt
      await eventStore.append({
        sessionId,
        type: 'message.user',
        payload: { content: 'Check the project files' },
      });

      // Turn 1: Assistant calls multiple tools
      await eventStore.append({
        sessionId,
        type: 'message.assistant',
        payload: {
          content: [
            { type: 'tool_use', id: 'tc_ls', name: 'Ls', input: { path: '.' } },
            { type: 'tool_use', id: 'tc_read', name: 'Read', input: { file_path: 'README.md' } },
          ],
          turn: 1,
        },
      });

      // Tool results
      await eventStore.append({
        sessionId,
        type: 'tool.result',
        payload: { toolCallId: 'tc_ls', content: 'file1.txt\nfile2.txt', isError: false },
      });
      await eventStore.append({
        sessionId,
        type: 'tool.result',
        payload: { toolCallId: 'tc_read', content: '# README', isError: false },
      });

      // Turn 2: Assistant continues
      await eventStore.append({
        sessionId,
        type: 'message.assistant',
        payload: {
          content: [{ type: 'text', text: 'The project has two files and a README.' }],
          turn: 2,
        },
      });

      const messages = await eventStore.getMessagesAtHead(sessionId);

      // Expected: 5 messages
      // user -> assistant(tool_use x2) -> toolResult -> toolResult -> assistant
      expect(messages.length).toBe(5);

      expect(messages[0].role).toBe('user');
      expect(messages[1].role).toBe('assistant');
      expect(messages[2].role).toBe('toolResult');
      expect(messages[3].role).toBe('toolResult');
      expect(messages[4].role).toBe('assistant');

      // Each tool result should be a separate toolResult message
      expect((messages[2] as any).toolCallId).toBe('tc_ls');
      expect((messages[3] as any).toolCallId).toBe('tc_read');
    });
  });

  describe('User response flows (no injection needed)', () => {
    it('should NOT inject tool_result when user message follows', async () => {
      // User prompt
      await eventStore.append({
        sessionId,
        type: 'message.user',
        payload: { content: 'Ask me something' },
      });

      // Assistant asks a question via tool
      await eventStore.append({
        sessionId,
        type: 'message.assistant',
        payload: {
          content: [
            { type: 'tool_use', id: 'tc_ask', name: 'AskUserQuestion', input: { question: 'Yes or no?' } },
          ],
          turn: 1,
        },
      });

      // Tool result (immediate return)
      await eventStore.append({
        sessionId,
        type: 'tool.result',
        payload: { toolCallId: 'tc_ask', content: 'Question presented', isError: false },
      });

      // User responds directly
      await eventStore.append({
        sessionId,
        type: 'message.user',
        payload: { content: 'Yes, proceed' },
      });

      const messages = await eventStore.getMessagesAtHead(sessionId);

      // Expected: 3 messages (no injected tool_result)
      // user -> assistant -> user
      expect(messages.length).toBe(3);
      expect(messages[0].role).toBe('user');
      expect(messages[1].role).toBe('assistant');
      expect(messages[2].role).toBe('user');
      expect(messages[2].content).toBe('Yes, proceed');
    });

    it('should NOT inject tool_result when message.user with tool_result content follows', async () => {
      // User prompt
      await eventStore.append({
        sessionId,
        type: 'message.user',
        payload: { content: 'Read a file' },
      });

      // Assistant with tool
      await eventStore.append({
        sessionId,
        type: 'message.assistant',
        payload: {
          content: [
            { type: 'tool_use', id: 'tc_1', name: 'Read', input: { file_path: 'test.txt' } },
          ],
          turn: 1,
        },
      });

      // Discrete tool.result event (for streaming)
      await eventStore.append({
        sessionId,
        type: 'tool.result',
        payload: { toolCallId: 'tc_1', content: 'File contents', isError: false },
      });

      // Proper message.user with tool_result (as stored by event-store-orchestrator for interrupts)
      await eventStore.append({
        sessionId,
        type: 'message.user',
        payload: {
          content: [
            { type: 'tool_result', tool_use_id: 'tc_1', content: 'File contents' },
          ],
        },
      });

      const messages = await eventStore.getMessagesAtHead(sessionId);

      // Expected: 3 messages (discrete tool.result discarded, message.user preserved)
      expect(messages.length).toBe(3);
      expect(messages[0].role).toBe('user');
      expect(messages[1].role).toBe('assistant');
      expect(messages[2].role).toBe('user');
      expect(Array.isArray(messages[2].content)).toBe(true);
    });
  });

  describe('Session resume scenarios', () => {
    it('should reconstruct valid message sequence for resumed agentic session', async () => {
      // Simulate events from a previous session with agentic loop

      // Initial conversation
      await eventStore.append({
        sessionId,
        type: 'message.user',
        payload: { content: 'Help me debug this' },
      });

      await eventStore.append({
        sessionId,
        type: 'message.assistant',
        payload: {
          content: [
            { type: 'text', text: 'Let me check the logs.' },
            { type: 'tool_use', id: 'tc_grep', name: 'Grep', input: { pattern: 'ERROR' } },
          ],
          turn: 1,
        },
      });

      await eventStore.append({
        sessionId,
        type: 'tool.result',
        payload: { toolCallId: 'tc_grep', content: 'ERROR: Connection failed', isError: false },
      });

      await eventStore.append({
        sessionId,
        type: 'message.assistant',
        payload: {
          content: [
            { type: 'text', text: 'Found an error. Let me check the config.' },
            { type: 'tool_use', id: 'tc_read', name: 'Read', input: { file_path: 'config.yml' } },
          ],
          turn: 2,
        },
      });

      await eventStore.append({
        sessionId,
        type: 'tool.result',
        payload: { toolCallId: 'tc_read', content: 'host: localhost', isError: false },
      });

      await eventStore.append({
        sessionId,
        type: 'message.assistant',
        payload: {
          content: [{ type: 'text', text: 'The config looks correct. The issue is...' }],
          turn: 3,
        },
      });

      // User sends new message (simulating resume)
      await eventStore.append({
        sessionId,
        type: 'message.user',
        payload: { content: 'What did you find?' },
      });

      const messages = await eventStore.getMessagesAtHead(sessionId);

      // Verify alternation is correct
      const roles = messages.map(m => m.role);
      for (let i = 0; i < roles.length - 1; i++) {
        expect(roles[i]).not.toBe(roles[i + 1]);
      }

      // Verify structure: user, assistant, toolResult, assistant, toolResult, assistant, user
      // Note: The final user message doesn't need tool_result injection because no assistant follows
      expect(messages.length).toBe(7);
      expect(roles).toEqual(['user', 'assistant', 'toolResult', 'assistant', 'toolResult', 'assistant', 'user']);
    });

    it('should handle session with multiple agentic turns properly', async () => {
      // Create session with multiple agentic turns (simulating what would happen with forked session)
      await eventStore.append({
        sessionId,
        type: 'message.user',
        payload: { content: 'Start task' },
      });

      await eventStore.append({
        sessionId,
        type: 'message.assistant',
        payload: {
          content: [
            { type: 'tool_use', id: 'tc_1', name: 'Bash', input: { command: 'ls' } },
          ],
          turn: 1,
        },
      });

      await eventStore.append({
        sessionId,
        type: 'tool.result',
        payload: { toolCallId: 'tc_1', content: 'file.txt', isError: false },
      });

      await eventStore.append({
        sessionId,
        type: 'message.assistant',
        payload: {
          content: [{ type: 'text', text: 'Found files.' }],
          turn: 2,
        },
      });

      // Continue with more conversation
      await eventStore.append({
        sessionId,
        type: 'message.user',
        payload: { content: 'Continue the task' },
      });

      await eventStore.append({
        sessionId,
        type: 'message.assistant',
        payload: {
          content: [{ type: 'text', text: 'Continuing...' }],
          turn: 3,
        },
      });

      const messages = await eventStore.getMessagesAtHead(sessionId);

      // Verify proper alternation
      const roles = messages.map(m => m.role);
      for (let i = 0; i < roles.length - 1; i++) {
        expect(roles[i]).not.toBe(roles[i + 1]);
      }

      // Expected: user, assistant, toolResult, assistant, user, assistant
      expect(messages.length).toBe(6);
      expect(roles).toEqual(['user', 'assistant', 'toolResult', 'assistant', 'user', 'assistant']);
    });
  });

  describe('Edge cases', () => {
    it('should handle tool error results in agentic loop', async () => {
      await eventStore.append({
        sessionId,
        type: 'message.user',
        payload: { content: 'Run command' },
      });

      await eventStore.append({
        sessionId,
        type: 'message.assistant',
        payload: {
          content: [
            { type: 'tool_use', id: 'tc_1', name: 'Bash', input: { command: 'fail' } },
          ],
          turn: 1,
        },
      });

      await eventStore.append({
        sessionId,
        type: 'tool.result',
        payload: {
          toolCallId: 'tc_1',
          content: 'Command not found: fail',
          isError: true,
        },
      });

      await eventStore.append({
        sessionId,
        type: 'message.assistant',
        payload: {
          content: [{ type: 'text', text: 'The command failed. Let me try another approach.' }],
          turn: 2,
        },
      });

      const messages = await eventStore.getMessagesAtHead(sessionId);

      expect(messages.length).toBe(4);

      // Verify error flag is preserved in toolResult message
      expect(messages[2].role).toBe('toolResult');
      expect((messages[2] as any).isError).toBe(true);
    });

    it('should handle compaction boundary in agentic session', async () => {
      // Pre-compaction messages
      await eventStore.append({
        sessionId,
        type: 'message.user',
        payload: { content: 'Old message 1' },
      });

      await eventStore.append({
        sessionId,
        type: 'message.assistant',
        payload: {
          content: [{ type: 'text', text: 'Old response 1' }],
          turn: 1,
        },
      });

      // Compaction events
      await eventStore.append({
        sessionId,
        type: 'compact.boundary',
        payload: { reason: 'context_limit' },
      });

      await eventStore.append({
        sessionId,
        type: 'compact.summary',
        payload: { summary: 'Previous conversation discussed old topics.' },
      });

      // Post-compaction agentic loop
      await eventStore.append({
        sessionId,
        type: 'message.user',
        payload: { content: 'New task' },
      });

      await eventStore.append({
        sessionId,
        type: 'message.assistant',
        payload: {
          content: [
            { type: 'tool_use', id: 'tc_1', name: 'Read', input: { file_path: 'new.txt' } },
          ],
          turn: 2,
        },
      });

      await eventStore.append({
        sessionId,
        type: 'tool.result',
        payload: { toolCallId: 'tc_1', content: 'New file contents', isError: false },
      });

      await eventStore.append({
        sessionId,
        type: 'message.assistant',
        payload: {
          content: [{ type: 'text', text: 'Here is the new file.' }],
          turn: 3,
        },
      });

      const messages = await eventStore.getMessagesAtHead(sessionId);

      // Should have: compaction pair + user + assistant + user(tool_result) + assistant
      expect(messages.length).toBe(6);

      // First two are compaction summary pair
      expect(messages[0].content).toContain('Previous conversation');
      expect((messages[1].content as any[])[0].text).toContain('understand');

      // Verify proper structure after compaction - tool results are toolResult messages
      const roles = messages.map(m => m.role);
      expect(roles).toEqual(['user', 'assistant', 'user', 'assistant', 'toolResult', 'assistant']);
    });

    it('should handle context.cleared in agentic session', async () => {
      // Pre-clear messages with tool loop
      await eventStore.append({
        sessionId,
        type: 'message.user',
        payload: { content: 'Clear me' },
      });

      await eventStore.append({
        sessionId,
        type: 'message.assistant',
        payload: {
          content: [
            { type: 'tool_use', id: 'tc_1', name: 'Read', input: { file_path: 'old.txt' } },
          ],
          turn: 1,
        },
      });

      await eventStore.append({
        sessionId,
        type: 'tool.result',
        payload: { toolCallId: 'tc_1', content: 'Old contents', isError: false },
      });

      // Clear context
      await eventStore.append({
        sessionId,
        type: 'context.cleared',
        payload: { reason: 'user_requested' },
      });

      // New conversation
      await eventStore.append({
        sessionId,
        type: 'message.user',
        payload: { content: 'Fresh start' },
      });

      await eventStore.append({
        sessionId,
        type: 'message.assistant',
        payload: {
          content: [{ type: 'text', text: 'Hello! How can I help?' }],
          turn: 2,
        },
      });

      const messages = await eventStore.getMessagesAtHead(sessionId);

      // Only post-clear messages should remain
      expect(messages.length).toBe(2);
      expect(messages[0].content).toBe('Fresh start');
    });

    it('should handle empty tool result content', async () => {
      await eventStore.append({
        sessionId,
        type: 'message.user',
        payload: { content: 'Test empty' },
      });

      await eventStore.append({
        sessionId,
        type: 'message.assistant',
        payload: {
          content: [
            { type: 'tool_use', id: 'tc_1', name: 'Write', input: { file_path: 'test.txt', content: 'x' } },
          ],
          turn: 1,
        },
      });

      await eventStore.append({
        sessionId,
        type: 'tool.result',
        payload: { toolCallId: 'tc_1', content: '', isError: false },
      });

      await eventStore.append({
        sessionId,
        type: 'message.assistant',
        payload: {
          content: [{ type: 'text', text: 'File written successfully.' }],
          turn: 2,
        },
      });

      const messages = await eventStore.getMessagesAtHead(sessionId);

      expect(messages.length).toBe(4);

      // Empty content should still be included in toolResult message
      expect(messages[2].role).toBe('toolResult');
      expect((messages[2] as any).content).toBe('');
    });
  });

  describe('Interrupted multi-turn session (regression)', () => {
    it('should have no duplicate tool_use IDs when 3-turn session interrupted during turn 3', async () => {
      // Simulates the bug: persistInterruptedContent() used accumulated state
      // which spans ALL turns, creating duplicates of turns 1 and 2 content.
      //
      // Correct behavior: only turn 3's unpersisted content should be in the
      // interrupted message.assistant event.

      // User prompt
      await eventStore.append({
        sessionId,
        type: 'message.user',
        payload: { content: 'Do a multi-step task' },
      });

      // Turn 1: assistant with tool_use (persisted normally)
      await eventStore.append({
        sessionId,
        type: 'message.assistant',
        payload: {
          content: [
            { type: 'text', text: 'Step 1' },
            { type: 'tool_use', id: 'tc_1', name: 'Read', input: { file_path: 'a.ts' } },
          ],
          turn: 1,
        },
      });

      await eventStore.append({
        sessionId,
        type: 'tool.result',
        payload: { toolCallId: 'tc_1', content: 'a contents', isError: false },
      });

      // Turn 2: assistant continues (persisted normally)
      await eventStore.append({
        sessionId,
        type: 'message.assistant',
        payload: {
          content: [
            { type: 'text', text: 'Step 2' },
            { type: 'tool_use', id: 'tc_2', name: 'Read', input: { file_path: 'b.ts' } },
          ],
          turn: 2,
        },
      });

      await eventStore.append({
        sessionId,
        type: 'tool.result',
        payload: { toolCallId: 'tc_2', content: 'b contents', isError: false },
      });

      // Turn 3: interrupted — only this turn's content should appear here
      await eventStore.append({
        sessionId,
        type: 'message.assistant',
        payload: {
          content: [
            { type: 'text', text: 'Step 3' },
            { type: 'tool_use', id: 'tc_3', name: 'Bash', input: { command: 'make build' } },
          ],
          turn: 3,
          interrupted: true,
        },
      });

      await eventStore.append({
        sessionId,
        type: 'tool.result',
        payload: { toolCallId: 'tc_3', content: 'Command interrupted (no output captured)', isError: false, interrupted: true },
      });

      // Reconstruct messages
      const messages = await eventStore.getMessagesAtHead(sessionId);

      // Collect ALL tool_use IDs across all messages
      const allToolUseIds: string[] = [];
      for (const msg of messages) {
        if (msg.role === 'assistant') {
          for (const block of (msg.content as any[])) {
            if (block.type === 'tool_use') {
              allToolUseIds.push(block.id);
            }
          }
        }
      }

      // CRITICAL: No duplicate tool_use IDs
      const uniqueIds = new Set(allToolUseIds);
      expect(allToolUseIds.length).toBe(uniqueIds.size);

      // Should have exactly 3 unique tool_use IDs
      expect(uniqueIds.size).toBe(3);
      expect(uniqueIds.has('tc_1')).toBe(true);
      expect(uniqueIds.has('tc_2')).toBe(true);
      expect(uniqueIds.has('tc_3')).toBe(true);
    });

    it('should handle interrupt after all tools complete in turn 3', async () => {
      await eventStore.append({
        sessionId,
        type: 'message.user',
        payload: { content: 'Multi-step' },
      });

      // Turn 1
      await eventStore.append({
        sessionId,
        type: 'message.assistant',
        payload: {
          content: [
            { type: 'tool_use', id: 'tc_1', name: 'Read', input: { file_path: 'a.ts' } },
          ],
          turn: 1,
        },
      });
      await eventStore.append({
        sessionId,
        type: 'tool.result',
        payload: { toolCallId: 'tc_1', content: 'a', isError: false },
      });

      // Turn 2
      await eventStore.append({
        sessionId,
        type: 'message.assistant',
        payload: {
          content: [
            { type: 'tool_use', id: 'tc_2', name: 'Read', input: { file_path: 'b.ts' } },
          ],
          turn: 2,
        },
      });
      await eventStore.append({
        sessionId,
        type: 'tool.result',
        payload: { toolCallId: 'tc_2', content: 'b', isError: false },
      });

      // Turn 3: tools completed, then interrupted before LLM response
      await eventStore.append({
        sessionId,
        type: 'message.assistant',
        payload: {
          content: [
            { type: 'tool_use', id: 'tc_3', name: 'Read', input: { file_path: 'c.ts' } },
          ],
          turn: 3,
        },
      });
      await eventStore.append({
        sessionId,
        type: 'tool.result',
        payload: { toolCallId: 'tc_3', content: 'c', isError: false },
      });

      const messages = await eventStore.getMessagesAtHead(sessionId);

      // Verify no duplicate tool_use IDs
      const allToolUseIds: string[] = [];
      for (const msg of messages) {
        if (msg.role === 'assistant') {
          for (const block of (msg.content as any[])) {
            if (block.type === 'tool_use') {
              allToolUseIds.push(block.id);
            }
          }
        }
      }
      expect(new Set(allToolUseIds).size).toBe(allToolUseIds.length);

      // Verify proper alternation
      const roles = messages.map(m => m.role);
      // user -> assistant -> toolResult -> assistant -> toolResult -> assistant -> toolResult
      expect(roles[0]).toBe('user');
    });

    it('should handle interrupt during first turn with tool calls', async () => {
      await eventStore.append({
        sessionId,
        type: 'message.user',
        payload: { content: 'Quick task' },
      });

      // Only turn 1, interrupted
      await eventStore.append({
        sessionId,
        type: 'message.assistant',
        payload: {
          content: [
            { type: 'text', text: 'Starting...' },
            { type: 'tool_use', id: 'tc_1', name: 'Bash', input: { command: 'ls' } },
          ],
          turn: 1,
          interrupted: true,
        },
      });

      await eventStore.append({
        sessionId,
        type: 'tool.result',
        payload: { toolCallId: 'tc_1', content: 'interrupted', isError: false, interrupted: true },
      });

      const messages = await eventStore.getMessagesAtHead(sessionId);

      // Should have: user -> assistant -> toolResult
      expect(messages).toHaveLength(3);
      expect(messages[0]!.role).toBe('user');
      expect(messages[1]!.role).toBe('assistant');
      expect(messages[2]!.role).toBe('toolResult');

      // Only one tool_use ID
      const assistantContent = (messages[1] as any).content;
      const toolUseBlocks = assistantContent.filter((b: any) => b.type === 'tool_use');
      expect(toolUseBlocks).toHaveLength(1);
    });
  });
});
