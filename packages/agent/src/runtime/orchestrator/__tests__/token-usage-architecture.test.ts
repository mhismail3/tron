/**
 * @fileoverview Token Usage Architecture Tests
 *
 * These tests define the expected behavior for the redesigned token usage architecture.
 * The key principle is: token data should be captured and normalized as early as possible,
 * and ALL message.assistant events should include complete token information.
 *
 * ## Architecture Overview
 *
 * 1. response_complete event fires immediately after LLM streaming completes (before tools)
 * 2. TokenRecord is computed immediately when response_complete is received
 * 3. message.assistant events ALWAYS include tokenUsage and tokenRecord
 * 4. iOS can read token data directly - no correlation with stream.turn_end needed
 *
 * ## Test Coverage
 *
 * - response_complete event timing and data
 * - Early normalization (before tool execution)
 * - Token data on message.assistant for both tool and non-tool turns
 * - Provider-specific normalization (Anthropic, OpenAI, Google, Codex)
 * - Context delta calculation accuracy
 * - Session reconstruction without fallbacks
 */

import { describe, it, expect, beforeEach } from 'vitest';
import { TurnContentTracker } from '../turn/turn-content-tracker.js';
import { normalizeTokens, type TokenSource } from '@infrastructure/tokens/index.js';
import type { ProviderType } from '@core/types/messages.js';

// Helper to create a TokenSource for normalizeTokens
function createTokenSource(
  provider: ProviderType,
  inputTokens: number,
  outputTokens: number,
  cacheReadTokens = 0,
  cacheCreationTokens = 0
): TokenSource {
  return {
    provider,
    timestamp: new Date().toISOString(),
    rawInputTokens: inputTokens,
    rawOutputTokens: outputTokens,
    rawCacheReadTokens: cacheReadTokens,
    rawCacheCreationTokens: cacheCreationTokens,
  };
}

