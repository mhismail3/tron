/**
 * @fileoverview Tests for AgentEventEmitter
 */

import { describe, it, expect, vi, beforeEach } from 'vitest';
import { AgentEventEmitter, createEventEmitter } from '../../src/agent/event-emitter.js';
import type { TronEvent } from '../../src/types/index.js';

describe('AgentEventEmitter', () => {
  let emitter: AgentEventEmitter;

  beforeEach(() => {
    emitter = createEventEmitter();
  });

  describe('addListener', () => {
    it('should add a listener', () => {
      const listener = vi.fn();
      emitter.addListener(listener);
      expect(emitter.listenerCount()).toBe(1);
    });

    it('should allow multiple listeners', () => {
      emitter.addListener(vi.fn());
      emitter.addListener(vi.fn());
      emitter.addListener(vi.fn());
      expect(emitter.listenerCount()).toBe(3);
    });
  });

  describe('removeListener', () => {
    it('should remove a specific listener', () => {
      const listener1 = vi.fn();
      const listener2 = vi.fn();

      emitter.addListener(listener1);
      emitter.addListener(listener2);
      expect(emitter.listenerCount()).toBe(2);

      emitter.removeListener(listener1);
      expect(emitter.listenerCount()).toBe(1);
    });

    it('should not fail when removing non-existent listener', () => {
      const listener = vi.fn();
      emitter.removeListener(listener);
      expect(emitter.listenerCount()).toBe(0);
    });
  });

  describe('emit', () => {
    it('should call all listeners with the event', () => {
      const listener1 = vi.fn();
      const listener2 = vi.fn();

      emitter.addListener(listener1);
      emitter.addListener(listener2);

      const event: TronEvent = {
        type: 'turn_start',
        sessionId: 'sess_123',
        timestamp: new Date().toISOString(),
        turn: 1,
      };

      emitter.emit(event);

      expect(listener1).toHaveBeenCalledWith(event);
      expect(listener2).toHaveBeenCalledWith(event);
    });

    it('should call listeners in order of registration', () => {
      const order: number[] = [];

      emitter.addListener(() => order.push(1));
      emitter.addListener(() => order.push(2));
      emitter.addListener(() => order.push(3));

      emitter.emit({
        type: 'agent_start',
        sessionId: 'sess_123',
        timestamp: new Date().toISOString(),
      });

      expect(order).toEqual([1, 2, 3]);
    });

    it('should continue calling listeners when one throws', () => {
      const listener1 = vi.fn(() => {
        throw new Error('Listener 1 failed');
      });
      const listener2 = vi.fn();

      emitter.addListener(listener1);
      emitter.addListener(listener2);

      const event: TronEvent = {
        type: 'agent_start',
        sessionId: 'sess_123',
        timestamp: new Date().toISOString(),
      };

      // Should not throw
      emitter.emit(event);

      expect(listener1).toHaveBeenCalled();
      expect(listener2).toHaveBeenCalled();
    });

    it('should handle empty listener list', () => {
      const event: TronEvent = {
        type: 'agent_start',
        sessionId: 'sess_123',
        timestamp: new Date().toISOString(),
      };

      // Should not throw
      expect(() => emitter.emit(event)).not.toThrow();
    });
  });

  describe('removeAllListeners', () => {
    it('should remove all listeners', () => {
      emitter.addListener(vi.fn());
      emitter.addListener(vi.fn());
      emitter.addListener(vi.fn());

      expect(emitter.listenerCount()).toBe(3);

      emitter.removeAllListeners();

      expect(emitter.listenerCount()).toBe(0);
    });
  });

  describe('event types', () => {
    it('should emit turn_start events', () => {
      const listener = vi.fn();
      emitter.addListener(listener);

      emitter.emit({
        type: 'turn_start',
        sessionId: 'sess_123',
        timestamp: new Date().toISOString(),
        turn: 1,
      });

      expect(listener).toHaveBeenCalledWith(
        expect.objectContaining({ type: 'turn_start', turn: 1 })
      );
    });

    it('should emit turn_end events', () => {
      const listener = vi.fn();
      emitter.addListener(listener);

      emitter.emit({
        type: 'turn_end',
        sessionId: 'sess_123',
        timestamp: new Date().toISOString(),
        turn: 1,
        duration: 1500,
      });

      expect(listener).toHaveBeenCalledWith(
        expect.objectContaining({ type: 'turn_end', duration: 1500 })
      );
    });

    it('should emit tool_execution_start events', () => {
      const listener = vi.fn();
      emitter.addListener(listener);

      emitter.emit({
        type: 'tool_execution_start',
        sessionId: 'sess_123',
        timestamp: new Date().toISOString(),
        toolName: 'Read',
        toolCallId: 'call_123',
        arguments: { file_path: '/test.txt' },
      });

      expect(listener).toHaveBeenCalledWith(
        expect.objectContaining({
          type: 'tool_execution_start',
          toolName: 'Read',
        })
      );
    });

    it('should emit message_update events', () => {
      const listener = vi.fn();
      emitter.addListener(listener);

      emitter.emit({
        type: 'message_update',
        sessionId: 'sess_123',
        timestamp: new Date().toISOString(),
        content: 'Hello',
      });

      expect(listener).toHaveBeenCalledWith(
        expect.objectContaining({
          type: 'message_update',
          content: 'Hello',
        })
      );
    });

    it('should emit agent_interrupted events', () => {
      const listener = vi.fn();
      emitter.addListener(listener);

      emitter.emit({
        type: 'agent_interrupted',
        sessionId: 'sess_123',
        timestamp: new Date().toISOString(),
        turn: 3,
        partialContent: 'Partial response...',
        activeTool: 'Bash',
      });

      expect(listener).toHaveBeenCalledWith(
        expect.objectContaining({
          type: 'agent_interrupted',
          partialContent: 'Partial response...',
        })
      );
    });
  });
});

describe('createEventEmitter', () => {
  it('should create a new instance', () => {
    const emitter = createEventEmitter();
    expect(emitter).toBeInstanceOf(AgentEventEmitter);
  });

  it('should create independent instances', () => {
    const emitter1 = createEventEmitter();
    const emitter2 = createEventEmitter();

    emitter1.addListener(vi.fn());
    expect(emitter1.listenerCount()).toBe(1);
    expect(emitter2.listenerCount()).toBe(0);
  });
});
