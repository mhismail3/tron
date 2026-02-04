/**
 * @fileoverview Fork Integration Tests - Thinking Block Handling
 *
 * Tests fork behavior with thinking blocks, specifically:
 * - Forking sessions with interrupted thinking-only assistant messages
 * - Reconstruction correctly handles thinking blocks
 * - Sanitization removes thinking-only messages without signatures
 * - Forked sessions can proceed without API errors
 *
 * This addresses a real bug: sess_303ac47a2c6a (fork of sess_696cd493332b) failed
 * because an interrupted assistant message containing only a thinking block (no signature)
 * was reconstructed and sent to the API, which rejected the empty content.
 */
import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import { EventStore } from '../../index.js';
import { sanitizeMessages } from '../../core/utils/message-sanitizer.js';
import path from 'path';
import os from 'os';
import fs from 'fs';

describe('Fork Integration - Thinking Block Handling', () => {
  let eventStore: EventStore;
  let testDir: string;

  beforeEach(async () => {
    testDir = fs.mkdtempSync(path.join(os.tmpdir(), 'tron-fork-thinking-test-'));
    const dbPath = path.join(testDir, 'events.db');
    eventStore = new EventStore(dbPath);
    await eventStore.initialize();
  });

  afterEach(async () => {
    await eventStore.close();
    fs.rmSync(testDir, { recursive: true, force: true });
  });

  describe('interrupted thinking-only assistant messages', () => {
    it('should handle fork with thinking-only message (no signature)', async () => {
      // This reproduces the exact bug from sess_696cd493332b / sess_303ac47a2c6a
      const { session, rootEvent } = await eventStore.createSession({
        workspacePath: '/test/project',
        workingDirectory: '/test/project',
        model: 'claude-haiku-4-5-20251001', // Non-extended thinking model (no signatures)
      });

      // Turn 1: Normal exchange
      const msg1 = await eventStore.append({
        sessionId: session.id,
        type: 'message.user',
        payload: { content: 'Hey' },
        parentId: rootEvent.id,
      });

      const msg2 = await eventStore.append({
        sessionId: session.id,
        type: 'message.assistant',
        payload: {
          content: [
            { type: 'thinking', thinking: 'User greeting, respond naturally' },
            { type: 'text', text: 'Hey! What can I help you with?' },
          ],
          usage: { inputTokens: 100, outputTokens: 50 },
        },
        parentId: msg1.id,
      });

      // Turn 2: User sends message, but gets interrupted during thinking
      const msg3 = await eventStore.append({
        sessionId: session.id,
        type: 'message.user',
        payload: { content: 'What\'s up' },
        parentId: msg2.id,
      });

      // INTERRUPTED: Only thinking content, no text, no signature (Haiku doesn't provide signatures)
      const msg4Interrupted = await eventStore.append({
        sessionId: session.id,
        type: 'message.assistant',
        payload: {
          content: [
            { type: 'thinking', thinking: 'The user is just greeting me casually...' },
            // NO text block - session was interrupted before text was generated
          ],
          usage: { inputTokens: 50, outputTokens: 20 },
          interrupted: true,
          stopReason: 'interrupted',
        },
        parentId: msg3.id,
      });

      // Turn 3: User continues with new message
      const msg5 = await eventStore.append({
        sessionId: session.id,
        type: 'message.user',
        payload: { content: 'What can you do' },
        parentId: msg4Interrupted.id,
      });

      // Normal response
      const msg6 = await eventStore.append({
        sessionId: session.id,
        type: 'message.assistant',
        payload: {
          content: [
            { type: 'thinking', thinking: 'User asking about capabilities...' },
            { type: 'text', text: 'I can help with many things!' },
          ],
          usage: { inputTokens: 150, outputTokens: 100 },
        },
        parentId: msg5.id,
      });

      // Fork from the final message
      const forkResult = await eventStore.fork(msg6.id, { name: 'Fork with thinking' });

      // Get messages at the fork point
      const messages = await eventStore.getMessagesAt(forkResult.rootEvent.id);

      // Verify: The thinking-only message should NOT be present after sanitization
      // The sanitizer should have removed it
      const sanitized = sanitizeMessages(messages);

      // Check that the sanitized messages don't include any thinking-only assistant messages
      const assistantMessages = sanitized.messages.filter(m => m.role === 'assistant');
      for (const msg of assistantMessages) {
        const content = (msg as { content: Array<{ type: string }> }).content;
        // Each assistant message should have at least one non-thinking block
        const hasNonThinkingContent = content.some(
          block => block.type !== 'thinking' ||
            (block.type === 'thinking' && (block as { signature?: string }).signature)
        );
        expect(hasNonThinkingContent).toBe(true);
      }

      // The fix should have removed the thinking-only message
      expect(sanitized.fixes.some(f => f.type === 'removed_thinking_only_message')).toBe(true);
    });

    it('should preserve thinking with signatures (extended thinking models)', async () => {
      const { session, rootEvent } = await eventStore.createSession({
        workspacePath: '/test/project',
        workingDirectory: '/test/project',
        model: 'claude-opus-4-5-20251101', // Extended thinking model (provides signatures)
      });

      const msg1 = await eventStore.append({
        sessionId: session.id,
        type: 'message.user',
        payload: { content: 'Hello' },
        parentId: rootEvent.id,
      });

      // Assistant message with thinking that HAS a signature
      const msg2 = await eventStore.append({
        sessionId: session.id,
        type: 'message.assistant',
        payload: {
          content: [
            {
              type: 'thinking',
              thinking: 'Let me think about this...',
              signature: 'sig_abc123xyz', // Extended thinking signature
            },
          ],
          usage: { inputTokens: 100, outputTokens: 50 },
        },
        parentId: msg1.id,
      });

      const forkResult = await eventStore.fork(msg2.id, { name: 'Fork with signed thinking' });
      const messages = await eventStore.getMessagesAt(forkResult.rootEvent.id);
      const sanitized = sanitizeMessages(messages);

      // Thinking with signature should be preserved
      expect(sanitized.fixes.some(f => f.type === 'removed_thinking_only_message')).toBe(false);

      // The message should still be there
      const assistantMessages = sanitized.messages.filter(m => m.role === 'assistant');
      expect(assistantMessages.length).toBe(1);
    });

    it('should handle multiple consecutive thinking-only interrupts', async () => {
      const { session, rootEvent } = await eventStore.createSession({
        workspacePath: '/test/project',
        workingDirectory: '/test/project',
        model: 'claude-haiku-4-5-20251001',
      });

      let lastEventId = rootEvent.id;

      // Multiple rapid interrupts during thinking
      for (let i = 0; i < 3; i++) {
        const user = await eventStore.append({
          sessionId: session.id,
          type: 'message.user',
          payload: { content: `Prompt ${i}` },
          parentId: lastEventId,
        });

        const interrupted = await eventStore.append({
          sessionId: session.id,
          type: 'message.assistant',
          payload: {
            content: [{ type: 'thinking', thinking: `Thinking ${i}...` }],
            interrupted: true,
          },
          parentId: user.id,
        });
        lastEventId = interrupted.id;
      }

      // Final successful response
      const finalUser = await eventStore.append({
        sessionId: session.id,
        type: 'message.user',
        payload: { content: 'Final prompt' },
        parentId: lastEventId,
      });

      const finalAssistant = await eventStore.append({
        sessionId: session.id,
        type: 'message.assistant',
        payload: {
          content: [
            { type: 'thinking', thinking: 'Final thinking' },
            { type: 'text', text: 'Final response' },
          ],
        },
        parentId: finalUser.id,
      });

      const forkResult = await eventStore.fork(finalAssistant.id, { name: 'Multi-interrupt fork' });
      const messages = await eventStore.getMessagesAt(forkResult.rootEvent.id);
      const sanitized = sanitizeMessages(messages);

      // All 3 thinking-only messages should be removed
      const thinkingOnlyFixes = sanitized.fixes.filter(
        f => f.type === 'removed_thinking_only_message'
      );
      expect(thinkingOnlyFixes.length).toBe(3);

      // Only the final assistant message with text should remain
      const assistantMessages = sanitized.messages.filter(m => m.role === 'assistant');
      expect(assistantMessages.length).toBe(1);
    });
  });

  describe('reconstruction pipeline', () => {
    it('should produce valid messages after reconstruction + sanitization', async () => {
      // This test ensures the full pipeline works:
      // event creation → fork → reconstruction → sanitization → API-ready messages

      const { session, rootEvent } = await eventStore.createSession({
        workspacePath: '/test/project',
        workingDirectory: '/test/project',
        model: 'claude-haiku-4-5-20251001',
      });

      // Create a realistic session with mixed content
      const events = [
        { type: 'message.user', content: 'Hello' },
        {
          type: 'message.assistant',
          content: [
            { type: 'thinking', thinking: 'Greeting...' },
            { type: 'text', text: 'Hi there!' },
          ],
        },
        { type: 'message.user', content: 'Read file.txt' },
        {
          type: 'message.assistant',
          content: [
            { type: 'thinking', thinking: 'Need to read file...' },
            { type: 'tool_use', id: 'toolu_01ABC', name: 'Read', arguments: { file_path: '/file.txt' } },
          ],
        },
        // Tool result would be here as tool.result event, handled by reconstructor
        {
          type: 'message.user', // Interrupted - user sent new message
          content: 'Actually, different file',
        },
        {
          type: 'message.assistant',
          content: [{ type: 'thinking', thinking: 'User changed mind...' }], // Interrupted
          interrupted: true,
        },
        { type: 'message.user', content: 'Read other.txt instead' },
        {
          type: 'message.assistant',
          content: [
            { type: 'thinking', thinking: 'Reading other file...' },
            { type: 'text', text: 'Here is the content of other.txt' },
          ],
        },
      ];

      let lastEventId = rootEvent.id;
      for (const evt of events) {
        const payload: Record<string, unknown> = {};
        if (evt.type === 'message.user') {
          payload.content = evt.content;
        } else {
          payload.content = evt.content;
          if ((evt as { interrupted?: boolean }).interrupted) {
            payload.interrupted = true;
            payload.stopReason = 'interrupted';
          }
        }

        const event = await eventStore.append({
          sessionId: session.id,
          type: evt.type as 'message.user' | 'message.assistant',
          payload,
          parentId: lastEventId,
        });
        lastEventId = event.id;
      }

      // Add tool.result event for the tool call
      const toolResultEvent = await eventStore.append({
        sessionId: session.id,
        type: 'tool.result',
        payload: {
          toolCallId: 'toolu_01ABC',
          content: '[Interrupted]',
          isError: false,
        },
        parentId: lastEventId,
      });

      // Fork and reconstruct
      const forkResult = await eventStore.fork(toolResultEvent.id, { name: 'Pipeline test' });
      const messages = await eventStore.getMessagesAt(forkResult.rootEvent.id);
      const sanitized = sanitizeMessages(messages);

      // Verify: No empty assistant messages
      for (const msg of sanitized.messages) {
        if (msg.role === 'assistant') {
          const content = (msg as { content: Array<{ type: string }> }).content;
          expect(content.length).toBeGreaterThan(0);

          // If it only has thinking, it must have a signature
          const nonThinkingBlocks = content.filter(b => b.type !== 'thinking');
          const thinkingBlocks = content.filter(b => b.type === 'thinking');

          if (nonThinkingBlocks.length === 0) {
            // All thinking - must have signatures
            for (const thinking of thinkingBlocks) {
              expect((thinking as { signature?: string }).signature).toBeDefined();
            }
          }
        }
      }

      // Verify: All tool_use blocks have corresponding results
      const toolUseIds = new Set<string>();
      const toolResultIds = new Set<string>();

      for (const msg of sanitized.messages) {
        if (msg.role === 'assistant') {
          for (const block of (msg as { content: Array<{ type: string; id?: string }> }).content) {
            if (block.type === 'tool_use' && block.id) {
              toolUseIds.add(block.id);
            }
          }
        }
        if (msg.role === 'toolResult') {
          toolResultIds.add((msg as { toolCallId: string }).toolCallId);
        }
      }

      for (const id of toolUseIds) {
        expect(toolResultIds.has(id)).toBe(true);
      }
    });
  });
});
