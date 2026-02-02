/**
 * @fileoverview Tests for EventFactory
 *
 * Tests the factory functions for creating properly structured events
 * with consistent ID generation and timestamp handling.
 */

import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest';
import {
  createEventFactory,
  type EventFactoryOptions,
} from '../event-factory.js';
import { SessionId, WorkspaceId, EventId } from '../types.js';

describe('EventFactory', () => {
  const mockNow = new Date('2026-02-01T12:00:00.000Z');

  beforeEach(() => {
    vi.useFakeTimers();
    vi.setSystemTime(mockNow);
  });

  afterEach(() => {
    vi.useRealTimers();
  });

  describe('createEventFactory', () => {
    it('creates factory with required options', () => {
      const options: EventFactoryOptions = {
        sessionId: SessionId('sess_123'),
        workspaceId: WorkspaceId('ws_456'),
      };
      const factory = createEventFactory(options);

      expect(factory).toBeDefined();
      expect(typeof factory.createSessionStart).toBe('function');
      expect(typeof factory.createSessionFork).toBe('function');
      expect(typeof factory.createEvent).toBe('function');
    });
  });

  describe('createSessionStart', () => {
    it('creates session start event with all required fields', () => {
      const factory = createEventFactory({
        sessionId: SessionId('sess_123'),
        workspaceId: WorkspaceId('ws_456'),
      });

      const event = factory.createSessionStart({
        workingDirectory: '/path/to/project',
        model: 'claude-3-opus',
      });

      expect(event.type).toBe('session.start');
      expect(event.sessionId).toBe('sess_123');
      expect(event.workspaceId).toBe('ws_456');
      expect(event.timestamp).toBe('2026-02-01T12:00:00.000Z');
      expect(event.sequence).toBe(0);
      expect(event.parentId).toBeNull();
      expect(event.id).toMatch(/^evt_/);
      expect(event.payload.workingDirectory).toBe('/path/to/project');
      expect(event.payload.model).toBe('claude-3-opus');
    });

    it('includes optional fields when provided', () => {
      const factory = createEventFactory({
        sessionId: SessionId('sess_123'),
        workspaceId: WorkspaceId('ws_456'),
      });

      const event = factory.createSessionStart({
        workingDirectory: '/path/to/project',
        model: 'claude-3-opus',
        provider: 'anthropic',
        title: 'Test Session',
        systemPrompt: 'You are helpful',
      });

      expect(event.payload.provider).toBe('anthropic');
      expect(event.payload.title).toBe('Test Session');
      expect(event.payload.systemPrompt).toBe('You are helpful');
    });
  });

  describe('createSessionFork', () => {
    it('creates session fork event with source references', () => {
      const factory = createEventFactory({
        sessionId: SessionId('sess_new'),
        workspaceId: WorkspaceId('ws_456'),
      });

      const event = factory.createSessionFork({
        parentId: EventId('evt_parent'),
        sourceSessionId: SessionId('sess_original'),
        sourceEventId: EventId('evt_fork_point'),
      });

      expect(event.type).toBe('session.fork');
      expect(event.sessionId).toBe('sess_new');
      expect(event.parentId).toBe('evt_parent');
      expect(event.sequence).toBe(0);
      expect(event.payload.sourceSessionId).toBe('sess_original');
      expect(event.payload.sourceEventId).toBe('evt_fork_point');
    });

    it('includes optional name and reason', () => {
      const factory = createEventFactory({
        sessionId: SessionId('sess_new'),
        workspaceId: WorkspaceId('ws_456'),
      });

      const event = factory.createSessionFork({
        parentId: EventId('evt_parent'),
        sourceSessionId: SessionId('sess_original'),
        sourceEventId: EventId('evt_fork_point'),
        name: 'Branch A',
        reason: 'Testing alternative approach',
      });

      expect(event.payload.name).toBe('Branch A');
      expect(event.payload.reason).toBe('Testing alternative approach');
    });
  });

  describe('createEvent', () => {
    it('creates generic event with specified type', () => {
      const factory = createEventFactory({
        sessionId: SessionId('sess_123'),
        workspaceId: WorkspaceId('ws_456'),
      });

      const event = factory.createEvent({
        type: 'message.user',
        parentId: EventId('evt_parent'),
        sequence: 5,
        payload: { content: 'Hello' },
      });

      expect(event.type).toBe('message.user');
      expect(event.sessionId).toBe('sess_123');
      expect(event.workspaceId).toBe('ws_456');
      expect(event.parentId).toBe('evt_parent');
      expect(event.sequence).toBe(5);
      expect(event.payload).toEqual({ content: 'Hello' });
      expect(event.timestamp).toBe('2026-02-01T12:00:00.000Z');
    });

    it('generates unique IDs for each event', () => {
      const factory = createEventFactory({
        sessionId: SessionId('sess_123'),
        workspaceId: WorkspaceId('ws_456'),
      });

      const event1 = factory.createEvent({
        type: 'message.user',
        parentId: EventId('evt_parent'),
        sequence: 1,
        payload: { content: 'First' },
      });

      const event2 = factory.createEvent({
        type: 'message.user',
        parentId: EventId('evt_parent'),
        sequence: 2,
        payload: { content: 'Second' },
      });

      expect(event1.id).not.toBe(event2.id);
    });
  });

  describe('generateEventId', () => {
    it('generates IDs with evt_ prefix', () => {
      const factory = createEventFactory({
        sessionId: SessionId('sess_123'),
        workspaceId: WorkspaceId('ws_456'),
      });

      const id = factory.generateEventId();

      expect(id).toMatch(/^evt_[a-f0-9]{12}$/);
    });
  });
});
