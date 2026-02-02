/**
 * @fileoverview Tests for InMemoryMessageBus
 */

import { describe, it, expect, beforeEach, vi } from 'vitest';
import { InMemoryMessageBus, createMessageBus } from '../message-bus.js';
import type { AgentMessage, MessageHandler } from '../types.js';

describe('InMemoryMessageBus', () => {
  let bus: InMemoryMessageBus;

  beforeEach(() => {
    bus = new InMemoryMessageBus({ currentSessionId: 'session-1' });
  });

  describe('send', () => {
    it('should send a message to a target session', async () => {
      const messageId = await bus.send('session-2', {
        type: 'test.message',
        payload: { data: 'hello' },
      });

      expect(messageId).toBeDefined();
      expect(typeof messageId).toBe('string');
    });

    it('should include sender session ID', async () => {
      await bus.send('session-2', {
        type: 'test.message',
        payload: {},
      });

      const messages = await bus.receive('session-2');
      expect(messages).toHaveLength(1);
      expect(messages[0].fromSessionId).toBe('session-1');
    });

    it('should set target session ID', async () => {
      await bus.send('session-2', {
        type: 'test.message',
        payload: {},
      });

      const messages = await bus.receive('session-2');
      expect(messages[0].toSessionId).toBe('session-2');
    });

    it('should generate unique IDs for each message', async () => {
      const id1 = await bus.send('session-2', { type: 'test', payload: {} });
      const id2 = await bus.send('session-2', { type: 'test', payload: {} });

      expect(id1).not.toBe(id2);
    });

    it('should set timestamp on message', async () => {
      const before = new Date().toISOString();
      await bus.send('session-2', { type: 'test', payload: {} });
      const after = new Date().toISOString();

      const messages = await bus.receive('session-2');
      expect(messages[0].timestamp >= before).toBe(true);
      expect(messages[0].timestamp <= after).toBe(true);
    });

    it('should include replyTo when provided', async () => {
      await bus.send('session-2', {
        type: 'test.reply',
        payload: {},
        replyTo: 'original-message-id',
      });

      const messages = await bus.receive('session-2');
      expect(messages[0].replyTo).toBe('original-message-id');
    });
  });

  describe('receive', () => {
    beforeEach(async () => {
      await bus.send('session-2', { type: 'task.created', payload: { id: 1 } });
      await bus.send('session-2', { type: 'task.updated', payload: { id: 2 } });
      await bus.send('session-3', { type: 'other.message', payload: { id: 3 } });
    });

    it('should return messages for the specified session', async () => {
      const messages = await bus.receive('session-2');
      expect(messages).toHaveLength(2);
    });

    it('should return empty array for session with no messages', async () => {
      const messages = await bus.receive('session-4');
      expect(messages).toHaveLength(0);
    });

    it('should filter by message type', async () => {
      const messages = await bus.receive('session-2', { type: 'task.created' });
      expect(messages).toHaveLength(1);
      expect(messages[0].type).toBe('task.created');
    });

    it('should filter by sender session', async () => {
      bus.setCurrentSessionId('session-other');
      await bus.send('session-2', { type: 'task.assigned', payload: {} });

      const messages = await bus.receive('session-2', { fromSessionId: 'session-1' });
      expect(messages).toHaveLength(2);
    });

    it('should filter unread only', async () => {
      const allMessages = await bus.receive('session-2');
      await bus.markAsRead([allMessages[0].id]);

      const unreadMessages = await bus.receive('session-2', { unreadOnly: true });
      expect(unreadMessages).toHaveLength(1);
    });

    it('should respect limit parameter', async () => {
      const messages = await bus.receive('session-2', undefined, 1);
      expect(messages).toHaveLength(1);
    });

    it('should return newest messages first', async () => {
      const messages = await bus.receive('session-2');
      // Messages should be sorted descending by timestamp
      expect(messages[0].timestamp >= messages[1].timestamp).toBe(true);
    });
  });

  describe('markAsRead', () => {
    it('should mark messages as read', async () => {
      await bus.send('session-2', { type: 'test', payload: {} });

      const before = await bus.receive('session-2', { unreadOnly: true });
      expect(before).toHaveLength(1);

      await bus.markAsRead([before[0].id]);

      const after = await bus.receive('session-2', { unreadOnly: true });
      expect(after).toHaveLength(0);
    });

    it('should handle non-existent message IDs gracefully', async () => {
      await expect(bus.markAsRead(['non-existent'])).resolves.not.toThrow();
    });
  });

  describe('getUnreadCount', () => {
    it('should return count of unread messages', async () => {
      await bus.send('session-2', { type: 'test', payload: {} });
      await bus.send('session-2', { type: 'test', payload: {} });

      const count = await bus.getUnreadCount('session-2');
      expect(count).toBe(2);
    });

    it('should return 0 for session with no messages', async () => {
      const count = await bus.getUnreadCount('session-empty');
      expect(count).toBe(0);
    });

    it('should not count read messages', async () => {
      await bus.send('session-2', { type: 'test', payload: {} });
      const messages = await bus.receive('session-2');
      await bus.markAsRead([messages[0].id]);

      const count = await bus.getUnreadCount('session-2');
      expect(count).toBe(0);
    });
  });

  describe('subscribe', () => {
    it('should call handler when matching message is sent', async () => {
      const handler = vi.fn();
      bus.subscribe('test.*', handler);

      await bus.send('session-2', { type: 'test.message', payload: { data: 'hello' } });

      expect(handler).toHaveBeenCalledTimes(1);
      expect(handler).toHaveBeenCalledWith(
        expect.objectContaining({
          type: 'test.message',
          payload: { data: 'hello' },
        })
      );
    });

    it('should not call handler for non-matching messages', async () => {
      const handler = vi.fn();
      bus.subscribe('task.*', handler);

      await bus.send('session-2', { type: 'test.message', payload: {} });

      expect(handler).not.toHaveBeenCalled();
    });

    it('should support wildcard pattern *', async () => {
      const handler = vi.fn();
      bus.subscribe('*', handler);

      await bus.send('session-2', { type: 'any.type', payload: {} });

      expect(handler).toHaveBeenCalledTimes(1);
    });

    it('should support prefix.* pattern', async () => {
      const handler = vi.fn();
      bus.subscribe('task.*', handler);

      await bus.send('session-2', { type: 'task.created', payload: {} });
      await bus.send('session-2', { type: 'task.updated', payload: {} });
      await bus.send('session-2', { type: 'other.event', payload: {} });

      expect(handler).toHaveBeenCalledTimes(2);
    });

    it('should return unsubscribe function', async () => {
      const handler = vi.fn();
      const unsubscribe = bus.subscribe('test.*', handler);

      await bus.send('session-2', { type: 'test.message', payload: {} });
      expect(handler).toHaveBeenCalledTimes(1);

      unsubscribe();

      await bus.send('session-2', { type: 'test.message', payload: {} });
      expect(handler).toHaveBeenCalledTimes(1); // Still 1, no new calls
    });

    it('should support multiple handlers for same pattern', async () => {
      const handler1 = vi.fn();
      const handler2 = vi.fn();

      bus.subscribe('test.*', handler1);
      bus.subscribe('test.*', handler2);

      await bus.send('session-2', { type: 'test.message', payload: {} });

      expect(handler1).toHaveBeenCalledTimes(1);
      expect(handler2).toHaveBeenCalledTimes(1);
    });

    it('should handle handler errors gracefully', async () => {
      const errorHandler = vi.fn().mockImplementation(() => {
        throw new Error('Handler error');
      });
      const normalHandler = vi.fn();

      bus.subscribe('test.*', errorHandler);
      bus.subscribe('test.*', normalHandler);

      // Should not throw
      await expect(
        bus.send('session-2', { type: 'test.message', payload: {} })
      ).resolves.toBeDefined();

      // Normal handler should still be called
      expect(normalHandler).toHaveBeenCalledTimes(1);
    });
  });

  describe('broadcast', () => {
    beforeEach(() => {
      // Create some sessions with messages
      bus.setCurrentSessionId('session-1');
    });

    it('should not broadcast to sender session', async () => {
      // First, create another session's message index
      bus.setCurrentSessionId('session-2');
      await bus.send('session-1', { type: 'setup', payload: {} });

      bus.setCurrentSessionId('session-1');
      await bus.broadcast({ type: 'broadcast.test', payload: {} });

      // Should not receive own broadcast
      const messages = await bus.receive('session-1', { type: 'broadcast.test' });
      expect(messages).toHaveLength(0);
    });

    it('should set toSessionId as undefined for broadcasts', async () => {
      const handler = vi.fn();
      bus.subscribe('broadcast.*', handler);

      await bus.broadcast({ type: 'broadcast.test', payload: {} });

      expect(handler).toHaveBeenCalledWith(
        expect.objectContaining({
          toSessionId: undefined,
        })
      );
    });
  });

  describe('cleanup', () => {
    it('should remove expired messages', async () => {
      vi.useFakeTimers();

      const shortRetentionBus = new InMemoryMessageBus({
        currentSessionId: 'session-1',
        retentionMs: 1000, // 1 second retention
      });

      await shortRetentionBus.send('session-2', { type: 'test', payload: {} });

      vi.advanceTimersByTime(1001);
      shortRetentionBus.cleanup();

      const messages = await shortRetentionBus.receive('session-2');
      expect(messages).toHaveLength(0);

      vi.useRealTimers();
    });
  });

  describe('session limit enforcement', () => {
    it('should enforce per-session message limit', async () => {
      const limitedBus = new InMemoryMessageBus({
        currentSessionId: 'session-1',
        maxMessagesPerSession: 3,
      });

      for (let i = 0; i < 5; i++) {
        await limitedBus.send('session-2', { type: 'test', payload: { index: i } });
      }

      const messages = await limitedBus.receive('session-2');
      expect(messages).toHaveLength(3);

      // Should keep the newest messages
      const indices = messages.map((m) => (m.payload as { index: number }).index);
      expect(indices).toContain(4);
      expect(indices).toContain(3);
      expect(indices).toContain(2);
    });
  });

  describe('factory function', () => {
    it('should create a message bus with createMessageBus', async () => {
      const factoryBus = createMessageBus({ currentSessionId: 'test-session' });
      const messageId = await factoryBus.send('other-session', {
        type: 'test',
        payload: {},
      });
      expect(messageId).toBeDefined();
    });
  });
});
