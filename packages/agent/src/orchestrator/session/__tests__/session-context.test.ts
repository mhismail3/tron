/**
 * @fileoverview SessionContext Unit Tests
 *
 * Tests for the SessionContext class which encapsulates per-session state
 * using the extracted modules (EventPersister, TurnManager, PlanModeHandler).
 *
 * Contract:
 * 1. Manage session lifecycle (create, activate, deactivate)
 * 2. Coordinate event persistence through EventPersister
 * 3. Manage turn lifecycle through TurnManager
 * 4. Track plan mode through PlanModeHandler
 * 5. Provide clean interface for orchestrator operations
 */
import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest';
import { EventStore, type SessionId, type EventId } from '../../../events/event-store.js';
import path from 'path';
import os from 'os';
import fs from 'fs';
import {
  SessionContext,
  createSessionContext,
  type SessionContextConfig,
} from '../session-context.js';

describe('SessionContext', () => {
  let eventStore: EventStore;
  let testDir: string;
  let sessionId: SessionId;
  let initialHeadEventId: EventId;

  beforeEach(async () => {
    // Create temp directory and EventStore
    testDir = fs.mkdtempSync(path.join(os.tmpdir(), 'tron-session-context-test-'));
    const dbPath = path.join(testDir, 'events.db');
    eventStore = new EventStore(dbPath);
    await eventStore.initialize();

    // Create a session to get initial head event ID
    const result = await eventStore.createSession({
      workspacePath: '/test/project',
      workingDirectory: '/test/project',
      model: 'claude-sonnet-4-20250514',
    });
    sessionId = result.session.id;
    initialHeadEventId = result.rootEvent.id;
  });

  afterEach(async () => {
    await eventStore.close();
    fs.rmSync(testDir, { recursive: true, force: true });
  });

  describe('Creation', () => {
    it('should create session context with required config', () => {
      const context = createSessionContext({
        sessionId,
        eventStore,
        initialHeadEventId,
        model: 'claude-sonnet-4-20250514',
        workingDirectory: '/test/project',
      });

      expect(context.getSessionId()).toBe(sessionId);
      expect(context.getModel()).toBe('claude-sonnet-4-20250514');
      expect(context.isProcessing()).toBe(false);
    });

    it('should initialize with inactive plan mode', () => {
      const context = createSessionContext({
        sessionId,
        eventStore,
        initialHeadEventId,
        model: 'claude-sonnet-4-20250514',
        workingDirectory: '/test/project',
      });

      expect(context.isInPlanMode()).toBe(false);
      expect(context.getBlockedTools()).toEqual([]);
    });

    it('should initialize with turn 0', () => {
      const context = createSessionContext({
        sessionId,
        eventStore,
        initialHeadEventId,
        model: 'claude-sonnet-4-20250514',
        workingDirectory: '/test/project',
      });

      expect(context.getCurrentTurn()).toBe(0);
    });
  });

  describe('Event persistence', () => {
    it('should append events through persister', async () => {
      const context = createSessionContext({
        sessionId,
        eventStore,
        initialHeadEventId,
        model: 'claude-sonnet-4-20250514',
        workingDirectory: '/test/project',
      });

      const event = await context.appendEvent('message.user', {
        content: 'Hello world',
      });

      expect(event).not.toBeNull();
      expect(event!.type).toBe('message.user');
      expect(context.getPendingHeadEventId()).toBe(event!.id);
    });

    it('should chain events correctly', async () => {
      const context = createSessionContext({
        sessionId,
        eventStore,
        initialHeadEventId,
        model: 'claude-sonnet-4-20250514',
        workingDirectory: '/test/project',
      });

      const event1 = await context.appendEvent('message.user', { content: 'First' });
      const event2 = await context.appendEvent('message.assistant', {
        content: [{ type: 'text', text: 'Second' }],
      });

      expect(event1!.parentId).toBe(initialHeadEventId);
      expect(event2!.parentId).toBe(event1!.id);
    });

    it('should flush pending events', async () => {
      const context = createSessionContext({
        sessionId,
        eventStore,
        initialHeadEventId,
        model: 'claude-sonnet-4-20250514',
        workingDirectory: '/test/project',
      });

      // Fire and forget
      context.appendEventFireAndForget('stream.turn_start', { turn: 1 });
      context.appendEventFireAndForget('stream.turn_end', { turn: 1 });

      // Flush should wait for all
      await context.flushEvents();

      // Verify events were persisted
      const ancestors = await eventStore.getAncestors(context.getPendingHeadEventId()!);
      expect(ancestors.length).toBe(3); // session.start + 2 events
    });
  });

  describe('Turn management', () => {
    it('should track turn lifecycle', () => {
      const context = createSessionContext({
        sessionId,
        eventStore,
        initialHeadEventId,
        model: 'claude-sonnet-4-20250514',
        workingDirectory: '/test/project',
      });

      context.startTurn(1);
      expect(context.getCurrentTurn()).toBe(1);

      context.addTextDelta('Hello');
      context.addTextDelta(' world');
      context.setResponseTokenUsage({ inputTokens: 100, outputTokens: 50 });

      const result = context.endTurn();

      expect(result.turn).toBe(1);
      expect(result.content.length).toBe(1);
      expect(result.content[0]).toMatchObject({ type: 'text', text: 'Hello world' });
    });

    it('should track tool calls', () => {
      const context = createSessionContext({
        sessionId,
        eventStore,
        initialHeadEventId,
        model: 'claude-sonnet-4-20250514',
        workingDirectory: '/test/project',
      });

      context.startTurn(1);
      context.addTextDelta('Reading file');
      context.startToolCall('tc_1', 'Read', { file_path: '/test.ts' });
      context.endToolCall('tc_1', 'file contents', false);

      const result = context.endTurn();

      expect(result.content.length).toBe(2);
      expect(result.content[0]).toMatchObject({ type: 'text' });
      expect(result.content[1]).toMatchObject({ type: 'tool_use', id: 'tc_1' });
      expect(result.toolResults.length).toBe(1);
    });

    it('should provide accumulated content for catch-up', () => {
      const context = createSessionContext({
        sessionId,
        eventStore,
        initialHeadEventId,
        model: 'claude-sonnet-4-20250514',
        workingDirectory: '/test/project',
      });

      context.startTurn(1);
      context.addTextDelta('Turn 1 content');
      context.endTurn();

      context.startTurn(2);
      context.addTextDelta('Turn 2 content');

      const accumulated = context.getAccumulatedContent();
      expect(accumulated.text).toContain('Turn 1');
      expect(accumulated.text).toContain('Turn 2');
    });
  });

  describe('Plan mode', () => {
    it('should enter and exit plan mode', () => {
      const context = createSessionContext({
        sessionId,
        eventStore,
        initialHeadEventId,
        model: 'claude-sonnet-4-20250514',
        workingDirectory: '/test/project',
      });

      context.enterPlanMode('test-skill', ['Edit', 'Write', 'Bash']);

      expect(context.isInPlanMode()).toBe(true);
      expect(context.getBlockedTools()).toEqual(['Edit', 'Write', 'Bash']);
      expect(context.isToolBlocked('Edit')).toBe(true);
      expect(context.isToolBlocked('Read')).toBe(false);

      context.exitPlanMode();

      expect(context.isInPlanMode()).toBe(false);
      expect(context.isToolBlocked('Edit')).toBe(false);
    });
  });

  describe('Interrupt handling', () => {
    it('should build interrupted content', () => {
      const context = createSessionContext({
        sessionId,
        eventStore,
        initialHeadEventId,
        model: 'claude-sonnet-4-20250514',
        workingDirectory: '/test/project',
      });

      context.startTurn(1);
      context.addTextDelta('Working on it...');
      context.startToolCall('tc_1', 'Bash', { command: 'long-running' });
      // Tool not ended - simulates interruption

      const interrupted = context.buildInterruptedContent();

      expect(interrupted.assistantContent.length).toBe(2);
      expect(interrupted.assistantContent[0]).toMatchObject({ type: 'text' });
      expect(interrupted.assistantContent[1]).toMatchObject({
        type: 'tool_use',
        _meta: { interrupted: true },
      });
    });
  });

  describe('Processing state', () => {
    it('should track processing state', () => {
      const context = createSessionContext({
        sessionId,
        eventStore,
        initialHeadEventId,
        model: 'claude-sonnet-4-20250514',
        workingDirectory: '/test/project',
      });

      expect(context.isProcessing()).toBe(false);

      context.setProcessing(true);
      expect(context.isProcessing()).toBe(true);

      context.setProcessing(false);
      expect(context.isProcessing()).toBe(false);
    });
  });

  describe('Agent lifecycle', () => {
    it('should clear state on agent start', () => {
      const context = createSessionContext({
        sessionId,
        eventStore,
        initialHeadEventId,
        model: 'claude-sonnet-4-20250514',
        workingDirectory: '/test/project',
      });

      // Build up some state
      context.startTurn(1);
      context.addTextDelta('Some content');
      context.endTurn();

      // Start new agent run
      context.onAgentStart();

      expect(context.getCurrentTurn()).toBe(0);
      expect(context.hasAccumulatedContent()).toBe(false);
    });

    it('should clear state on agent end', () => {
      const context = createSessionContext({
        sessionId,
        eventStore,
        initialHeadEventId,
        model: 'claude-sonnet-4-20250514',
        workingDirectory: '/test/project',
      });

      context.startTurn(1);
      context.addTextDelta('Content');
      context.endTurn();

      context.onAgentEnd();

      expect(context.hasAccumulatedContent()).toBe(false);
    });
  });

  describe('State reconstruction', () => {
    it('should restore state from events', async () => {
      // Create context and add some events
      const context1 = createSessionContext({
        sessionId,
        eventStore,
        initialHeadEventId,
        model: 'claude-sonnet-4-20250514',
        workingDirectory: '/test/project',
      });

      // Enter plan mode and persist event
      context1.enterPlanMode('my-plan', ['Edit']);
      await context1.appendEvent('plan.mode_entered', {
        skillName: 'my-plan',
        blockedTools: ['Edit'],
      });

      // Create a new context and restore state
      const events = await eventStore.getAncestors(context1.getPendingHeadEventId()!);

      const context2 = createSessionContext({
        sessionId,
        eventStore,
        initialHeadEventId: context1.getPendingHeadEventId()!,
        model: 'claude-sonnet-4-20250514',
        workingDirectory: '/test/project',
      });

      context2.restoreFromEvents(events);

      expect(context2.isInPlanMode()).toBe(true);
      expect(context2.getBlockedTools()).toEqual(['Edit']);
    });
  });

  describe('Thinking support', () => {
    it('should accumulate thinking deltas through turn manager', () => {
      const context = createSessionContext({
        sessionId,
        eventStore,
        initialHeadEventId,
        model: 'claude-sonnet-4-20250514',
        workingDirectory: '/test/project',
      });

      context.startTurn(1);
      context.addThinkingDelta('Let me ');
      context.addThinkingDelta('analyze this...');
      context.addTextDelta('Here is my response');
      context.setResponseTokenUsage({ inputTokens: 100, outputTokens: 50 });

      const result = context.endTurn();

      // Thinking should come first
      expect(result.content.length).toBe(2);
      expect(result.content[0]).toMatchObject({
        type: 'thinking',
        thinking: 'Let me analyze this...',
      });
      expect(result.content[1]).toMatchObject({
        type: 'text',
        text: 'Here is my response',
      });
    });

    it('should include thinking in interrupted content', () => {
      const context = createSessionContext({
        sessionId,
        eventStore,
        initialHeadEventId,
        model: 'claude-sonnet-4-20250514',
        workingDirectory: '/test/project',
      });

      context.startTurn(1);
      context.addThinkingDelta('Deep analysis in progress');
      context.addTextDelta('Working on it...');
      context.startToolCall('tc_1', 'Bash', { command: 'long-running' });
      // Tool not ended - simulates interruption

      const interrupted = context.buildInterruptedContent();

      // Thinking should be first
      expect(interrupted.assistantContent.length).toBeGreaterThan(0);
      expect(interrupted.assistantContent[0]).toMatchObject({
        type: 'thinking',
        thinking: 'Deep analysis in progress',
      });
    });

    it('should preserve thinking with tool calls', () => {
      const context = createSessionContext({
        sessionId,
        eventStore,
        initialHeadEventId,
        model: 'claude-sonnet-4-20250514',
        workingDirectory: '/test/project',
      });

      context.startTurn(1);
      context.addThinkingDelta('I need to read the file first');
      context.addTextDelta('Let me check the file');
      context.startToolCall('tc_1', 'Read', { file_path: '/test.ts' });
      context.endToolCall('tc_1', 'file contents', false);

      const result = context.endTurn();

      // Order: thinking, text, tool_use
      expect(result.content.length).toBe(3);
      expect(result.content[0].type).toBe('thinking');
      expect(result.content[1].type).toBe('text');
      expect(result.content[2].type).toBe('tool_use');
      expect(result.toolResults.length).toBe(1);
    });

    it('should include thinking in accumulated content', () => {
      const context = createSessionContext({
        sessionId,
        eventStore,
        initialHeadEventId,
        model: 'claude-sonnet-4-20250514',
        workingDirectory: '/test/project',
      });

      context.startTurn(1);
      context.addThinkingDelta('Turn 1 thinking');
      context.addTextDelta('Turn 1 response');
      context.endTurn();

      context.startTurn(2);
      context.addThinkingDelta('Turn 2 thinking');
      context.addTextDelta('Turn 2 response');

      const accumulated = context.getAccumulatedContent();
      expect(accumulated.thinking).toContain('Turn 1 thinking');
      expect(accumulated.thinking).toContain('Turn 2 thinking');
    });

    it('should clear thinking on agent lifecycle', () => {
      const context = createSessionContext({
        sessionId,
        eventStore,
        initialHeadEventId,
        model: 'claude-sonnet-4-20250514',
        workingDirectory: '/test/project',
      });

      // Build up state
      context.startTurn(1);
      context.addThinkingDelta('Some thinking');
      context.addTextDelta('Some text');
      context.endTurn();

      // Start new agent run
      context.onAgentStart();

      expect(context.getCurrentTurn()).toBe(0);
      expect(context.hasAccumulatedContent()).toBe(false);
    });
  });
});
