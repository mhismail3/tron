/**
 * @fileoverview Tests for cache-TTL pruning
 *
 * Pure functions for determining cache coldness and pruning
 * large tool_result blocks from old turns to reduce re-caching cost.
 */

import { describe, it, expect } from 'vitest';
import { isCacheCold, pruneToolResultsForRecache } from '../cache-pruning.js';

describe('isCacheCold', () => {
  it('returns true when elapsed time exceeds default 5m TTL', () => {
    const fiveMinutesAgo = Date.now() - 5 * 60 * 1000 - 1;
    expect(isCacheCold(fiveMinutesAgo)).toBe(true);
  });

  it('returns false when elapsed time is within 5m TTL', () => {
    const threeMinutesAgo = Date.now() - 3 * 60 * 1000;
    expect(isCacheCold(threeMinutesAgo)).toBe(false);
  });

  it('returns false when lastApiCallMs is 0 (no prior call)', () => {
    expect(isCacheCold(0)).toBe(false);
  });

  it('supports custom TTL', () => {
    const twoMinutesAgo = Date.now() - 2 * 60 * 1000 - 1;
    expect(isCacheCold(twoMinutesAgo, 2 * 60 * 1000)).toBe(true);
  });

  it('returns false at exactly the TTL boundary', () => {
    const exactlyFiveMinutesAgo = Date.now() - 5 * 60 * 1000;
    expect(isCacheCold(exactlyFiveMinutesAgo)).toBe(false);
  });
});

describe('pruneToolResultsForRecache', () => {
  function makeToolResult(content: string): any {
    return {
      role: 'user',
      content: [
        { type: 'tool_result', tool_use_id: 'toolu_1', content },
      ],
    };
  }

  function makeTextMessage(text: string): any {
    return {
      role: 'user',
      content: [{ type: 'text', text }],
    };
  }

  function makeAssistantMessage(text: string): any {
    return {
      role: 'assistant',
      content: [{ type: 'text', text }],
    };
  }

  it('preserves recent 3 turns, prunes older large tool_results', () => {
    const largeContent = 'x'.repeat(3000); // > 2KB
    const messages = [
      makeAssistantMessage('turn1'),     // turn 1 (old)
      makeToolResult(largeContent),
      makeAssistantMessage('turn2'),     // turn 2 (recent — 4-3=1, starts at turn 2)
      makeToolResult('small'),
      makeAssistantMessage('turn3'),     // turn 3 (recent)
      makeToolResult('also small'),
      makeAssistantMessage('turn4'),     // turn 4 (recent)
      makeToolResult('fine'),
    ];

    const result = pruneToolResultsForRecache(messages);

    // Turn 1 tool_result (old, large) should be pruned
    expect(result[1].content[0].content).toContain('[pruned');
    // Recent turns' tool_results should be preserved
    expect(result[3].content[0].content).toBe('small');
    expect(result[5].content[0].content).toBe('also small');
    expect(result[7].content[0].content).toBe('fine');
  });

  it('does not prune tool_results under 2KB', () => {
    const smallContent = 'x'.repeat(1000); // < 2KB
    const messages = [
      makeAssistantMessage('old1'),       // turn 1 (old)
      makeToolResult(smallContent),
      makeAssistantMessage('old2'),       // turn 2 (old — will be in prune window)
      makeToolResult(smallContent),
      makeAssistantMessage('recent1'),    // turn 3
      makeToolResult('recent'),
      makeAssistantMessage('recent2'),    // turn 4
      makeToolResult('recent'),
      makeAssistantMessage('recent3'),    // turn 5
      makeToolResult('recent'),
    ];

    const result = pruneToolResultsForRecache(messages);

    // Small content in old turns should NOT be pruned (under threshold)
    expect(result[1].content[0].content).toBe(smallContent);
    expect(result[3].content[0].content).toBe(smallContent);
  });

  it('does NOT mutate the input array', () => {
    const largeContent = 'x'.repeat(3000);
    const messages = [
      makeAssistantMessage('old'),       // turn 1 (old)
      makeToolResult(largeContent),
      makeAssistantMessage('r1'),        // turn 2
      makeToolResult('small'),
      makeAssistantMessage('r2'),        // turn 3
      makeToolResult('small'),
      makeAssistantMessage('r3'),        // turn 4
      makeToolResult('small'),
    ];

    const originalContent = messages[1].content[0].content;
    pruneToolResultsForRecache(messages);

    // Original should be unchanged
    expect(messages[1].content[0].content).toBe(originalContent);
  });

  it('handles empty array', () => {
    const result = pruneToolResultsForRecache([]);
    expect(result).toEqual([]);
  });

  it('handles messages with no tool_results', () => {
    const messages = [
      makeTextMessage('hello'),
      makeAssistantMessage('hi'),
    ];

    const result = pruneToolResultsForRecache(messages);
    expect(result).toEqual(messages);
  });

  it('handles string content (not array) in user messages', () => {
    const messages = [
      makeAssistantMessage('old'),
      { role: 'user', content: 'x'.repeat(3000) }, // string content, not array
      makeAssistantMessage('r1'),
      makeToolResult('small'),
      makeAssistantMessage('r2'),
      makeToolResult('small'),
      makeAssistantMessage('r3'),
      makeToolResult('small'),
    ];

    // Should not throw
    const result = pruneToolResultsForRecache(messages);
    expect(result).toHaveLength(8);
  });

  it('supports custom recentTurnsToPreserve', () => {
    const largeContent = 'x'.repeat(3000);
    const messages = [
      makeAssistantMessage('1'),
      makeToolResult(largeContent),
      makeAssistantMessage('2'),
      makeToolResult(largeContent),
    ];

    // Preserve only 1 recent turn
    const result = pruneToolResultsForRecache(messages, 1);

    // First tool_result should be pruned
    expect(result[1].content[0].content).toContain('[pruned');
    // Second (most recent) should be preserved
    expect(result[3].content[0].content).toBe(largeContent);
  });

  it('handles all messages being within recent window', () => {
    const largeContent = 'x'.repeat(3000);
    const messages = [
      makeAssistantMessage('1'),
      makeToolResult(largeContent),
    ];

    // With default 3 turns, 1 turn is within window
    const result = pruneToolResultsForRecache(messages);
    expect(result[1].content[0].content).toBe(largeContent);
  });
});