describe('Token Usage Architecture', () => {
  describe('TurnContentTracker - Early Token Capture', () => {
    let tracker: TurnContentTracker;

    beforeEach(() => {
      tracker = new TurnContentTracker();
    });

    describe('setResponseTokenUsage (captures tokens early)', () => {
      it('should compute TokenRecord immediately when token usage is set', () => {
        tracker.onAgentStart();
        tracker.onTurnStart(1);

        // Simulate response_complete: set token usage BEFORE tools execute
        // cacheCreationTokens ARE part of context (mutually exclusive with input/cacheRead)
        tracker.setResponseTokenUsage({
          inputTokens: 500,
          outputTokens: 100,
          cacheCreationTokens: 8000, // Being written to cache AND sent to model
        });

        // TokenRecord should be available immediately
        const tokenRecord = tracker.getLastTokenRecord();
        expect(tokenRecord).toBeDefined();
        // contextWindowTokens = inputTokens + cacheRead + cacheCreate (all mutually exclusive)
        expect(tokenRecord?.computed.newInputTokens).toBe(8500); // First turn: 500 + 8000
        expect(tokenRecord?.computed.contextWindowTokens).toBe(8500); // input + cacheCreate
        expect(tokenRecord?.source.rawOutputTokens).toBe(100);
      });

      it('should make token data available for pre-tool flush', () => {
        tracker.onAgentStart();
        tracker.onTurnStart(1);

        // Set token usage (simulating response_complete)
        tracker.setResponseTokenUsage({
          inputTokens: 604,
          outputTokens: 53,
          cacheReadTokens: 17332,
        });

        // Add content and register tools
        tracker.addTextDelta('Let me read the file.');
        tracker.registerToolIntents([
          { id: 'tc_1', name: 'Read', arguments: { file_path: 'test.ts' } },
        ]);

        // Token usage should be available for the message.assistant event
        const tokenUsage = tracker.getLastTurnTokenUsage();
        const tokenRecord = tracker.getLastTokenRecord();

        expect(tokenUsage).toBeDefined();
        expect(tokenUsage?.inputTokens).toBe(604);
        expect(tokenRecord).toBeDefined();
        expect(tokenRecord?.computed.newInputTokens).toBe(17936); // 604 + 17332 (first turn)
        expect(tokenRecord?.computed.contextWindowTokens).toBe(17936);
      });

      it('should update baseline for subsequent turns', () => {
        tracker.onAgentStart();

        // Turn 1: cacheCreation is part of context (being written to cache AND sent to model)
        tracker.onTurnStart(1);
        tracker.setResponseTokenUsage({
          inputTokens: 500,
          outputTokens: 100,
          cacheCreationTokens: 8000, // Writing to cache AND part of context
        });
        tracker.onTurnEnd(); // This should NOT re-compute (already done)

        // Turn 2: Now reading from cache (same content, now served from cache)
        tracker.onTurnStart(2);
        tracker.setResponseTokenUsage({
          inputTokens: 604,
          outputTokens: 50,
          cacheReadTokens: 8000, // Cache is now being READ (same tokens as before)
        });

        const tokenRecord = tracker.getLastTokenRecord();
        // contextWindowTokens = 604 + 8000 = 8604
        // Previous was 8500 (500 input + 8000 cacheCreation)
        expect(tokenRecord?.computed.newInputTokens).toBe(104); // 8604 - 8500 (small delta)
        expect(tokenRecord?.computed.contextWindowTokens).toBe(8604); // 604 + 8000
      });
    });

    describe('Token data persistence on message.assistant', () => {
      it('should include token data on message.assistant for NO-TOOL turns', () => {
        tracker.onAgentStart();
        tracker.onTurnStart(1);

        // Set token usage (response complete)
        tracker.setResponseTokenUsage({
          inputTokens: 500,
          outputTokens: 100,
        });

        // Just text, no tools
        tracker.addTextDelta('Here is my response.');

        // Get the data that would go on message.assistant
        const tokenUsage = tracker.getLastTurnTokenUsage();
        const tokenRecord = tracker.getLastTokenRecord();

        expect(tokenUsage).toBeDefined();
        expect(tokenRecord).toBeDefined();
        expect(tokenUsage?.inputTokens).toBe(500);
        expect(tokenRecord?.computed.newInputTokens).toBe(500);
      });

      it('should include token data on message.assistant for TOOL turns', () => {
        tracker.onAgentStart();
        tracker.onTurnStart(1);

        // Set token usage BEFORE tool execution (response complete)
        tracker.setResponseTokenUsage({
          inputTokens: 604,
          outputTokens: 53,
          cacheReadTokens: 17332,
        });

        // Add text and tools
        tracker.addTextDelta('Let me read files.');
        tracker.registerToolIntents([
          { id: 'tc_1', name: 'Read', arguments: { file_path: 'a.ts' } },
          { id: 'tc_2', name: 'Read', arguments: { file_path: 'b.ts' } },
        ]);

        // Flush pre-tool content (this is what creates message.assistant for tool turns)
        tracker.startToolCall('tc_1', 'Read', { file_path: 'a.ts' }, new Date().toISOString());
        const flushed = tracker.flushPreToolContent();

        // The token data should be available to include on the message.assistant event
        const tokenUsage = tracker.getLastTurnTokenUsage();
        const tokenRecord = tracker.getLastTokenRecord();

        expect(flushed).not.toBeNull();
        expect(tokenUsage).toBeDefined();
        expect(tokenRecord).toBeDefined();

        // These values should be correct for Anthropic
        expect(tokenUsage?.inputTokens).toBe(604);
        expect(tokenUsage?.cacheReadTokens).toBe(17332);
        expect(tokenRecord?.computed.contextWindowTokens).toBe(17936); // 604 + 17332
        expect(tokenRecord?.computed.newInputTokens).toBe(17936); // First turn
      });
    });

    describe('Provider-specific normalization', () => {
      it('should handle Anthropic semantics (inputTokens excludes cache)', () => {
        tracker.setProviderType('anthropic');
        tracker.onAgentStart();
        tracker.onTurnStart(1);

        tracker.setResponseTokenUsage({
          inputTokens: 502, // Non-cached only
          outputTokens: 53,
          cacheReadTokens: 17332, // Cached system prompt
        });

        const tokenRecord = tracker.getLastTokenRecord();
        // contextWindow = inputTokens + cacheRead
        expect(tokenRecord?.computed.contextWindowTokens).toBe(17834); // 502 + 17332
        expect(tokenRecord?.source.rawInputTokens).toBe(502);
        expect(tokenRecord?.source.rawCacheReadTokens).toBe(17332);
      });

      it('should handle OpenAI semantics (inputTokens is full context)', () => {
        tracker.setProviderType('openai');
        tracker.onAgentStart();

        // Turn 1
        tracker.onTurnStart(1);
        tracker.setResponseTokenUsage({
          inputTokens: 5000, // FULL context
          outputTokens: 100,
        });
        tracker.onTurnEnd();

        // Turn 2
        tracker.onTurnStart(2);
        tracker.setResponseTokenUsage({
          inputTokens: 6000, // Context grew
          outputTokens: 150,
        });

        const tokenRecord = tracker.getLastTokenRecord();
        // For OpenAI, contextWindow = inputTokens (no cache adjustment)
        expect(tokenRecord?.computed.contextWindowTokens).toBe(6000);
        expect(tokenRecord?.computed.newInputTokens).toBe(1000); // 6000 - 5000
      });

      it('should handle Google semantics (same as OpenAI)', () => {
        tracker.setProviderType('google');
        tracker.onAgentStart();
        tracker.onTurnStart(1);

        tracker.setResponseTokenUsage({
          inputTokens: 8000,
          outputTokens: 200,
        });

        const tokenRecord = tracker.getLastTokenRecord();
        expect(tokenRecord?.computed.contextWindowTokens).toBe(8000);
        expect(tokenRecord?.computed.newInputTokens).toBe(8000); // First turn
      });

      it('should reset baseline when provider changes', () => {
        tracker.setProviderType('anthropic');
        tracker.onAgentStart();
        tracker.onTurnStart(1);
        tracker.setResponseTokenUsage({
          inputTokens: 500,
          outputTokens: 100,
          cacheReadTokens: 8000,
        });
        tracker.onTurnEnd();

        // Switch provider (model switch)
        tracker.setProviderType('openai');

        tracker.onTurnStart(2);
        tracker.setResponseTokenUsage({
          inputTokens: 5000,
          outputTokens: 150,
        });

        const tokenRecord = tracker.getLastTokenRecord();
        // Baseline reset to 0 on provider change
        expect(tokenRecord?.computed.newInputTokens).toBe(5000); // All new (baseline was reset)
      });
    });

    describe('Context delta accuracy', () => {
      it('should calculate accurate deltas across multi-turn sessions', () => {
        tracker.setProviderType('anthropic');
        tracker.onAgentStart();

        // Turn 1: Initial context with cache being written
        // IMPORTANT: Anthropic's three token fields are MUTUALLY EXCLUSIVE:
        // - inputTokens: tokens NOT involved in cache operations
        // - cacheCreationTokens: tokens being written TO cache (part of context)
        // - cacheReadTokens: tokens read FROM cache (part of context)
        // Total context = inputTokens + cacheCreationTokens + cacheReadTokens (no overlap)
        tracker.onTurnStart(1);
        tracker.setResponseTokenUsage({
          inputTokens: 500,
          outputTokens: 100,
          cacheCreationTokens: 8000, // System prompt being written to cache (IS part of context)
        });
        // contextWindow = 500 + 8000 = 8500 (cacheCreation IS context)
        expect(tracker.getLastTokenRecord()?.computed.newInputTokens).toBe(8500);
        expect(tracker.getLastTokenRecord()?.computed.contextWindowTokens).toBe(8500);
        tracker.onTurnEnd();

        // Turn 2: Cache hit - same system prompt now read from cache
        tracker.onTurnStart(2);
        tracker.setResponseTokenUsage({
          inputTokens: 800, // Grew by 300 (user + prev assistant, non-cached)
          outputTokens: 150,
          cacheReadTokens: 8000, // System prompt now read from cache
        });
        // contextWindow = 800 + 8000 = 8800, previous was 8500
        expect(tracker.getLastTokenRecord()?.computed.newInputTokens).toBe(300); // 8800 - 8500
        expect(tracker.getLastTokenRecord()?.computed.contextWindowTokens).toBe(8800);
        tracker.onTurnEnd();

        // Turn 3: More growth
        tracker.onTurnStart(3);
        tracker.setResponseTokenUsage({
          inputTokens: 1200,
          outputTokens: 200,
          cacheReadTokens: 8000,
        });
        // contextWindow = 1200 + 8000 = 9200, previous was 8800
        expect(tracker.getLastTokenRecord()?.computed.newInputTokens).toBe(400); // 9200 - 8800
        expect(tracker.getLastTokenRecord()?.computed.contextWindowTokens).toBe(9200);
      });

      it('should handle context shrink gracefully (compaction)', () => {
        tracker.setProviderType('openai');
        tracker.onAgentStart();

        // Turn 1: Large context
        tracker.onTurnStart(1);
        tracker.setResponseTokenUsage({
          inputTokens: 50000,
          outputTokens: 100,
        });
        tracker.onTurnEnd();

        // Turn 2: Context shrank (compaction happened)
        tracker.onTurnStart(2);
        tracker.setResponseTokenUsage({
          inputTokens: 10000, // Shrank from 50000
          outputTokens: 100,
        });

        const tokenRecord = tracker.getLastTokenRecord();
        // Should report 0, not negative
        expect(tokenRecord?.computed.newInputTokens).toBe(0);
        expect(tokenRecord?.computed.contextWindowTokens).toBe(10000);
      });
    });

    describe('onTurnEnd should not re-compute if already set', () => {
      it('should preserve tokenRecord from setResponseTokenUsage', () => {
        tracker.onAgentStart();
        tracker.onTurnStart(1);

        // Set token usage early (response complete)
        tracker.setResponseTokenUsage({
          inputTokens: 500,
          outputTokens: 100,
        });

        const beforeEnd = tracker.getLastTokenRecord();
        expect(beforeEnd?.computed.newInputTokens).toBe(500);

        // End turn (should NOT overwrite)
        tracker.onTurnEnd();

        const afterEnd = tracker.getLastTokenRecord();
        expect(afterEnd?.computed.newInputTokens).toBe(500);
      });
    });
  });

  describe('normalizeTokens function', () => {
    // These tests ensure the core normalization logic is correct

    describe('first turn behavior', () => {
      it('should treat entire context as new on first turn (previousContextSize = 0)', () => {
        const providers: ProviderType[] = ['anthropic', 'openai', 'openai-codex', 'google'];

        for (const provider of providers) {
          const source = createTokenSource(provider, 5000, 100);
          const result = normalizeTokens(source, 0, {
            turn: 1,
            sessionId: 'test',
            extractedAt: new Date().toISOString(),
            normalizedAt: new Date().toISOString(),
          });
          expect(result.computed.newInputTokens).toBe(5000);
        }
      });
    });

    describe('Anthropic cache handling', () => {
      it('should include all token types (input + cacheRead + cacheCreation) in context window', () => {
        // Anthropic token fields are MUTUALLY EXCLUSIVE (no overlap)
        // Total context = input + cacheRead + cacheCreation
        const source = createTokenSource('anthropic', 500, 100, 8000, 200);
        const result = normalizeTokens(source, 0, {
          turn: 1,
          sessionId: 'test',
          extractedAt: new Date().toISOString(),
          normalizedAt: new Date().toISOString(),
        });

        // contextWindowTokens = inputTokens + cacheRead + cacheCreate (mutually exclusive)
        expect(result.computed.contextWindowTokens).toBe(8700); // 500 + 8000 + 200
        expect(result.source.rawInputTokens).toBe(500);
        expect(result.source.rawCacheReadTokens).toBe(8000);
        expect(result.source.rawCacheCreationTokens).toBe(200);
      });

      it('should calculate delta from contextWindowTokens for Anthropic', () => {
        // Previous context was 8700 (500 input + 8000 cacheRead + 200 cacheCreation)
        const source = createTokenSource('anthropic', 604, 100, 8000);
        const result = normalizeTokens(source, 8700, {
          turn: 2,
          sessionId: 'test',
          extractedAt: new Date().toISOString(),
          normalizedAt: new Date().toISOString(),
        });

        // New context is 8604 (604 input + 8000 cacheRead)
        // Context actually shrank, so delta should be 0
        expect(result.computed.newInputTokens).toBe(0); // Context shrunk
        expect(result.computed.contextWindowTokens).toBe(8604);
      });
    });

    describe('OpenAI/Google/Codex handling', () => {
      it('should use inputTokens directly as contextWindow for OpenAI', () => {
        const source = createTokenSource('openai', 5000, 100);
        const result = normalizeTokens(source, 0, {
          turn: 1,
          sessionId: 'test',
          extractedAt: new Date().toISOString(),
          normalizedAt: new Date().toISOString(),
        });

        expect(result.computed.contextWindowTokens).toBe(5000);
        expect(result.source.rawInputTokens).toBe(5000);
      });

      it('should calculate simple delta for OpenAI', () => {
        const source = createTokenSource('openai', 6000, 100);
        const result = normalizeTokens(source, 5000, {
          turn: 2,
          sessionId: 'test',
          extractedAt: new Date().toISOString(),
          normalizedAt: new Date().toISOString(),
        });

        expect(result.computed.newInputTokens).toBe(1000);
        expect(result.computed.contextWindowTokens).toBe(6000);
      });
    });
  });
});

