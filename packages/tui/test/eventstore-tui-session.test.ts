/**
 * @fileoverview TUI EventStore Integration Tests
 *
 * These tests verify the EventStoreTuiSession class integrates correctly
 * with the EventStore for session management. The TUI uses direct database
 * access (local-first) since it runs on the same machine.
 *
 * Test-Driven Development: These tests are written FIRST to define
 * the expected behavior before implementation.
 */
import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest';
import * as path from 'path';
import * as os from 'os';
import * as fs from 'fs';
import {
  EventStore,
  type SessionId,
  type EventId,
  type EventMessage,
  type EventSessionState,
  type TronSessionEvent,
} from '@tron/agent';

// Import the class we'll create
import { EventStoreTuiSession, type EventStoreTuiSessionConfig } from '../src/session/eventstore-tui-session.js';

// Test utilities
function createTempDir(): string {
  const tmpDir = path.join(os.tmpdir(), `tron-tui-test-${Date.now()}-${Math.random().toString(36).slice(2)}`);
  fs.mkdirSync(tmpDir, { recursive: true });
  return tmpDir;
}

function cleanupTempDir(dir: string): void {
  try {
    fs.rmSync(dir, { recursive: true, force: true });
  } catch {
    // Ignore cleanup errors
  }
}

describe('EventStoreTuiSession', () => {
  let tempDir: string;
  let eventStore: EventStore;
  let config: EventStoreTuiSessionConfig;

  beforeEach(async () => {
    tempDir = createTempDir();

    // Create EventStore with in-memory database for tests
    eventStore = new EventStore(':memory:');
    await eventStore.initialize();

    config = {
      workingDirectory: tempDir,
      tronDir: path.join(tempDir, '.tron'),
      model: 'claude-sonnet-4-20250514',
      provider: 'anthropic',
      eventStore,
    };
  });

  afterEach(async () => {
    await eventStore.close();
    cleanupTempDir(tempDir);
  });

  // ===========================================================================
  // Initialization Tests
  // ===========================================================================

  describe('initialization', () => {
    it('should create a new session with EventStore', async () => {
      const tuiSession = new EventStoreTuiSession(config);
      const result = await tuiSession.initialize();

      expect(result.sessionId).toBeDefined();
      expect(result.sessionId).toMatch(/^sess_/);
      expect(result.systemPrompt).toBeDefined();
    });

    it('should create workspace if not exists', async () => {
      const tuiSession = new EventStoreTuiSession(config);
      await tuiSession.initialize();

      const sessionId = tuiSession.getSessionId();
      const session = await eventStore.getSession(sessionId);

      expect(session).toBeDefined();
      expect(session?.workingDirectory).toBe(tempDir);
    });

    it('should create root session.start event', async () => {
      const tuiSession = new EventStoreTuiSession(config);
      await tuiSession.initialize();

      const sessionId = tuiSession.getSessionId();
      const events = await eventStore.getEventsBySession(sessionId);

      expect(events.length).toBeGreaterThanOrEqual(1);
      expect(events[0].type).toBe('session.start');
      expect(events[0].payload).toMatchObject({
        model: 'claude-sonnet-4-20250514',
        provider: 'anthropic',
        workingDirectory: tempDir,
      });
    });

    it('should record session metadata in start event', async () => {
      const tuiSession = new EventStoreTuiSession(config);
      await tuiSession.initialize();

      const sessionId = tuiSession.getSessionId();
      const events = await eventStore.getEventsBySession(sessionId);
      const startEvent = events.find(e => e.type === 'session.start');

      expect(startEvent?.payload).toMatchObject({
        clientType: 'tui',
        version: expect.any(String),
      });
    });

    it('should resume existing session by ID', async () => {
      // Create first session
      const tuiSession1 = new EventStoreTuiSession(config);
      const result1 = await tuiSession1.initialize();
      await tuiSession1.addMessage({ role: 'user', content: 'Hello' });

      // Resume same session
      const tuiSession2 = new EventStoreTuiSession({
        ...config,
        sessionId: result1.sessionId,
      });
      const result2 = await tuiSession2.initialize();

      expect(result2.sessionId).toBe(result1.sessionId);
      const messages = await tuiSession2.getMessages();
      expect(messages.length).toBe(1);
      expect(messages[0].content).toBe('Hello');
    });

    it('should load context from AGENTS.md/CLAUDE.md files', async () => {
      // Create context file
      const agentsFile = path.join(tempDir, 'AGENTS.md');
      fs.writeFileSync(agentsFile, '# Test Agent Context\nThis is test context.');

      const tuiSession = new EventStoreTuiSession(config);
      const result = await tuiSession.initialize();

      // Rules content is now accessed via getRulesContent() for agent.setRulesContent()
      // The systemPrompt is deprecated for rules (now returns empty)
      const rulesContent = tuiSession.getRulesContent();
      expect(rulesContent).toContain('Test Agent Context');
      // Also verify it's in the context.merged field
      expect(result.context?.merged).toContain('Test Agent Context');
    });
  });

  // ===========================================================================
  // Message Recording Tests
  // ===========================================================================

  describe('message recording', () => {
    it('should record user message as event', async () => {
      const tuiSession = new EventStoreTuiSession(config);
      await tuiSession.initialize();

      await tuiSession.addMessage({ role: 'user', content: 'Hello, assistant!' });

      const sessionId = tuiSession.getSessionId();
      const events = await eventStore.getEventsBySession(sessionId);
      const userEvent = events.find(e => e.type === 'message.user');

      expect(userEvent).toBeDefined();
      expect(userEvent?.payload).toMatchObject({
        content: 'Hello, assistant!',
      });
    });

    it('should record assistant message as event', async () => {
      const tuiSession = new EventStoreTuiSession(config);
      await tuiSession.initialize();

      await tuiSession.addMessage({
        role: 'assistant',
        content: [{ type: 'text', text: 'Hello, human!' }],
      });

      const sessionId = tuiSession.getSessionId();
      const events = await eventStore.getEventsBySession(sessionId);
      const assistantEvent = events.find(e => e.type === 'message.assistant');

      expect(assistantEvent).toBeDefined();
      expect(assistantEvent?.payload.content).toEqual([{ type: 'text', text: 'Hello, human!' }]);
    });

    it('should track token usage in events', async () => {
      const tuiSession = new EventStoreTuiSession(config);
      await tuiSession.initialize();

      await tuiSession.addMessage(
        { role: 'assistant', content: [{ type: 'text', text: 'Response' }] },
        { inputTokens: 100, outputTokens: 50 }
      );

      const sessionId = tuiSession.getSessionId();
      const events = await eventStore.getEventsBySession(sessionId);
      const assistantEvent = events.find(e => e.type === 'message.assistant');

      // Token usage is stored in payload.tokenUsage
      expect(assistantEvent?.payload.tokenUsage).toEqual({
        inputTokens: 100,
        outputTokens: 50,
      });
    });

    it('should maintain event chain via parentId', async () => {
      const tuiSession = new EventStoreTuiSession(config);
      await tuiSession.initialize();

      await tuiSession.addMessage({ role: 'user', content: 'First message' });
      await tuiSession.addMessage({ role: 'assistant', content: [{ type: 'text', text: 'Response' }] });
      await tuiSession.addMessage({ role: 'user', content: 'Second message' });

      const sessionId = tuiSession.getSessionId();
      const events = await eventStore.getEventsBySession(sessionId);

      // Each event should have parentId pointing to previous
      for (let i = 1; i < events.length; i++) {
        expect(events[i].parentId).toBe(events[i - 1].id);
      }
    });

    it('should update session head after each message', async () => {
      const tuiSession = new EventStoreTuiSession(config);
      await tuiSession.initialize();

      await tuiSession.addMessage({ role: 'user', content: 'Message 1' });

      const sessionId = tuiSession.getSessionId();
      const session1 = await eventStore.getSession(sessionId);
      const head1 = session1?.headEventId;

      await tuiSession.addMessage({ role: 'user', content: 'Message 2' });

      const session2 = await eventStore.getSession(sessionId);
      const head2 = session2?.headEventId;

      expect(head2).not.toBe(head1);
    });

    it('should skip persistence in ephemeral mode but track in memory', async () => {
      const ephemeralConfig: EventStoreTuiSessionConfig = {
        ...config,
        ephemeral: true,
      };

      const tuiSession = new EventStoreTuiSession(ephemeralConfig);
      await tuiSession.initialize();

      await tuiSession.addMessage({ role: 'user', content: 'Ephemeral message' });

      // Should still be able to get messages in memory
      const messages = await tuiSession.getMessages();
      expect(messages.length).toBe(1);

      // But EventStore should have no message events (only session.start)
      const sessionId = tuiSession.getSessionId();
      const events = await eventStore.getEventsBySession(sessionId);
      const messageEvents = events.filter(e => e.type === 'message.user' || e.type === 'message.assistant');
      expect(messageEvents.length).toBe(0);
    });
  });

  // ===========================================================================
  // Tool Recording Tests
  // ===========================================================================

  describe('tool recording', () => {
    it('should record tool call as event', async () => {
      const tuiSession = new EventStoreTuiSession(config);
      await tuiSession.initialize();

      await tuiSession.recordToolCall({
        toolCallId: 'call_123',
        toolName: 'read',
        arguments: { file_path: '/test/file.ts' },
      });

      const sessionId = tuiSession.getSessionId();
      const events = await eventStore.getEventsBySession(sessionId);
      const toolCallEvent = events.find(e => e.type === 'tool.call');

      expect(toolCallEvent).toBeDefined();
      expect(toolCallEvent?.payload).toMatchObject({
        toolCallId: 'call_123',
        toolName: 'read',
        arguments: { file_path: '/test/file.ts' },
      });
    });

    it('should record tool result as event', async () => {
      const tuiSession = new EventStoreTuiSession(config);
      await tuiSession.initialize();

      await tuiSession.recordToolCall({
        toolCallId: 'call_123',
        toolName: 'read',
        arguments: { file_path: '/test/file.ts' },
      });

      await tuiSession.recordToolResult({
        toolCallId: 'call_123',
        result: 'File contents here',
        isError: false,
      });

      const sessionId = tuiSession.getSessionId();
      const events = await eventStore.getEventsBySession(sessionId);
      const toolResultEvent = events.find(e => e.type === 'tool.result');

      expect(toolResultEvent).toBeDefined();
      expect(toolResultEvent?.payload).toMatchObject({
        toolCallId: 'call_123',
        result: 'File contents here',
        isError: false,
      });
    });

    it('should record tool errors', async () => {
      const tuiSession = new EventStoreTuiSession(config);
      await tuiSession.initialize();

      await tuiSession.recordToolCall({
        toolCallId: 'call_456',
        toolName: 'bash',
        arguments: { command: 'invalid-command' },
      });

      await tuiSession.recordToolResult({
        toolCallId: 'call_456',
        result: 'Command not found',
        isError: true,
      });

      const sessionId = tuiSession.getSessionId();
      const events = await eventStore.getEventsBySession(sessionId);
      const toolResultEvent = events.find(e => e.type === 'tool.result');

      expect(toolResultEvent?.payload.isError).toBe(true);
    });
  });

  // ===========================================================================
  // State Reconstruction Tests
  // ===========================================================================

  describe('state reconstruction', () => {
    it('should get messages from event chain', async () => {
      const tuiSession = new EventStoreTuiSession(config);
      await tuiSession.initialize();

      await tuiSession.addMessage({ role: 'user', content: 'Hello' });
      await tuiSession.addMessage({ role: 'assistant', content: [{ type: 'text', text: 'Hi!' }] });
      await tuiSession.addMessage({ role: 'user', content: 'How are you?' });

      const messages = await tuiSession.getMessages();

      expect(messages.length).toBe(3);
      expect(messages[0].role).toBe('user');
      expect(messages[0].content).toBe('Hello');
      expect(messages[1].role).toBe('assistant');
      expect(messages[2].content).toBe('How are you?');
    });

    it('should get full session state', async () => {
      const tuiSession = new EventStoreTuiSession(config);
      await tuiSession.initialize();

      await tuiSession.addMessage({ role: 'user', content: 'Test' }, { inputTokens: 10, outputTokens: 0 });
      await tuiSession.addMessage(
        { role: 'assistant', content: [{ type: 'text', text: 'Response' }] },
        { inputTokens: 0, outputTokens: 20 }
      );

      const state = await tuiSession.getSessionState();

      expect(state.messages.length).toBe(2);
      expect(state.tokenUsage.inputTokens).toBe(10);
      expect(state.tokenUsage.outputTokens).toBe(20);
    });

    it('should get state at specific event (point-in-time)', async () => {
      const tuiSession = new EventStoreTuiSession(config);
      await tuiSession.initialize();

      await tuiSession.addMessage({ role: 'user', content: 'Message 1' });

      // Get the event ID after first message
      const sessionId = tuiSession.getSessionId();
      const events = await eventStore.getEventsBySession(sessionId);
      const afterFirstMessage = events[events.length - 1].id;

      await tuiSession.addMessage({ role: 'user', content: 'Message 2' });
      await tuiSession.addMessage({ role: 'user', content: 'Message 3' });

      // Get state at earlier point
      const stateAtPoint = await tuiSession.getStateAt(afterFirstMessage);
      expect(stateAtPoint.messages.length).toBe(1);
      expect(stateAtPoint.messages[0].content).toBe('Message 1');
    });

    it('should get token usage totals', async () => {
      const tuiSession = new EventStoreTuiSession(config);
      await tuiSession.initialize();

      await tuiSession.addMessage({ role: 'user', content: 'Test' }, { inputTokens: 100, outputTokens: 0 });
      await tuiSession.addMessage(
        { role: 'assistant', content: [{ type: 'text', text: 'Response' }] },
        { inputTokens: 50, outputTokens: 75 }
      );

      const usage = tuiSession.getTokenUsage();
      expect(usage.inputTokens).toBe(150);
      expect(usage.outputTokens).toBe(75);
    });
  });

  // ===========================================================================
  // Fork Tests
  // ===========================================================================

  describe('fork operations', () => {
    it('should fork session from current head', async () => {
      const tuiSession = new EventStoreTuiSession(config);
      await tuiSession.initialize();

      await tuiSession.addMessage({ role: 'user', content: 'Original message' });
      await tuiSession.addMessage({ role: 'assistant', content: [{ type: 'text', text: 'Original response' }] });

      const forkResult = await tuiSession.fork();

      expect(forkResult.newSessionId).toBeDefined();
      expect(forkResult.newSessionId).not.toBe(tuiSession.getSessionId());
      expect(forkResult.forkedFromSessionId).toBe(tuiSession.getSessionId());
    });

    it('should fork session from specific event', async () => {
      const tuiSession = new EventStoreTuiSession(config);
      await tuiSession.initialize();

      await tuiSession.addMessage({ role: 'user', content: 'Message 1' });

      // Get event ID after first message
      const sessionId = tuiSession.getSessionId();
      const events = await eventStore.getEventsBySession(sessionId);
      const forkPoint = events[events.length - 1].id;

      await tuiSession.addMessage({ role: 'user', content: 'Message 2' });
      await tuiSession.addMessage({ role: 'user', content: 'Message 3' });

      const forkResult = await tuiSession.fork({ fromEventId: forkPoint });

      expect(forkResult.forkedFromEventId).toBe(forkPoint);

      // Load forked session and check messages
      const forkedSession = new EventStoreTuiSession({
        ...config,
        sessionId: forkResult.newSessionId,
      });
      await forkedSession.initialize();
      const messages = await forkedSession.getMessages();

      // Should only have 1 message (fork point was after first message)
      expect(messages.length).toBe(1);
      expect(messages[0].content).toBe('Message 1');
    });

    it('should allow divergent paths after fork', async () => {
      const tuiSession = new EventStoreTuiSession(config);
      await tuiSession.initialize();

      await tuiSession.addMessage({ role: 'user', content: 'Common base' });
      await tuiSession.addMessage({ role: 'assistant', content: [{ type: 'text', text: 'Acknowledged' }] });

      const forkResult = await tuiSession.fork();

      // Add different messages to each session (with proper alternation)
      await tuiSession.addMessage({ role: 'user', content: 'Original path' });

      const forkedSession = new EventStoreTuiSession({
        ...config,
        sessionId: forkResult.newSessionId,
      });
      await forkedSession.initialize();
      await forkedSession.addMessage({ role: 'user', content: 'Forked path' });

      // Check they diverged
      const originalMessages = await tuiSession.getMessages();
      const forkedMessages = await forkedSession.getMessages();

      // Both sessions have: Common base, Acknowledged, then divergent paths
      expect(originalMessages[2].content).toBe('Original path');
      expect(forkedMessages[2].content).toBe('Forked path');
    });
  });

  // ===========================================================================
  // Compaction Tests
  // ===========================================================================

  describe('compaction', () => {
    it('should detect when compaction is needed', async () => {
      const tuiSession = new EventStoreTuiSession({
        ...config,
        compactionMaxTokens: 1000,
        compactionThreshold: 0.8,
      });
      await tuiSession.initialize();

      // Add messages that exceed threshold
      for (let i = 0; i < 20; i++) {
        await tuiSession.addMessage(
          { role: 'user', content: 'A'.repeat(100) },
          { inputTokens: 50, outputTokens: 0 }
        );
        await tuiSession.addMessage(
          { role: 'assistant', content: [{ type: 'text', text: 'B'.repeat(100) }] },
          { inputTokens: 0, outputTokens: 50 }
        );
      }

      expect(tuiSession.needsCompaction()).toBe(true);
    });

    it('should record compaction boundary event', async () => {
      const tuiSession = new EventStoreTuiSession({
        ...config,
        compactionMaxTokens: 200,  // Lower threshold for easier triggering
        compactionThreshold: 0.5,  // Trigger at 100 tokens
        compactionTargetTokens: 50,
      });
      await tuiSession.initialize();

      // Add messages with longer content to trigger compaction
      // Each message pair needs ~50 chars to reach 100 token threshold quickly
      const longQuestion = 'This is a longer question that will consume more tokens for testing purposes. ';
      const longAnswer = 'This is a comprehensive answer with enough content to help trigger compaction. ';

      for (let i = 0; i < 10; i++) {
        await tuiSession.addMessage(
          { role: 'user', content: longQuestion + i },
          { inputTokens: 30, outputTokens: 0 }
        );
        await tuiSession.addMessage(
          { role: 'assistant', content: [{ type: 'text', text: longAnswer + i }] },
          { inputTokens: 0, outputTokens: 30 }
        );
      }

      if (tuiSession.needsCompaction()) {
        await tuiSession.compact();
      }

      const sessionId = tuiSession.getSessionId();
      const events = await eventStore.getEventsBySession(sessionId);
      const compactEvents = events.filter(e =>
        e.type === 'compact.boundary' || e.type === 'compact.summary'
      );

      expect(compactEvents.length).toBeGreaterThan(0);
    });

    it('should include summary in compaction event', async () => {
      const tuiSession = new EventStoreTuiSession({
        ...config,
        compactionMaxTokens: 300,
        compactionThreshold: 0.5,
        compactionTargetTokens: 100,
      });
      await tuiSession.initialize();

      // Add messages
      for (let i = 0; i < 5; i++) {
        await tuiSession.addMessage(
          { role: 'user', content: `Working on task ${i}` },
          { inputTokens: 50, outputTokens: 0 }
        );
        await tuiSession.addMessage(
          { role: 'assistant', content: [{ type: 'text', text: `Completed task ${i}` }] },
          { inputTokens: 0, outputTokens: 50 }
        );
      }

      if (tuiSession.needsCompaction()) {
        await tuiSession.compact();

        const sessionId = tuiSession.getSessionId();
        const events = await eventStore.getEventsBySession(sessionId);
        const summaryEvent = events.find(e => e.type === 'compact.summary');

        expect(summaryEvent?.payload.summary).toBeDefined();
        expect(typeof summaryEvent?.payload.summary).toBe('string');
      }
    });
  });

  // ===========================================================================
  // Session End Tests
  // ===========================================================================

  describe('session end', () => {
    it('should return session info on end', async () => {
      const tuiSession = new EventStoreTuiSession(config);
      await tuiSession.initialize();

      await tuiSession.addMessage({ role: 'user', content: 'Work done' });

      const endResult = await tuiSession.end();

      expect(endResult.sessionId).toBe(tuiSession.getSessionId());
    });

    it('should set handoffCreated when enough messages', async () => {
      const tuiSession = new EventStoreTuiSession({
        ...config,
        minMessagesForHandoff: 2,
      });
      await tuiSession.initialize();

      await tuiSession.addMessage({ role: 'user', content: 'First message' });
      await tuiSession.addMessage({ role: 'assistant', content: [{ type: 'text', text: 'Response' }] });
      await tuiSession.addMessage({ role: 'user', content: 'Second message' });

      const endResult = await tuiSession.end();

      expect(endResult.handoffCreated).toBe(true);
    });

    it('should not allow operations after end', async () => {
      const tuiSession = new EventStoreTuiSession(config);
      await tuiSession.initialize();

      await tuiSession.end();

      await expect(tuiSession.addMessage({ role: 'user', content: 'After end' }))
        .rejects.toThrow(/session.*ended/i);
    });
  });

  // ===========================================================================
  // Search Tests
  // ===========================================================================

  describe('search', () => {
    it('should search messages in session', async () => {
      const tuiSession = new EventStoreTuiSession(config);
      await tuiSession.initialize();

      await tuiSession.addMessage({ role: 'user', content: 'How do I implement authentication?' });
      await tuiSession.addMessage({ role: 'assistant', content: [{ type: 'text', text: 'Use JWT tokens for authentication' }] });
      await tuiSession.addMessage({ role: 'user', content: 'What about database setup?' });

      const results = await tuiSession.searchMessages('authentication');

      expect(results.length).toBeGreaterThan(0);
      expect(results.some(r => r.content.toLowerCase().includes('authentication'))).toBe(true);
    });

    it('should search across all sessions in workspace', async () => {
      // Create first session
      const tuiSession1 = new EventStoreTuiSession(config);
      await tuiSession1.initialize();
      await tuiSession1.addMessage({ role: 'user', content: 'Working on feature X' });
      await tuiSession1.end();

      // Create second session
      const tuiSession2 = new EventStoreTuiSession(config);
      await tuiSession2.initialize();
      await tuiSession2.addMessage({ role: 'user', content: 'Still working on feature X' });

      const results = await tuiSession2.searchWorkspace('feature X');

      // Should find results from both sessions
      expect(results.length).toBeGreaterThan(0);
    });
  });

  // ===========================================================================
  // Event History Tests
  // ===========================================================================

  describe('event history', () => {
    it('should get recent events', async () => {
      const tuiSession = new EventStoreTuiSession(config);
      await tuiSession.initialize();

      await tuiSession.addMessage({ role: 'user', content: 'Test' });

      const events = await tuiSession.getRecentEvents(5);

      expect(events.length).toBeGreaterThanOrEqual(2); // start + message
      expect(events.some(e => e.type === 'session.start')).toBe(true);
      expect(events.some(e => e.type === 'message.user')).toBe(true);
    });

    it('should get ancestors (full history to root)', async () => {
      const tuiSession = new EventStoreTuiSession(config);
      await tuiSession.initialize();

      await tuiSession.addMessage({ role: 'user', content: 'Msg 1' });
      await tuiSession.addMessage({ role: 'user', content: 'Msg 2' });
      await tuiSession.addMessage({ role: 'user', content: 'Msg 3' });

      const ancestors = await tuiSession.getAncestors();

      // Should include all events from root to head
      expect(ancestors[0].type).toBe('session.start'); // Root
      expect(ancestors[ancestors.length - 1].type).toBe('message.user'); // Head
    });

    it('should get tree visualization data', async () => {
      const tuiSession = new EventStoreTuiSession(config);
      await tuiSession.initialize();

      await tuiSession.addMessage({ role: 'user', content: 'Base' });
      await tuiSession.fork();
      await tuiSession.addMessage({ role: 'user', content: 'Original path' });

      const tree = await tuiSession.getTreeVisualization();

      expect(tree.root).toBeDefined();
      expect(tree.root.id).toBeDefined();
      expect(tree.branchPoints.length).toBeGreaterThan(0);
    });
  });

  // ===========================================================================
  // Context Audit Tests
  // ===========================================================================

  describe('context audit', () => {
    it('should record context sources in audit', async () => {
      // Create context file
      const agentsFile = path.join(tempDir, 'AGENTS.md');
      fs.writeFileSync(agentsFile, '# Test Context');

      const tuiSession = new EventStoreTuiSession(config);
      const result = await tuiSession.initialize();

      expect(result.audit.contextFiles.length).toBeGreaterThan(0);
      expect(result.audit.contextFiles.some(f => f.path.includes('AGENTS.md'))).toBe(true);
    });

    it('should record handoffs used in context', async () => {
      // This would require setting up handoffs in eventstore
      // For now, test that the audit structure is correct
      const tuiSession = new EventStoreTuiSession(config);
      const result = await tuiSession.initialize();

      // ContextAuditData has 'handoffs' property (not 'handoffsUsed')
      expect(result.audit).toHaveProperty('handoffs');
      expect(Array.isArray(result.audit.handoffs)).toBe(true);
    });
  });
});
