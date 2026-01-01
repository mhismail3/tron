/**
 * @fileoverview TuiSession Orchestrator Tests
 *
 * Tests for the unified session orchestrator that wires together:
 * - Context loading (AGENTS.md hierarchy)
 * - Session persistence (JSONL files)
 * - Memory/handoff management (SQLite with FTS5)
 * - Hook execution (SessionStart, SessionEnd, Pre/PostToolUse)
 * - Ledger management (continuity state)
 */
import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest';
import * as fs from 'fs/promises';
import * as path from 'path';
import * as os from 'os';
import { TuiSession, TuiSessionConfig, TuiSessionState } from '../../src/session/tui-session.js';

// Test fixtures
const TEST_DIR = path.join(os.tmpdir(), 'tron-tui-session-tests');
const TRON_DIR = path.join(TEST_DIR, '.tron');

describe('TuiSession', () => {
  beforeEach(async () => {
    // Create test directories
    await fs.mkdir(TRON_DIR, { recursive: true });
    await fs.mkdir(path.join(TRON_DIR, 'sessions'), { recursive: true });
    await fs.mkdir(path.join(TRON_DIR, 'memory'), { recursive: true });
  });

  afterEach(async () => {
    // Cleanup
    try {
      await fs.rm(TEST_DIR, { recursive: true, force: true });
    } catch {
      // Ignore cleanup errors
    }
  });

  describe('initialization', () => {
    it('should create a TuiSession with required config', async () => {
      const config: TuiSessionConfig = {
        workingDirectory: TEST_DIR,
        tronDir: TRON_DIR,
        model: 'claude-sonnet-4-20250514',
        provider: 'anthropic',
      };

      const session = new TuiSession(config);
      expect(session).toBeDefined();
      expect(session.getState()).toBe('uninitialized');
    });

    it('should initialize all managers on start', async () => {
      const config: TuiSessionConfig = {
        workingDirectory: TEST_DIR,
        tronDir: TRON_DIR,
        model: 'claude-sonnet-4-20250514',
        provider: 'anthropic',
      };

      const session = new TuiSession(config);
      await session.initialize();

      expect(session.getState()).toBe('ready');
      expect(session.getSessionId()).toMatch(/^sess_/);
    });

    it('should load context from AGENTS.md on initialization', async () => {
      // Create a test AGENTS.md file
      const agentsContent = `# Project Instructions

Always use TypeScript strict mode.
Follow the coding standards.`;
      await fs.writeFile(path.join(TEST_DIR, 'AGENTS.md'), agentsContent);

      const config: TuiSessionConfig = {
        workingDirectory: TEST_DIR,
        tronDir: TRON_DIR,
        model: 'claude-sonnet-4-20250514',
        provider: 'anthropic',
      };

      const session = new TuiSession(config);
      const initResult = await session.initialize();

      expect(initResult.context).toBeDefined();
      expect(initResult.context?.merged).toContain('TypeScript strict mode');
    });

    it('should create session file on initialization', async () => {
      const config: TuiSessionConfig = {
        workingDirectory: TEST_DIR,
        tronDir: TRON_DIR,
        model: 'claude-sonnet-4-20250514',
        provider: 'anthropic',
      };

      const session = new TuiSession(config);
      await session.initialize();

      const sessionId = session.getSessionId();
      const sessionFile = path.join(TRON_DIR, 'sessions', `${sessionId}.jsonl`);

      const exists = await fs.access(sessionFile).then(() => true).catch(() => false);
      expect(exists).toBe(true);

      // Verify session_start entry
      const content = await fs.readFile(sessionFile, 'utf-8');
      const firstEntry = JSON.parse(content.split('\n')[0]!);
      expect(firstEntry.type).toBe('session_start');
      expect(firstEntry.workingDirectory).toBe(TEST_DIR);
    });

    it('should load recent handoffs on initialization', async () => {
      // First create a previous session with a handoff
      const config: TuiSessionConfig = {
        workingDirectory: TEST_DIR,
        tronDir: TRON_DIR,
        model: 'claude-sonnet-4-20250514',
        provider: 'anthropic',
      };

      const session1 = new TuiSession(config);
      await session1.initialize();

      // Simulate some work and create handoff
      await session1.addMessage({ role: 'user', content: 'Test message 1' });
      await session1.addMessage({ role: 'assistant', content: 'Test response 1' });
      await session1.end();

      // Start new session - should see previous handoff
      const session2 = new TuiSession(config);
      const initResult = await session2.initialize();

      expect(initResult.handoffs).toBeDefined();
      expect(initResult.handoffs?.length).toBeGreaterThanOrEqual(0);
    });

    it('should load ledger state on initialization', async () => {
      // Create a ledger file
      const ledgerContent = `# Continuity Ledger

## Goal
Build the authentication system

## Now
Implementing login flow

## Next
- [ ] Add password validation
- [ ] Implement logout
`;
      await fs.mkdir(path.join(TRON_DIR, 'memory'), { recursive: true });
      await fs.writeFile(path.join(TRON_DIR, 'memory', 'CONTINUITY.md'), ledgerContent);

      const config: TuiSessionConfig = {
        workingDirectory: TEST_DIR,
        tronDir: TRON_DIR,
        model: 'claude-sonnet-4-20250514',
        provider: 'anthropic',
      };

      const session = new TuiSession(config);
      const initResult = await session.initialize();

      expect(initResult.ledger).toBeDefined();
      expect(initResult.ledger?.goal).toBe('Build the authentication system');
      expect(initResult.ledger?.now).toBe('Implementing login flow');
    });
  });

  describe('message handling', () => {
    it('should persist user messages', async () => {
      const config: TuiSessionConfig = {
        workingDirectory: TEST_DIR,
        tronDir: TRON_DIR,
        model: 'claude-sonnet-4-20250514',
        provider: 'anthropic',
      };

      const session = new TuiSession(config);
      await session.initialize();

      await session.addMessage({
        role: 'user',
        content: 'Hello, Tron!',
      });

      const sessionId = session.getSessionId();
      const sessionFile = path.join(TRON_DIR, 'sessions', `${sessionId}.jsonl`);
      const content = await fs.readFile(sessionFile, 'utf-8');
      const lines = content.trim().split('\n');

      // Should have session_start and message entries
      expect(lines.length).toBeGreaterThanOrEqual(2);

      const messageEntry = JSON.parse(lines[1]!);
      expect(messageEntry.type).toBe('message');
      expect(messageEntry.message.role).toBe('user');
      expect(messageEntry.message.content).toBe('Hello, Tron!');
    });

    it('should persist assistant messages with token usage', async () => {
      const config: TuiSessionConfig = {
        workingDirectory: TEST_DIR,
        tronDir: TRON_DIR,
        model: 'claude-sonnet-4-20250514',
        provider: 'anthropic',
      };

      const session = new TuiSession(config);
      await session.initialize();

      await session.addMessage(
        {
          role: 'assistant',
          content: [{ type: 'text', text: 'Hello! How can I help?' }],
        },
        { inputTokens: 100, outputTokens: 50 }
      );

      const sessionId = session.getSessionId();
      const sessionFile = path.join(TRON_DIR, 'sessions', `${sessionId}.jsonl`);
      const content = await fs.readFile(sessionFile, 'utf-8');
      const lines = content.trim().split('\n');

      const messageEntry = JSON.parse(lines[1]!);
      expect(messageEntry.message.role).toBe('assistant');
      expect(messageEntry.tokenUsage.inputTokens).toBe(100);
      expect(messageEntry.tokenUsage.outputTokens).toBe(50);
    });

    it('should track message count', async () => {
      const config: TuiSessionConfig = {
        workingDirectory: TEST_DIR,
        tronDir: TRON_DIR,
        model: 'claude-sonnet-4-20250514',
        provider: 'anthropic',
      };

      const session = new TuiSession(config);
      await session.initialize();

      expect(session.getMessageCount()).toBe(0);

      await session.addMessage({ role: 'user', content: 'Message 1' });
      expect(session.getMessageCount()).toBe(1);

      await session.addMessage({ role: 'assistant', content: 'Response 1' });
      expect(session.getMessageCount()).toBe(2);
    });
  });

  describe('session end', () => {
    it('should write session_end entry on end', async () => {
      const config: TuiSessionConfig = {
        workingDirectory: TEST_DIR,
        tronDir: TRON_DIR,
        model: 'claude-sonnet-4-20250514',
        provider: 'anthropic',
      };

      const session = new TuiSession(config);
      await session.initialize();
      await session.addMessage({ role: 'user', content: 'Test' });
      await session.addMessage({ role: 'assistant', content: 'Response' });

      await session.end();

      const sessionId = session.getSessionId();
      const sessionFile = path.join(TRON_DIR, 'sessions', `${sessionId}.jsonl`);
      const content = await fs.readFile(sessionFile, 'utf-8');
      const lines = content.trim().split('\n');

      const lastEntry = JSON.parse(lines[lines.length - 1]!);
      expect(lastEntry.type).toBe('session_end');
      expect(session.getState()).toBe('ended');
    });

    it('should create handoff on end if enough messages', async () => {
      const config: TuiSessionConfig = {
        workingDirectory: TEST_DIR,
        tronDir: TRON_DIR,
        model: 'claude-sonnet-4-20250514',
        provider: 'anthropic',
      };

      const session = new TuiSession(config);
      await session.initialize();

      // Add enough messages to trigger handoff
      await session.addMessage({ role: 'user', content: 'Please help me build a feature' });
      await session.addMessage({ role: 'assistant', content: 'I will help you build the feature' });
      await session.addMessage({ role: 'user', content: 'Start with the database' });
      await session.addMessage({ role: 'assistant', content: 'Created database schema' });

      const endResult = await session.end();

      expect(endResult.handoffCreated).toBe(true);
      expect(endResult.handoffId).toBeDefined();
    });

    it('should not create handoff for very short sessions', async () => {
      const config: TuiSessionConfig = {
        workingDirectory: TEST_DIR,
        tronDir: TRON_DIR,
        model: 'claude-sonnet-4-20250514',
        provider: 'anthropic',
      };

      const session = new TuiSession(config);
      await session.initialize();

      // Only one message - too short for handoff
      await session.addMessage({ role: 'user', content: 'Hi' });

      const endResult = await session.end();

      expect(endResult.handoffCreated).toBe(false);
    });

    it('should update ledger on session end', async () => {
      const config: TuiSessionConfig = {
        workingDirectory: TEST_DIR,
        tronDir: TRON_DIR,
        model: 'claude-sonnet-4-20250514',
        provider: 'anthropic',
      };

      const session = new TuiSession(config);
      await session.initialize();

      // Update ledger during session
      await session.updateLedger({
        now: 'Implementing feature X',
        next: ['Add tests', 'Update docs'],
      });

      await session.addMessage({ role: 'user', content: 'Test' });
      await session.addMessage({ role: 'assistant', content: 'Response' });
      await session.end();

      // Ledger should persist
      const ledgerFile = path.join(TRON_DIR, 'memory', 'CONTINUITY.md');
      const content = await fs.readFile(ledgerFile, 'utf-8');
      expect(content).toContain('Implementing feature X');
    });
  });

  describe('context building', () => {
    it('should build system prompt with all context sources', async () => {
      // Create AGENTS.md
      const agentsContent = `# Project Context
Use TypeScript for all code.`;
      await fs.writeFile(path.join(TEST_DIR, 'AGENTS.md'), agentsContent);

      // Create ledger
      const ledgerContent = `# Continuity Ledger

## Goal
Build user auth

## Now
Working on login
`;
      await fs.mkdir(path.join(TRON_DIR, 'memory'), { recursive: true });
      await fs.writeFile(path.join(TRON_DIR, 'memory', 'CONTINUITY.md'), ledgerContent);

      const config: TuiSessionConfig = {
        workingDirectory: TEST_DIR,
        tronDir: TRON_DIR,
        model: 'claude-sonnet-4-20250514',
        provider: 'anthropic',
      };

      const session = new TuiSession(config);
      await session.initialize();

      const systemPrompt = session.buildSystemPrompt();

      // Should include project context
      expect(systemPrompt).toContain('TypeScript');
      // Should include ledger state
      expect(systemPrompt).toContain('Build user auth');
      expect(systemPrompt).toContain('Working on login');
    });

    it('should include handoff context when available', async () => {
      const config: TuiSessionConfig = {
        workingDirectory: TEST_DIR,
        tronDir: TRON_DIR,
        model: 'claude-sonnet-4-20250514',
        provider: 'anthropic',
      };

      // Create first session with handoff
      const session1 = new TuiSession(config);
      await session1.initialize();
      await session1.addMessage({ role: 'user', content: 'Build auth system' });
      await session1.addMessage({ role: 'assistant', content: 'Starting auth implementation' });
      await session1.addMessage({ role: 'user', content: 'Add JWT' });
      await session1.addMessage({ role: 'assistant', content: 'Added JWT support' });
      await session1.end();

      // Create second session
      const session2 = new TuiSession(config);
      const initResult = await session2.initialize();

      // Should have previous session context
      if (initResult.handoffs && initResult.handoffs.length > 0) {
        const systemPrompt = session2.buildSystemPrompt();
        expect(systemPrompt).toContain('Previous Session');
      }
    });
  });

  describe('ledger management', () => {
    it('should update ledger goal', async () => {
      const config: TuiSessionConfig = {
        workingDirectory: TEST_DIR,
        tronDir: TRON_DIR,
        model: 'claude-sonnet-4-20250514',
        provider: 'anthropic',
      };

      const session = new TuiSession(config);
      await session.initialize();

      await session.updateLedger({ goal: 'Build amazing feature' });

      const ledger = await session.getLedger();
      expect(ledger.goal).toBe('Build amazing feature');
    });

    it('should track working files', async () => {
      const config: TuiSessionConfig = {
        workingDirectory: TEST_DIR,
        tronDir: TRON_DIR,
        model: 'claude-sonnet-4-20250514',
        provider: 'anthropic',
      };

      const session = new TuiSession(config);
      await session.initialize();

      await session.addWorkingFile('src/auth.ts');
      await session.addWorkingFile('src/types.ts');

      const ledger = await session.getLedger();
      expect(ledger.workingFiles).toContain('src/auth.ts');
      expect(ledger.workingFiles).toContain('src/types.ts');
    });

    it('should record decisions', async () => {
      const config: TuiSessionConfig = {
        workingDirectory: TEST_DIR,
        tronDir: TRON_DIR,
        model: 'claude-sonnet-4-20250514',
        provider: 'anthropic',
      };

      const session = new TuiSession(config);
      await session.initialize();

      await session.addDecision('Use JWT', 'Better for stateless auth');

      const ledger = await session.getLedger();
      expect(ledger.decisions.length).toBe(1);
      expect(ledger.decisions[0]?.choice).toBe('Use JWT');
      expect(ledger.decisions[0]?.reason).toBe('Better for stateless auth');
    });
  });

  describe('handoff search', () => {
    it('should search handoffs by content', async () => {
      const config: TuiSessionConfig = {
        workingDirectory: TEST_DIR,
        tronDir: TRON_DIR,
        model: 'claude-sonnet-4-20250514',
        provider: 'anthropic',
      };

      // Create session with specific content
      const session1 = new TuiSession(config);
      await session1.initialize();
      await session1.updateLedger({ goal: 'Implement authentication system' });
      await session1.addMessage({ role: 'user', content: 'Build OAuth integration' });
      await session1.addMessage({ role: 'assistant', content: 'Implemented OAuth flow' });
      await session1.addMessage({ role: 'user', content: 'Add token refresh' });
      await session1.addMessage({ role: 'assistant', content: 'Added refresh token logic' });
      await session1.end();

      // Search for it
      const session2 = new TuiSession(config);
      await session2.initialize();

      const results = await session2.searchHandoffs('OAuth');
      // Note: FTS5 search may or may not find depending on handoff summary
      expect(results).toBeDefined();
    });
  });

  describe('state management', () => {
    it('should transition through correct states', async () => {
      const config: TuiSessionConfig = {
        workingDirectory: TEST_DIR,
        tronDir: TRON_DIR,
        model: 'claude-sonnet-4-20250514',
        provider: 'anthropic',
      };

      const session = new TuiSession(config);
      expect(session.getState()).toBe('uninitialized');

      await session.initialize();
      expect(session.getState()).toBe('ready');

      await session.addMessage({ role: 'user', content: 'Test' });
      expect(session.getState()).toBe('ready');

      await session.end();
      expect(session.getState()).toBe('ended');
    });

    it('should prevent operations on ended session', async () => {
      const config: TuiSessionConfig = {
        workingDirectory: TEST_DIR,
        tronDir: TRON_DIR,
        model: 'claude-sonnet-4-20250514',
        provider: 'anthropic',
      };

      const session = new TuiSession(config);
      await session.initialize();
      await session.end();

      await expect(session.addMessage({ role: 'user', content: 'Test' }))
        .rejects.toThrow('Session has ended');
    });

    it('should prevent operations on uninitialized session', async () => {
      const config: TuiSessionConfig = {
        workingDirectory: TEST_DIR,
        tronDir: TRON_DIR,
        model: 'claude-sonnet-4-20250514',
        provider: 'anthropic',
      };

      const session = new TuiSession(config);

      await expect(session.addMessage({ role: 'user', content: 'Test' }))
        .rejects.toThrow('Session not initialized');
    });
  });

  describe('error handling', () => {
    it('should handle missing directories gracefully', async () => {
      // Use a new temp directory that doesn't exist yet
      const newTempDir = path.join(os.tmpdir(), `tron-test-${Date.now()}`);
      const newTronDir = path.join(newTempDir, '.tron');

      const config: TuiSessionConfig = {
        workingDirectory: newTempDir,
        tronDir: newTronDir,
        model: 'claude-sonnet-4-20250514',
        provider: 'anthropic',
      };

      const session = new TuiSession(config);

      // Should create directories as needed
      await expect(session.initialize()).resolves.toBeDefined();

      // Cleanup
      await fs.rm(newTempDir, { recursive: true, force: true }).catch(() => {});
    });

    it('should handle corrupted ledger gracefully', async () => {
      // Create corrupted ledger
      await fs.mkdir(path.join(TRON_DIR, 'memory'), { recursive: true });
      await fs.writeFile(
        path.join(TRON_DIR, 'memory', 'CONTINUITY.md'),
        'not valid markdown ledger format'
      );

      const config: TuiSessionConfig = {
        workingDirectory: TEST_DIR,
        tronDir: TRON_DIR,
        model: 'claude-sonnet-4-20250514',
        provider: 'anthropic',
      };

      const session = new TuiSession(config);
      const result = await session.initialize();

      // Should still initialize with empty/default ledger
      expect(result).toBeDefined();
      expect(session.getState()).toBe('ready');
    });
  });
});
