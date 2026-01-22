/**
 * @fileoverview Tests for Provider Base Types
 */

import { describe, it, expect } from 'vitest';
import {
  startEvent,
  textStartEvent,
  textDeltaEvent,
  textEndEvent,
  toolCallStartEvent,
  toolCallDeltaEvent,
  doneEvent,
  errorEvent,
} from '../../../src/providers/base/types.js';

describe('Stream Event Helpers', () => {
  describe('startEvent', () => {
    it('should create a start event', () => {
      const event = startEvent();
      expect(event).toEqual({ type: 'start' });
    });
  });

  describe('textStartEvent', () => {
    it('should create a text_start event', () => {
      const event = textStartEvent();
      expect(event).toEqual({ type: 'text_start' });
    });
  });

  describe('textDeltaEvent', () => {
    it('should create a text_delta event', () => {
      const event = textDeltaEvent('Hello');
      expect(event).toEqual({ type: 'text_delta', delta: 'Hello' });
    });

    it('should handle empty delta', () => {
      const event = textDeltaEvent('');
      expect(event).toEqual({ type: 'text_delta', delta: '' });
    });
  });

  describe('textEndEvent', () => {
    it('should create a text_end event', () => {
      const event = textEndEvent('Hello World');
      expect(event).toEqual({ type: 'text_end', text: 'Hello World' });
    });
  });

  describe('toolCallStartEvent', () => {
    it('should create a toolcall_start event', () => {
      const event = toolCallStartEvent('call_123', 'readFile');
      expect(event).toEqual({
        type: 'toolcall_start',
        toolCallId: 'call_123',
        name: 'readFile',
      });
    });
  });

  describe('toolCallDeltaEvent', () => {
    it('should create a toolcall_delta event', () => {
      const event = toolCallDeltaEvent('call_123', '{"path":');
      expect(event).toEqual({
        type: 'toolcall_delta',
        toolCallId: 'call_123',
        argumentsDelta: '{"path":',
      });
    });
  });

  describe('doneEvent', () => {
    it('should create a done event', () => {
      const message = {
        role: 'assistant' as const,
        content: [{ type: 'text' as const, text: 'Hello' }],
      };
      const event = doneEvent(message, 'stop');
      expect(event).toEqual({
        type: 'done',
        message,
        stopReason: 'stop',
      });
    });
  });

  describe('errorEvent', () => {
    it('should create an error event', () => {
      const error = new Error('Test error');
      const event = errorEvent(error);
      expect(event).toEqual({ type: 'error', error });
    });
  });
});
