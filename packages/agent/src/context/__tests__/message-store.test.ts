/**
 * @fileoverview Tests for MessageStore
 *
 * MessageStore handles message storage and token caching for context management.
 */

import { describe, it, expect, beforeEach } from 'vitest';
import { MessageStore, createMessageStore } from '../message-store.js';
import type { Message } from '../../types/index.js';

describe('MessageStore', () => {
  let store: MessageStore;

  beforeEach(() => {
    store = createMessageStore();
  });

  describe('add', () => {
    it('should add a message and cache its token count', () => {
      const message: Message = {
        role: 'user',
        content: 'Hello, world!',
      };

      store.add(message);

      expect(store.get()).toHaveLength(1);
      expect(store.get()[0]).toEqual(message);
      expect(store.length).toBe(1);
    });

    it('should add multiple messages in order', () => {
      const msg1: Message = { role: 'user', content: 'First' };
      const msg2: Message = {
        role: 'assistant',
        content: [{ type: 'text', text: 'Second' }],
      };
      const msg3: Message = { role: 'user', content: 'Third' };

      store.add(msg1);
      store.add(msg2);
      store.add(msg3);

      const messages = store.get();
      expect(messages).toHaveLength(3);
      expect(messages[0]).toEqual(msg1);
      expect(messages[1]).toEqual(msg2);
      expect(messages[2]).toEqual(msg3);
    });

    it('should cache token estimates for added messages', () => {
      const message: Message = {
        role: 'user',
        content: 'This is a test message with some content',
      };

      store.add(message);

      const cachedTokens = store.getCachedTokens(message);
      expect(cachedTokens).toBeGreaterThan(0);
      expect(cachedTokens).toBeDefined();
    });
  });

  describe('set', () => {
    it('should replace all messages', () => {
      store.add({ role: 'user', content: 'Original' });

      const newMessages: Message[] = [
        { role: 'user', content: 'New message 1' },
        { role: 'assistant', content: [{ type: 'text', text: 'New message 2' }] },
      ];

      store.set(newMessages);

      expect(store.get()).toHaveLength(2);
      expect(store.get()[0].content).toBe('New message 1');
    });

    it('should rebuild token cache for new messages', () => {
      const messages: Message[] = [
        { role: 'user', content: 'First message' },
        { role: 'assistant', content: [{ type: 'text', text: 'Second message' }] },
      ];

      store.set(messages);

      expect(store.getCachedTokens(messages[0])).toBeGreaterThan(0);
      expect(store.getCachedTokens(messages[1])).toBeGreaterThan(0);
    });

    it('should create defensive copy of messages', () => {
      const messages: Message[] = [{ role: 'user', content: 'Test' }];
      store.set(messages);

      messages.push({ role: 'user', content: 'Added after' });

      expect(store.get()).toHaveLength(1);
    });
  });

  describe('get', () => {
    it('should return empty array when no messages', () => {
      expect(store.get()).toEqual([]);
    });

    it('should return defensive copy of messages', () => {
      store.add({ role: 'user', content: 'Test' });

      const messages1 = store.get();
      const messages2 = store.get();

      expect(messages1).not.toBe(messages2);
      expect(messages1).toEqual(messages2);
    });

    it('should not allow external modification of internal state', () => {
      store.add({ role: 'user', content: 'Original' });

      const messages = store.get();
      messages.push({ role: 'user', content: 'Injected' });

      expect(store.get()).toHaveLength(1);
    });
  });

  describe('clear', () => {
    it('should remove all messages', () => {
      store.add({ role: 'user', content: 'Message 1' });
      store.add({ role: 'user', content: 'Message 2' });

      store.clear();

      expect(store.get()).toEqual([]);
      expect(store.length).toBe(0);
    });
  });

  describe('getTokens', () => {
    it('should return 0 for empty store', () => {
      expect(store.getTokens()).toBe(0);
    });

    it('should return sum of all message tokens', () => {
      store.add({ role: 'user', content: 'First message' });
      store.add({ role: 'assistant', content: [{ type: 'text', text: 'Second message' }] });

      const totalTokens = store.getTokens();
      expect(totalTokens).toBeGreaterThan(0);
    });

    it('should use cached values for efficiency', () => {
      const message: Message = { role: 'user', content: 'Test message' };
      store.add(message);

      const tokens1 = store.getTokens();
      const tokens2 = store.getTokens();

      expect(tokens1).toBe(tokens2);
    });
  });

  describe('getCachedTokens', () => {
    it('should return undefined for unknown message', () => {
      const unknownMessage: Message = { role: 'user', content: 'Unknown' };
      expect(store.getCachedTokens(unknownMessage)).toBeUndefined();
    });

    it('should return cached tokens for added message', () => {
      const message: Message = { role: 'user', content: 'Test' };
      store.add(message);

      const cached = store.getCachedTokens(message);
      expect(cached).toBeDefined();
      expect(cached).toBeGreaterThan(0);
    });
  });

  describe('length', () => {
    it('should return 0 for empty store', () => {
      expect(store.length).toBe(0);
    });

    it('should return correct count after adds', () => {
      store.add({ role: 'user', content: 'One' });
      expect(store.length).toBe(1);

      store.add({ role: 'user', content: 'Two' });
      expect(store.length).toBe(2);
    });

    it('should return 0 after clear', () => {
      store.add({ role: 'user', content: 'Test' });
      store.clear();
      expect(store.length).toBe(0);
    });
  });

  describe('factory function', () => {
    it('should create MessageStore with initial messages', () => {
      const initialMessages: Message[] = [
        { role: 'user', content: 'Initial message' },
      ];

      const storeWithMessages = createMessageStore({ initialMessages });

      expect(storeWithMessages.get()).toHaveLength(1);
      expect(storeWithMessages.getCachedTokens(initialMessages[0])).toBeGreaterThan(0);
    });

    it('should create empty MessageStore without config', () => {
      const emptyStore = createMessageStore();
      expect(emptyStore.get()).toEqual([]);
    });
  });
});
