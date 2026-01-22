/**
 * @fileoverview Tests for AskUserQuestion async flow
 *
 * The expected flow is:
 * 1. User sends prompt
 * 2. Agent calls AskUserQuestion tool (tool_use)
 * 3. Tool returns immediately with "Questions presented to user..." (tool_result)
 * 4. Turn ends
 * 5. User sends answer as plain text prompt
 * 6. Agent receives and responds
 *
 * The message sequence sent to Anthropic API should be:
 * [
 *   { role: "user", content: "Ask me a test question" },
 *   { role: "assistant", content: [{ type: "tool_use", ... }] },
 *   { role: "user", content: [{ type: "tool_result", ... }] },
 *   { role: "user", content: "[Answers to your questions]..." }
 * ]
 */
import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import { EventStore, SessionId } from '../index.js';
import path from 'path';
import os from 'os';
import fs from 'fs';

describe('AskUserQuestion Flow', () => {
  let eventStore: EventStore;
  let testDir: string;
  let sessionId: SessionId;

  beforeEach(async () => {
    testDir = fs.mkdtempSync(path.join(os.tmpdir(), 'tron-askuserquestion-test-'));
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

  describe('Message reconstruction for Anthropic API', () => {
    it('should reconstruct messages in correct order for AskUserQuestion flow', async () => {
      // Turn 1: User asks agent to ask a question
      await eventStore.append({
        sessionId,
        type: 'message.user',
        payload: { content: 'Ask me a test question' },
      });

      // Turn 1: Agent responds with AskUserQuestion tool call
      await eventStore.append({
        sessionId,
        type: 'message.assistant',
        payload: {
          content: [
            {
              type: 'tool_use',
              id: 'tc_ask_123',
              name: 'AskUserQuestion',
              input: {
                questions: [{
                  id: 'q1',
                  question: 'What is your favorite color?',
                  options: [
                    { label: 'Red', description: 'The color of fire' },
                    { label: 'Blue', description: 'The color of sky' },
                  ],
                  mode: 'single',
                }],
              },
            },
          ],
          turn: 1,
        },
      });

      // Turn 1: Tool result stored (tool returns immediately)
      await eventStore.append({
        sessionId,
        type: 'tool.result',
        payload: {
          toolCallId: 'tc_ask_123',
          content: 'Questions presented to user:\n1. What is your favorite color?',
          isError: false,
        },
      });

      // Turn 2: User answers the question (plain text, NOT tool_result)
      await eventStore.append({
        sessionId,
        type: 'message.user',
        payload: {
          content: '[Answers to your questions]\n\n**What is your favorite color?**\nAnswer: Blue',
        },
      });

      // Reconstruct messages
      const messages = await eventStore.getMessagesAtHead(sessionId);

      // Expected: 3 messages (user prompt, assistant with tool_use, user answer)
      // The tool.result should NOT create a separate message - it's for streaming only
      expect(messages.length).toBe(3);

      // Message 1: Original user prompt
      expect(messages[0].role).toBe('user');
      expect(messages[0].content).toBe('Ask me a test question');

      // Message 2: Assistant with tool_use
      expect(messages[1].role).toBe('assistant');
      expect(Array.isArray(messages[1].content)).toBe(true);
      const assistantContent = messages[1].content as any[];
      expect(assistantContent[0].type).toBe('tool_use');
      expect(assistantContent[0].name).toBe('AskUserQuestion');

      // Message 3: User answer (plain text)
      expect(messages[2].role).toBe('user');
      expect(messages[2].content).toContain('[Answers to your questions]');
    });

    it('should handle multiple tool calls in same turn correctly', async () => {
      // User prompt
      await eventStore.append({
        sessionId,
        type: 'message.user',
        payload: { content: 'Read a file and ask me a question' },
      });

      // Assistant with Read tool call
      await eventStore.append({
        sessionId,
        type: 'message.assistant',
        payload: {
          content: [
            {
              type: 'tool_use',
              id: 'tc_read_1',
              name: 'Read',
              input: { file_path: '/test/file.txt' },
            },
          ],
          turn: 1,
        },
      });

      // Tool results for Read (stored as user message for proper sequencing)
      await eventStore.append({
        sessionId,
        type: 'message.user',
        payload: {
          content: [
            {
              type: 'tool_result',
              tool_use_id: 'tc_read_1',
              content: 'File contents here',
            },
          ],
        },
      });

      // Second assistant message with AskUserQuestion
      await eventStore.append({
        sessionId,
        type: 'message.assistant',
        payload: {
          content: [
            {
              type: 'text',
              text: 'I read the file. Now let me ask you a question.',
            },
            {
              type: 'tool_use',
              id: 'tc_ask_2',
              name: 'AskUserQuestion',
              input: {
                questions: [{
                  id: 'q1',
                  question: 'Do you want to proceed?',
                  options: [
                    { label: 'Yes', description: 'Continue' },
                    { label: 'No', description: 'Stop' },
                  ],
                  mode: 'single',
                }],
              },
            },
          ],
          turn: 2,
        },
      });

      // Tool result for AskUserQuestion (stored as user message)
      await eventStore.append({
        sessionId,
        type: 'message.user',
        payload: {
          content: [
            {
              type: 'tool_result',
              tool_use_id: 'tc_ask_2',
              content: 'Questions presented to user:\n1. Do you want to proceed?',
            },
          ],
        },
      });

      // User answers (this will merge with the tool_result message above)
      await eventStore.append({
        sessionId,
        type: 'message.user',
        payload: {
          content: '[Answers to your questions]\n\n**Do you want to proceed?**\nAnswer: Yes',
        },
      });

      // Reconstruct messages
      const messages = await eventStore.getMessagesAtHead(sessionId);

      // Expected: 5 messages with proper alternation:
      // user prompt, assistant (Read), user (tool_result), assistant (AskUserQuestion), user (tool_result + answer merged)
      expect(messages.length).toBe(5);
      expect(messages[0].role).toBe('user');
      expect(messages[1].role).toBe('assistant');
      expect(messages[2].role).toBe('user');
      expect(messages[3].role).toBe('assistant');
      expect(messages[4].role).toBe('user');
    });
  });

  describe('No toolResult role in reconstruction', () => {
    it('should never create toolResult role messages from tool.result events', async () => {
      // Simulate a complete flow with tool.result events
      await eventStore.append({
        sessionId,
        type: 'message.user',
        payload: { content: 'Test prompt' },
      });

      await eventStore.append({
        sessionId,
        type: 'message.assistant',
        payload: {
          content: [
            {
              type: 'tool_use',
              id: 'tc_1',
              name: 'SomeTool',
              input: { param: 'value' },
            },
          ],
          turn: 1,
        },
      });

      await eventStore.append({
        sessionId,
        type: 'tool.result',
        payload: {
          toolCallId: 'tc_1',
          content: 'Tool output',
          isError: false,
        },
      });

      await eventStore.append({
        sessionId,
        type: 'message.user',
        payload: { content: 'Follow up message' },
      });

      const messages = await eventStore.getMessagesAtHead(sessionId);

      // Verify NO toolResult role messages exist
      for (const msg of messages) {
        expect(msg.role).not.toBe('toolResult');
      }

      // Should only have user and assistant messages
      const roles = messages.map(m => m.role);
      expect(roles).toEqual(['user', 'assistant', 'user']);
    });
  });
});
