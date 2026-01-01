/**
 * @fileoverview Tests for HandoffManager
 */
import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import { HandoffManager, type Handoff, type CodeChange } from '../../src/memory/handoff-manager.js';

describe('HandoffManager', () => {
  let manager: HandoffManager;

  beforeEach(async () => {
    // Use in-memory database for tests
    manager = new HandoffManager(':memory:');
    await manager.initialize();
  });

  afterEach(async () => {
    await manager.close();
  });

  describe('initialization', () => {
    it('should initialize with in-memory database', async () => {
      const count = await manager.count();
      expect(count).toBe(0);
    });

    it('should be idempotent on multiple initialize calls', async () => {
      await manager.initialize();
      await manager.initialize();
      const count = await manager.count();
      expect(count).toBe(0);
    });
  });

  describe('create', () => {
    it('should create a handoff with all fields', async () => {
      const id = await manager.create({
        sessionId: 'test-session',
        timestamp: new Date(),
        summary: 'Implemented OAuth flow',
        codeChanges: [
          { file: 'src/auth/oauth.ts', description: 'Added PKCE flow' },
        ],
        currentState: 'OAuth working, need to integrate with streaming',
        blockers: [],
        nextSteps: ['Wire OAuth into provider', 'Test refresh'],
        patterns: ['Use 5-minute buffer for token expiry'],
      });

      expect(id).toBeTruthy();
      expect(id).toMatch(/^handoff_/);
    });

    it('should create handoff with empty arrays', async () => {
      const id = await manager.create({
        sessionId: 's1',
        timestamp: new Date(),
        summary: 'Simple session',
        codeChanges: [],
        currentState: 'Done',
        blockers: [],
        nextSteps: [],
        patterns: [],
      });

      expect(id).toBeTruthy();

      const handoff = await manager.get(id);
      expect(handoff).not.toBeNull();
      expect(handoff?.codeChanges).toEqual([]);
      expect(handoff?.blockers).toEqual([]);
    });

    it('should store metadata', async () => {
      const id = await manager.create({
        sessionId: 's1',
        timestamp: new Date(),
        summary: 'Session with metadata',
        codeChanges: [],
        currentState: 'Done',
        blockers: [],
        nextSteps: [],
        patterns: [],
        metadata: { tokenCount: 5000, model: 'claude-3-opus' },
      });

      const handoff = await manager.get(id);
      expect(handoff?.metadata).toEqual({ tokenCount: 5000, model: 'claude-3-opus' });
    });
  });

  describe('get', () => {
    it('should return null for non-existent handoff', async () => {
      const handoff = await manager.get('non-existent');
      expect(handoff).toBeNull();
    });

    it('should retrieve handoff by id', async () => {
      const timestamp = new Date();
      const id = await manager.create({
        sessionId: 'test-session',
        timestamp,
        summary: 'Test summary',
        codeChanges: [
          { file: 'src/test.ts', description: 'Added tests' },
        ],
        currentState: 'Testing complete',
        blockers: ['Need code review'],
        nextSteps: ['Deploy to staging'],
        patterns: ['TDD approach'],
      });

      const handoff = await manager.get(id);

      expect(handoff).not.toBeNull();
      expect(handoff?.id).toBe(id);
      expect(handoff?.sessionId).toBe('test-session');
      expect(handoff?.summary).toBe('Test summary');
      expect(handoff?.codeChanges).toHaveLength(1);
      expect(handoff?.codeChanges[0].file).toBe('src/test.ts');
      expect(handoff?.blockers).toContain('Need code review');
      expect(handoff?.nextSteps).toContain('Deploy to staging');
      expect(handoff?.patterns).toContain('TDD approach');
    });
  });

  describe('search', () => {
    beforeEach(async () => {
      // Create test handoffs
      await manager.create({
        sessionId: 's1',
        timestamp: new Date('2024-01-01'),
        summary: 'Fixed authentication bug in OAuth flow',
        codeChanges: [{ file: 'src/auth/oauth.ts', description: 'Fixed token refresh' }],
        currentState: 'Auth working',
        blockers: [],
        nextSteps: [],
        patterns: ['JWT tokens'],
      });

      await manager.create({
        sessionId: 's2',
        timestamp: new Date('2024-01-02'),
        summary: 'Added user interface components',
        codeChanges: [{ file: 'src/ui/Button.tsx', description: 'Created button' }],
        currentState: 'UI complete',
        blockers: [],
        nextSteps: [],
        patterns: ['React components'],
      });

      await manager.create({
        sessionId: 's3',
        timestamp: new Date('2024-01-03'),
        summary: 'Database migration for users table',
        codeChanges: [{ file: 'migrations/001_users.sql', description: 'Added users' }],
        currentState: 'Migration applied',
        blockers: [],
        nextSteps: [],
        patterns: ['SQLite migrations'],
      });
    });

    it('should search handoffs by summary content', async () => {
      const results = await manager.search('authentication', 10);
      expect(results.length).toBe(1);
      expect(results[0].summary).toContain('authentication');
    });

    it('should search handoffs by pattern', async () => {
      const results = await manager.search('JWT', 10);
      expect(results.length).toBe(1);
      expect(results[0].sessionId).toBe('s1');
    });

    it('should return empty array for no matches', async () => {
      const results = await manager.search('nonexistent-term-xyz', 10);
      expect(results).toEqual([]);
    });

    it('should respect limit parameter', async () => {
      const results = await manager.search('a', 2); // Should match many
      expect(results.length).toBeLessThanOrEqual(2);
    });

    it('should search code changes', async () => {
      const results = await manager.search('oauth.ts', 10);
      expect(results.length).toBe(1);
      expect(results[0].sessionId).toBe('s1');
    });
  });

  describe('getRecent', () => {
    beforeEach(async () => {
      // Create handoffs with different timestamps
      await manager.create({
        sessionId: 's1',
        timestamp: new Date('2024-01-01'),
        summary: 'First session',
        codeChanges: [],
        currentState: '',
        blockers: [],
        nextSteps: [],
        patterns: [],
      });

      await manager.create({
        sessionId: 's2',
        timestamp: new Date('2024-01-02'),
        summary: 'Second session',
        codeChanges: [],
        currentState: '',
        blockers: [],
        nextSteps: [],
        patterns: [],
      });

      await manager.create({
        sessionId: 's3',
        timestamp: new Date('2024-01-03'),
        summary: 'Third session',
        codeChanges: [],
        currentState: '',
        blockers: [],
        nextSteps: [],
        patterns: [],
      });
    });

    it('should return most recent handoffs first', async () => {
      const recent = await manager.getRecent(3);

      expect(recent.length).toBe(3);
      expect(recent[0].sessionId).toBe('s3'); // Most recent
      expect(recent[1].sessionId).toBe('s2');
      expect(recent[2].sessionId).toBe('s1'); // Oldest
    });

    it('should respect limit parameter', async () => {
      const recent = await manager.getRecent(1);

      expect(recent.length).toBe(1);
      expect(recent[0].sessionId).toBe('s3');
    });

    it('should return empty array when no handoffs exist', async () => {
      const emptyManager = new HandoffManager(':memory:');
      await emptyManager.initialize();

      const recent = await emptyManager.getRecent(5);
      expect(recent).toEqual([]);

      await emptyManager.close();
    });
  });

  describe('getBySession', () => {
    it('should return handoffs for specific session', async () => {
      await manager.create({
        sessionId: 's1',
        timestamp: new Date('2024-01-01'),
        summary: 'First',
        codeChanges: [],
        currentState: '',
        blockers: [],
        nextSteps: [],
        patterns: [],
      });

      await manager.create({
        sessionId: 's1',
        timestamp: new Date('2024-01-02'),
        summary: 'Second for same session',
        codeChanges: [],
        currentState: '',
        blockers: [],
        nextSteps: [],
        patterns: [],
      });

      await manager.create({
        sessionId: 's2',
        timestamp: new Date(),
        summary: 'Different session',
        codeChanges: [],
        currentState: '',
        blockers: [],
        nextSteps: [],
        patterns: [],
      });

      const s1Handoffs = await manager.getBySession('s1');
      expect(s1Handoffs.length).toBe(2);
      expect(s1Handoffs.every(h => h.sessionId === 's1')).toBe(true);
    });
  });

  describe('delete', () => {
    it('should delete existing handoff', async () => {
      const id = await manager.create({
        sessionId: 's1',
        timestamp: new Date(),
        summary: 'To be deleted',
        codeChanges: [],
        currentState: '',
        blockers: [],
        nextSteps: [],
        patterns: [],
      });

      const deleted = await manager.delete(id);
      expect(deleted).toBe(true);

      const handoff = await manager.get(id);
      expect(handoff).toBeNull();
    });

    it('should return false for non-existent handoff', async () => {
      const deleted = await manager.delete('non-existent');
      expect(deleted).toBe(false);
    });

    it('should remove from FTS index', async () => {
      const id = await manager.create({
        sessionId: 's1',
        timestamp: new Date(),
        summary: 'Unique searchable term xyzabc123',
        codeChanges: [],
        currentState: '',
        blockers: [],
        nextSteps: [],
        patterns: [],
      });

      // Verify searchable
      let results = await manager.search('xyzabc123', 10);
      expect(results.length).toBe(1);

      // Delete
      await manager.delete(id);

      // Should no longer be found
      results = await manager.search('xyzabc123', 10);
      expect(results.length).toBe(0);
    });
  });

  describe('count', () => {
    it('should return correct count', async () => {
      expect(await manager.count()).toBe(0);

      await manager.create({
        sessionId: 's1',
        timestamp: new Date(),
        summary: 'First',
        codeChanges: [],
        currentState: '',
        blockers: [],
        nextSteps: [],
        patterns: [],
      });

      expect(await manager.count()).toBe(1);

      await manager.create({
        sessionId: 's2',
        timestamp: new Date(),
        summary: 'Second',
        codeChanges: [],
        currentState: '',
        blockers: [],
        nextSteps: [],
        patterns: [],
      });

      expect(await manager.count()).toBe(2);
    });
  });

  describe('findByPattern', () => {
    beforeEach(async () => {
      await manager.create({
        sessionId: 's1',
        timestamp: new Date(),
        summary: 'Session 1',
        codeChanges: [],
        currentState: '',
        blockers: [],
        nextSteps: [],
        patterns: ['TDD', 'Clean Code'],
      });

      await manager.create({
        sessionId: 's2',
        timestamp: new Date(),
        summary: 'Session 2',
        codeChanges: [],
        currentState: '',
        blockers: [],
        nextSteps: [],
        patterns: ['SOLID', 'Clean Code'],
      });
    });

    it('should find handoffs by pattern', async () => {
      const results = await manager.findByPattern('TDD');
      expect(results.length).toBe(1);
      expect(results[0].sessionId).toBe('s1');
    });

    it('should find multiple handoffs with same pattern', async () => {
      const results = await manager.findByPattern('Clean Code');
      expect(results.length).toBe(2);
    });
  });

  describe('getWithBlockers', () => {
    beforeEach(async () => {
      await manager.create({
        sessionId: 's1',
        timestamp: new Date(),
        summary: 'Blocked session',
        codeChanges: [],
        currentState: '',
        blockers: ['Waiting for API key', 'Need code review'],
        nextSteps: [],
        patterns: [],
      });

      await manager.create({
        sessionId: 's2',
        timestamp: new Date(),
        summary: 'Unblocked session',
        codeChanges: [],
        currentState: '',
        blockers: [],
        nextSteps: [],
        patterns: [],
      });
    });

    it('should return only handoffs with blockers', async () => {
      const blocked = await manager.getWithBlockers();
      expect(blocked.length).toBe(1);
      expect(blocked[0].sessionId).toBe('s1');
      expect(blocked[0].blockers).toContain('Waiting for API key');
    });
  });

  describe('generateContext', () => {
    it('should generate empty string when no handoffs', async () => {
      const context = await manager.generateContext();
      expect(context).toBe('');
    });

    it('should generate context from recent handoffs', async () => {
      await manager.create({
        sessionId: 's1',
        timestamp: new Date('2024-01-01'),
        summary: 'Implemented feature X',
        codeChanges: [],
        currentState: 'Feature working',
        blockers: [],
        nextSteps: ['Add tests', 'Update docs'],
        patterns: ['TDD'],
      });

      const context = await manager.generateContext(1);

      expect(context).toContain('Previous Session Context');
      expect(context).toContain('Session: s1');
      expect(context).toContain('Implemented feature X');
      expect(context).toContain('Feature working');
      expect(context).toContain('Add tests');
      expect(context).toContain('TDD');
    });
  });

  describe('code changes serialization', () => {
    it('should serialize and deserialize code changes correctly', async () => {
      const codeChanges: CodeChange[] = [
        { file: 'src/auth/oauth.ts', description: 'Added PKCE flow' },
        { file: 'src/auth/token.ts', description: 'Token refresh logic' },
        { file: 'package.json', description: 'Added dependencies' },
      ];

      const id = await manager.create({
        sessionId: 's1',
        timestamp: new Date(),
        summary: 'Auth implementation',
        codeChanges,
        currentState: 'Complete',
        blockers: [],
        nextSteps: [],
        patterns: [],
      });

      const handoff = await manager.get(id);

      expect(handoff?.codeChanges).toHaveLength(3);
      expect(handoff?.codeChanges[0].file).toBe('src/auth/oauth.ts');
      expect(handoff?.codeChanges[0].description).toBe('Added PKCE flow');
      expect(handoff?.codeChanges[2].file).toBe('package.json');
    });

    it('should make code changes searchable', async () => {
      await manager.create({
        sessionId: 's1',
        timestamp: new Date(),
        summary: 'Auth work',
        codeChanges: [
          { file: 'src/auth/oauth.ts', description: 'Added PKCE flow' },
        ],
        currentState: '',
        blockers: [],
        nextSteps: [],
        patterns: [],
      });

      // Should be able to search by file name
      const resultsByFile = await manager.search('oauth', 10);
      expect(resultsByFile.length).toBe(1);

      // Should be able to search by description
      const resultsByDesc = await manager.search('PKCE', 10);
      expect(resultsByDesc.length).toBe(1);
    });
  });
});
