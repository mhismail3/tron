/**
 * @fileoverview Tests for HookContextFactory
 *
 * Tests the factory functions for creating hook contexts with
 * consistent base fields (sessionId, timestamp, data).
 */

import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest';
import {
  createHookContextFactory,
  type HookContextFactoryOptions,
} from '../context-factory.js';
import type { TronToolResult } from '@core/types/index.js';

describe('HookContextFactory', () => {
  const mockNow = new Date('2026-02-01T12:00:00.000Z');

  beforeEach(() => {
    vi.useFakeTimers();
    vi.setSystemTime(mockNow);
  });

  afterEach(() => {
    vi.useRealTimers();
  });

  describe('createHookContextFactory', () => {
    it('creates factory with required options', () => {
      const factory = createHookContextFactory({
        sessionId: 'sess_123',
      });

      expect(factory).toBeDefined();
      expect(typeof factory.createPreToolContext).toBe('function');
      expect(typeof factory.createPostToolContext).toBe('function');
    });
  });

  describe('createPreToolContext', () => {
    it('creates PreToolHookContext with base fields', () => {
      const factory = createHookContextFactory({
        sessionId: 'sess_123',
      });

      const context = factory.createPreToolContext({
        toolName: 'Bash',
        toolArguments: { command: 'ls -la' },
        toolCallId: 'tool_abc',
      });

      expect(context.hookType).toBe('PreToolUse');
      expect(context.sessionId).toBe('sess_123');
      expect(context.timestamp).toBe('2026-02-01T12:00:00.000Z');
      expect(context.data).toEqual({});
      expect(context.toolName).toBe('Bash');
      expect(context.toolArguments).toEqual({ command: 'ls -la' });
      expect(context.toolCallId).toBe('tool_abc');
    });

    it('allows custom data to be provided', () => {
      const factory = createHookContextFactory({
        sessionId: 'sess_123',
      });

      const context = factory.createPreToolContext({
        toolName: 'Read',
        toolArguments: { path: '/file.txt' },
        toolCallId: 'tool_def',
        data: { customKey: 'customValue' },
      });

      expect(context.data).toEqual({ customKey: 'customValue' });
    });
  });

  describe('createPostToolContext', () => {
    it('creates PostToolHookContext with result and duration', () => {
      const factory = createHookContextFactory({
        sessionId: 'sess_456',
      });

      const result: TronToolResult = {
        content: 'File contents',
        isError: false,
      };

      const context = factory.createPostToolContext({
        toolName: 'Read',
        toolCallId: 'tool_xyz',
        result,
        duration: 150,
      });

      expect(context.hookType).toBe('PostToolUse');
      expect(context.sessionId).toBe('sess_456');
      expect(context.timestamp).toBe('2026-02-01T12:00:00.000Z');
      expect(context.data).toEqual({});
      expect(context.toolName).toBe('Read');
      expect(context.toolCallId).toBe('tool_xyz');
      expect(context.result).toBe(result);
      expect(context.duration).toBe(150);
    });
  });

  describe('createStopContext', () => {
    it('creates StopHookContext', () => {
      const factory = createHookContextFactory({
        sessionId: 'sess_789',
      });

      const context = factory.createStopContext({
        stopReason: 'completed',
        finalMessage: 'Task finished',
      });

      expect(context.hookType).toBe('Stop');
      expect(context.sessionId).toBe('sess_789');
      expect(context.timestamp).toBe('2026-02-01T12:00:00.000Z');
      expect(context.stopReason).toBe('completed');
      expect(context.finalMessage).toBe('Task finished');
    });
  });

  describe('createSessionStartContext', () => {
    it('creates SessionStartHookContext', () => {
      const factory = createHookContextFactory({
        sessionId: 'sess_new',
      });

      const context = factory.createSessionStartContext({
        workingDirectory: '/path/to/project',
      });

      expect(context.hookType).toBe('SessionStart');
      expect(context.sessionId).toBe('sess_new');
      expect(context.workingDirectory).toBe('/path/to/project');
    });
  });

  describe('timestamp handling', () => {
    it('uses current time for each context creation', () => {
      const factory = createHookContextFactory({
        sessionId: 'sess_time',
      });

      const context1 = factory.createPreToolContext({
        toolName: 'A',
        toolArguments: {},
        toolCallId: 'a',
      });

      // Advance time
      vi.advanceTimersByTime(5000);

      const context2 = factory.createPreToolContext({
        toolName: 'B',
        toolArguments: {},
        toolCallId: 'b',
      });

      expect(context1.timestamp).toBe('2026-02-01T12:00:00.000Z');
      expect(context2.timestamp).toBe('2026-02-01T12:00:05.000Z');
    });
  });
});
