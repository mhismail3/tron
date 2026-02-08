/**
 * @fileoverview Tests for buildEmbeddingText
 */

import { describe, it, expect } from 'vitest';
import { buildEmbeddingText } from '../embedding-text.js';
import type { MemoryLedgerPayload } from '@infrastructure/events/types/memory.js';

describe('buildEmbeddingText', () => {
  it('builds text from all fields', () => {
    const payload: MemoryLedgerPayload = {
      eventRange: { firstEventId: 'e1', lastEventId: 'e2' },
      turnRange: { firstTurn: 1, lastTurn: 5 },
      title: 'Add OAuth support',
      entryType: 'feature',
      status: 'completed',
      tags: ['auth', 'security'],
      input: 'Implement OAuth for Anthropic API',
      actions: ['Created auth module', 'Added token refresh'],
      files: [{ path: 'auth.ts', op: 'C', why: 'New auth module' }],
      decisions: [{ choice: 'Use PKCE flow', reason: 'More secure for CLI apps' }],
      lessons: ['Always validate tokens before use'],
      thinkingInsights: [],
      tokenCost: { input: 1000, output: 500 },
      model: 'claude-sonnet-4-20250514',
      workingDirectory: '/project',
    };

    const text = buildEmbeddingText(payload);

    expect(text).toContain('Add OAuth support');
    expect(text).toContain('Implement OAuth for Anthropic API');
    expect(text).toContain('Created auth module');
    expect(text).toContain('Added token refresh');
    expect(text).toContain('Always validate tokens before use');
    expect(text).toContain('Use PKCE flow');
    expect(text).toContain('auth');
    expect(text).toContain('security');
  });

  it('handles empty/missing fields gracefully', () => {
    const payload: MemoryLedgerPayload = {
      eventRange: { firstEventId: 'e1', lastEventId: 'e2' },
      turnRange: { firstTurn: 1, lastTurn: 1 },
      title: 'Quick fix',
      entryType: 'bugfix',
      status: 'completed',
      tags: [],
      input: '',
      actions: [],
      files: [],
      decisions: [],
      lessons: [],
      thinkingInsights: [],
      tokenCost: { input: 100, output: 50 },
      model: 'claude-sonnet-4-20250514',
      workingDirectory: '/project',
    };

    const text = buildEmbeddingText(payload);

    expect(text).toContain('Quick fix');
    expect(text.length).toBeGreaterThan(0);
  });

  it('joins multiple items with newlines', () => {
    const payload: MemoryLedgerPayload = {
      eventRange: { firstEventId: 'e1', lastEventId: 'e2' },
      turnRange: { firstTurn: 1, lastTurn: 3 },
      title: 'Multi-action session',
      entryType: 'feature',
      status: 'completed',
      tags: ['a', 'b'],
      input: 'Do multiple things',
      actions: ['First action', 'Second action'],
      files: [{ path: 'a.ts', op: 'M', why: 'Modified' }],
      decisions: [],
      lessons: ['Lesson 1', 'Lesson 2'],
      thinkingInsights: [],
      tokenCost: { input: 500, output: 300 },
      model: 'claude-sonnet-4-20250514',
      workingDirectory: '/project',
    };

    const text = buildEmbeddingText(payload);

    // Should be joined with newlines between major sections
    expect(text.split('\n').length).toBeGreaterThanOrEqual(4);
  });
});