describe('Event Ordering and Timing', () => {
  // These tests verify the correct order of events and when token data is available

  it('should have token data available before first tool execution', () => {
    const tracker = new TurnContentTracker();
    tracker.onAgentStart();
    tracker.onTurnStart(1);

    // This simulates the response_complete event firing
    tracker.setResponseTokenUsage({
      inputTokens: 500,
      outputTokens: 100,
    });

    // Token data should be available NOW (before any tools)
    expect(tracker.getLastTurnTokenUsage()).toBeDefined();
    expect(tracker.getLastTokenRecord()).toBeDefined();

    // Now tools start
    tracker.registerToolIntents([{ id: 'tc_1', name: 'Read', arguments: {} }]);
    tracker.startToolCall('tc_1', 'Read', {}, new Date().toISOString());

    // Token data should still be the same
    expect(tracker.getLastTurnTokenUsage()?.inputTokens).toBe(500);
    expect(tracker.getLastTokenRecord()?.computed.newInputTokens).toBe(500);
  });

  it('should preserve token data through entire turn lifecycle', () => {
    const tracker = new TurnContentTracker();
    tracker.onAgentStart();
    tracker.onTurnStart(1);

    // Response complete
    tracker.setResponseTokenUsage({
      inputTokens: 604,
      outputTokens: 53,
      cacheReadTokens: 17332,
    });

    const expectedContext = 17936; // 604 + 17332

    // Before tools
    expect(tracker.getLastTokenRecord()?.computed.contextWindowTokens).toBe(expectedContext);

    // During tools
    tracker.registerToolIntents([{ id: 'tc_1', name: 'Read', arguments: {} }]);
    tracker.startToolCall('tc_1', 'Read', {}, new Date().toISOString());
    expect(tracker.getLastTokenRecord()?.computed.contextWindowTokens).toBe(expectedContext);

    // Pre-tool flush
    tracker.flushPreToolContent();
    expect(tracker.getLastTokenRecord()?.computed.contextWindowTokens).toBe(expectedContext);

    // Tool end
    tracker.endToolCall('tc_1', 'file contents', false, new Date().toISOString());
    expect(tracker.getLastTokenRecord()?.computed.contextWindowTokens).toBe(expectedContext);

    // Turn end
    tracker.onTurnEnd();
    expect(tracker.getLastTokenRecord()?.computed.contextWindowTokens).toBe(expectedContext);
  });
});

