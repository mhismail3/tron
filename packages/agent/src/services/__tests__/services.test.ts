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
      currentTokens: 1000,
      contextLimit: 200000,
      usagePercent: 0.5,
      thresholdLevel: 'normal',
      breakdown: { systemPrompt: 100, tools: 200, rules: 50, messages: 650 },
    }),
    getDetailedContextSnapshot: vi.fn().mockReturnValue({
      currentTokens: 1000,
      contextLimit: 200000,
      usagePercent: 0.5,
      thresholdLevel: 'normal',
      breakdown: { systemPrompt: 100, tools: 200, rules: 50, messages: 650 },
      messages: [],
      systemPromptContent: '',
      toolsContent: [],
    }),
    shouldCompact: vi.fn().mockReturnValue(false),
    previewCompaction: vi.fn().mockResolvedValue({
      tokensBefore: 1000,
      tokensAfter: 500,
      compressionRatio: 0.5,
      preservedTurns: 3,
      summarizedTurns: 5,
      summary: 'Test summary',
    }),
    confirmCompaction: vi.fn().mockResolvedValue({
      success: true,
      tokensBefore: 1000,
      tokensAfter: 500,
      compressionRatio: 0.5,
      summary: 'Test summary',
    }),
    canAcceptTurn: vi.fn().mockReturnValue({
      canProceed: true,
      needsCompaction: false,
      wouldExceedLimit: false,
      currentTokens: 1000,
      estimatedAfterTurn: 2000,
      contextLimit: 200000,
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
    getActiveSession: vi.fn().mockReturnValue(null),
    emit: vi.fn(),
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
      expect(snapshot.currentTokens).toBe(1000);
      expect(snapshot.contextLimit).toBe(200000);
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
      expect(preview.tokensBefore).toBe(1000);
      expect(preview.tokensAfter).toBe(500);
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
