/**
 * @fileoverview Tests for Services Module
 *
 * The services module provides thin service wrappers around existing
 * implementations. These tests verify the factory functions and interfaces.
 */

import { describe, it, expect, vi } from 'vitest';
import {
  createContextService,
  type ContextService,
  type ContextServiceDeps,
} from '../context/index.js';

// Mock the underlying ContextOps implementation
vi.mock('../../orchestrator/operations/context-ops.js', () => ({
  createContextOps: vi.fn(() => ({
    getContextSnapshot: vi.fn().mockReturnValue({
      sessionId: 'session-123',
      tokens: { current: 1000, limit: 200000, percentage: 0.5 },
      thresholds: { compact: 0.8, warning: 0.9, critical: 0.95 },
    }),
    getDetailedContextSnapshot: vi.fn().mockReturnValue({
      sessionId: 'session-123',
      tokens: { current: 1000, limit: 200000, percentage: 0.5 },
      thresholds: { compact: 0.8, warning: 0.9, critical: 0.95 },
      messages: [],
    }),
    shouldCompact: vi.fn().mockReturnValue(false),
    previewCompaction: vi.fn().mockResolvedValue({
      beforeTokens: 1000,
      afterTokens: 500,
      reduction: 500,
      reductionPercent: 50,
      summary: 'Test summary',
    }),
    confirmCompaction: vi.fn().mockResolvedValue({
      beforeTokens: 1000,
      afterTokens: 500,
      reduction: 500,
      reductionPercent: 50,
    }),
    canAcceptTurn: vi.fn().mockReturnValue({
      canAccept: true,
      needsCompaction: false,
    }),
    clearContext: vi.fn().mockResolvedValue({
      success: true,
      tokensBefore: 1000,
      tokensAfter: 0,
      clearedTodos: [],
    }),
  })),
  ContextOps: vi.fn(),
}));

describe('ContextService', () => {
  const mockDeps: ContextServiceDeps = {
    eventStore: {
      getSession: vi.fn(),
      getMessagesAt: vi.fn().mockResolvedValue([]),
    } as any,
    getActiveSession: vi.fn().mockReturnValue(null),
  };

  it('creates context service instance with all methods', () => {
    const service = createContextService(mockDeps);
    expect(service).toBeDefined();
    expect(typeof service.getSnapshot).toBe('function');
    expect(typeof service.getDetailedSnapshot).toBe('function');
    expect(typeof service.shouldCompact).toBe('function');
    expect(typeof service.previewCompaction).toBe('function');
    expect(typeof service.confirmCompaction).toBe('function');
    expect(typeof service.canAcceptTurn).toBe('function');
    expect(typeof service.clearContext).toBe('function');
  });

  describe('getSnapshot', () => {
    it('returns context snapshot for a session', () => {
      const service = createContextService(mockDeps);
      const snapshot = service.getSnapshot('session-123');

      expect(snapshot).toBeDefined();
      expect(snapshot.sessionId).toBe('session-123');
      expect(snapshot.tokens).toBeDefined();
    });
  });

  describe('shouldCompact', () => {
    it('returns boolean indicating compaction need', () => {
      const service = createContextService(mockDeps);
      const result = service.shouldCompact('session-123');

      expect(typeof result).toBe('boolean');
    });
  });

  describe('previewCompaction', () => {
    it('returns compaction preview', async () => {
      const service = createContextService(mockDeps);
      const preview = await service.previewCompaction('session-123');

      expect(preview).toBeDefined();
      expect(preview.beforeTokens).toBe(1000);
      expect(preview.afterTokens).toBe(500);
    });
  });

  describe('clearContext', () => {
    it('returns clear result', async () => {
      const service = createContextService(mockDeps);
      const result = await service.clearContext('session-123');

      expect(result.success).toBe(true);
      expect(result.tokensBefore).toBe(1000);
      expect(result.tokensAfter).toBe(0);
    });
  });
});

describe('SessionService', () => {
  // SessionService is a thin wrapper around SessionManager which is already tested
  // These are placeholder tests to verify the module structure

  it.todo('creates session service instance');
  it.todo('delegates createSession to manager');
  it.todo('delegates resumeSession to manager');
  it.todo('delegates endSession to manager');
});

describe('OrchestrationService', () => {
  // OrchestrationService interface is exported but not yet implemented
  it.todo('provides run coordination interface');
});