describe('iOS Reconstruction Compatibility', () => {
  // These tests ensure the data structure is correct for iOS to consume directly

  it('should produce TokenRecord with all required fields', () => {
    const tracker = new TurnContentTracker();
    tracker.setProviderType('anthropic');
    tracker.onAgentStart();
    tracker.onTurnStart(1);

    tracker.setResponseTokenUsage({
      inputTokens: 502,
      outputTokens: 53,
      cacheReadTokens: 17332,
      cacheCreationTokens: 0,
    });

    const tokenRecord = tracker.getLastTokenRecord();

    // All fields iOS needs should be present
    expect(tokenRecord).toHaveProperty('source');
    expect(tokenRecord).toHaveProperty('computed');
    expect(tokenRecord).toHaveProperty('meta');

    // Source fields
    expect(tokenRecord?.source.rawInputTokens).toBe(502);
    expect(tokenRecord?.source.rawOutputTokens).toBe(53);
    expect(tokenRecord?.source.rawCacheReadTokens).toBe(17332);
    expect(tokenRecord?.source.rawCacheCreationTokens).toBe(0);

    // Computed fields
    expect(tokenRecord?.computed.newInputTokens).toBe(17834); // 502 + 17332
    expect(tokenRecord?.computed.contextWindowTokens).toBe(17834);
  });

  it('should produce tokenUsage with all raw fields', () => {
    const tracker = new TurnContentTracker();
    tracker.onAgentStart();
    tracker.onTurnStart(1);

    tracker.setResponseTokenUsage({
      inputTokens: 500,
      outputTokens: 100,
      cacheReadTokens: 8000,
      cacheCreationTokens: 200,
    });

    const tokenUsage = tracker.getLastTurnTokenUsage();

    expect(tokenUsage?.inputTokens).toBe(500);
    expect(tokenUsage?.outputTokens).toBe(100);
    expect(tokenUsage?.cacheReadTokens).toBe(8000);
    expect(tokenUsage?.cacheCreationTokens).toBe(200);
  });
});
