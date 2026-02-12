/**
 * @fileoverview Tests for ContextOps task context in detailed snapshot
 */

import { describe, it, expect, beforeEach, vi } from 'vitest';
import { ContextOps, createContextOps, type ContextOpsConfig } from '../context-ops.js';

// =============================================================================
// Test Fixtures
// =============================================================================

function createMockSessionStore() {
  const store = new Map<string, any>();
  return {
    get: vi.fn((id: string) => store.get(id)),
    set: (id: string, session: any) => store.set(id, session),
  };
}

function createMockActiveSession() {
  return {
    agent: {
      getContextManager: vi.fn().mockReturnValue({
        getSnapshot: vi.fn().mockReturnValue({
          currentTokens: 5000,
          contextLimit: 200_000,
          usagePercent: 2.5,
          thresholdLevel: 'normal',
          breakdown: { systemPrompt: 1000, tools: 2000, rules: 500, messages: 1500 },
        }),
        getDetailedSnapshot: vi.fn().mockReturnValue({
          currentTokens: 5000,
          contextLimit: 200_000,
          usagePercent: 2.5,
          thresholdLevel: 'normal',
          breakdown: { systemPrompt: 1000, tools: 2000, rules: 500, messages: 1500 },
          messages: [],
          systemPromptContent: 'system prompt',
          toolsContent: ['tool1'],
        }),
        getMemoryContent: vi.fn().mockReturnValue(null),
        getSessionMemories: vi.fn().mockReturnValue([]),
      }),
    },
    sessionContext: {
      getMessageEventIds: vi.fn().mockReturnValue([]),
    },
    skillTracker: {
      getAddedSkills: vi.fn().mockReturnValue([]),
    },
    rulesTracker: {
      getRulesFiles: vi.fn().mockReturnValue([]),
      getRulesIndex: vi.fn().mockReturnValue(null),
    },
  };
}

// =============================================================================
// Tests
// =============================================================================

describe('ContextOps - Task Context in Detailed Snapshot', () => {
  let contextOps: ContextOps;
  let sessionStore: ReturnType<typeof createMockSessionStore>;
  let mockTaskContextBuilder: { buildSummary: ReturnType<typeof vi.fn> };

  beforeEach(() => {
    sessionStore = createMockSessionStore();
    mockTaskContextBuilder = { buildSummary: vi.fn().mockReturnValue(undefined) };

    contextOps = createContextOps({
      sessionStore: sessionStore as any,
      emit: vi.fn(),
      taskContextBuilder: mockTaskContextBuilder,
    });
  });

  it('includes taskContext when tasks exist', () => {
    const session = createMockActiveSession();
    sessionStore.set('sess_1', session);
    mockTaskContextBuilder.buildSummary.mockReturnValue(
      '## Active Tasks\n- [in_progress] Fix the bug\n- [pending] Write tests'
    );

    const result = contextOps.getDetailedContextSnapshot('sess_1') as any;

    expect(result.taskContext).toBeDefined();
    expect(result.taskContext.summary).toContain('Active Tasks');
    expect(result.taskContext.tokens).toBeGreaterThan(0);
  });

  it('omits taskContext when no tasks', () => {
    const session = createMockActiveSession();
    sessionStore.set('sess_1', session);
    mockTaskContextBuilder.buildSummary.mockReturnValue(undefined);

    const result = contextOps.getDetailedContextSnapshot('sess_1') as any;

    expect(result.taskContext).toBeUndefined();
  });

  it('omits taskContext when builder not configured', () => {
    // Create without taskContextBuilder
    const ops = createContextOps({
      sessionStore: sessionStore as any,
      emit: vi.fn(),
    });
    const session = createMockActiveSession();
    sessionStore.set('sess_1', session);

    const result = ops.getDetailedContextSnapshot('sess_1') as any;

    expect(result.taskContext).toBeUndefined();
  });

  it('returns default snapshot without taskContext for inactive session', () => {
    const result = contextOps.getDetailedContextSnapshot('nonexistent') as any;

    expect(result.currentTokens).toBe(0);
    expect(result.taskContext).toBeUndefined();
  });

  it('estimates tokens from summary length', () => {
    const session = createMockActiveSession();
    sessionStore.set('sess_1', session);
    const summary = 'A'.repeat(400); // 400 chars = 100 tokens
    mockTaskContextBuilder.buildSummary.mockReturnValue(summary);

    const result = contextOps.getDetailedContextSnapshot('sess_1') as any;

    expect(result.taskContext.tokens).toBe(100); // Math.ceil(400 / 4)
  });
});
