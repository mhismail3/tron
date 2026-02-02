/**
 * @fileoverview Message Queue Tests
 *
 * Tests for queuing user messages during streaming.
 */
import { describe, it, expect, beforeEach } from 'vitest';
import { MessageQueue } from '../message-queue.js';

describe('MessageQueue', () => {
  let queue: MessageQueue;

  beforeEach(() => {
    queue = new MessageQueue();
  });

  describe('initial state', () => {
    it('starts empty', () => {
      expect(queue.hasMessages()).toBe(false);
      expect(queue.size()).toBe(0);
    });
  });

  describe('add', () => {
    it('adds a message to the queue', () => {
      queue.add('hello');
      expect(queue.hasMessages()).toBe(true);
      expect(queue.size()).toBe(1);
    });

    it('adds multiple messages', () => {
      queue.add('first');
      queue.add('second');
      queue.add('third');
      expect(queue.size()).toBe(3);
    });

    it('ignores empty messages', () => {
      queue.add('');
      queue.add('   ');
      expect(queue.hasMessages()).toBe(false);
    });

    it('trims whitespace from messages', () => {
      queue.add('  hello  ');
      expect(queue.peek()).toBe('hello');
    });
  });

  describe('pop', () => {
    it('returns undefined when empty', () => {
      expect(queue.pop()).toBeUndefined();
    });

    it('returns messages in FIFO order', () => {
      queue.add('first');
      queue.add('second');
      queue.add('third');

      expect(queue.pop()).toBe('first');
      expect(queue.pop()).toBe('second');
      expect(queue.pop()).toBe('third');
      expect(queue.pop()).toBeUndefined();
    });
  });

  describe('peek', () => {
    it('returns undefined when empty', () => {
      expect(queue.peek()).toBeUndefined();
    });

    it('returns next message without removing it', () => {
      queue.add('test');
      expect(queue.peek()).toBe('test');
      expect(queue.peek()).toBe('test');
      expect(queue.hasMessages()).toBe(true);
    });
  });

  describe('clear', () => {
    it('removes all messages', () => {
      queue.add('one');
      queue.add('two');
      queue.clear();

      expect(queue.hasMessages()).toBe(false);
      expect(queue.size()).toBe(0);
    });
  });

  describe('getAll', () => {
    it('returns empty array when empty', () => {
      expect(queue.getAll()).toEqual([]);
    });

    it('returns all messages and clears queue', () => {
      queue.add('one');
      queue.add('two');
      queue.add('three');

      const messages = queue.getAll();

      expect(messages).toEqual(['one', 'two', 'three']);
      expect(queue.hasMessages()).toBe(false);
    });
  });
});
