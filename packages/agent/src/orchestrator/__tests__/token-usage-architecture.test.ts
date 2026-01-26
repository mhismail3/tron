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
 * 2. normalizedUsage is computed immediately when response_complete is received
 * 3. message.assistant events ALWAYS include tokenUsage and normalizedUsage
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

import { describe, it, expect, beforeEach, vi } from 'vitest';
import { TurnContentTracker } from '../turn/turn-content-tracker.js';
import { normalizeTokenUsage } from '../../providers/token-normalizer.js';
import type { ProviderType } from '../../types/messages.js';

describe('Token Usage Architecture', () => {
  describe('TurnContentTracker - Early Token Capture', () => {
    let tracker: TurnContentTracker;

    beforeEach(() => {
      tracker = new TurnContentTracker();
    });

    describe('setResponseTokenUsage (new method)', () => {
      it('should compute normalizedUsage immediately when token usage is set', () => {
        tracker.onAgentStart();
        tracker.onTurnStart(1);

        // Simulate response_complete: set token usage BEFORE tools execute
        tracker.setResponseTokenUsage({
          inputTokens: 500,
          outputTokens: 100,
          cacheCreationTokens: 8000,
        });

        // normalizedUsage should be available immediately
        const normalized = tracker.getLastNormalizedUsage();
        expect(normalized).toBeDefined();
        expect(normalized?.newInputTokens).toBe(8500); // First turn: all context is new
        expect(normalized?.contextWindowTokens).toBe(8500); // 500 + 8000
        expect(normalized?.outputTokens).toBe(100);
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
        const normalizedUsage = tracker.getLastNormalizedUsage();

        expect(tokenUsage).toBeDefined();
        expect(tokenUsage?.inputTokens).toBe(604);
        expect(normalizedUsage).toBeDefined();
        expect(normalizedUsage?.newInputTokens).toBe(17936); // 604 + 17332 (first turn)
        expect(normalizedUsage?.contextWindowTokens).toBe(17936);
      });

      it('should update baseline for subsequent turns', () => {
        tracker.onAgentStart();

        // Turn 1
        tracker.onTurnStart(1);
        tracker.setResponseTokenUsage({
          inputTokens: 500,
          outputTokens: 100,
          cacheCreationTokens: 8000,
        });
        tracker.onTurnEnd(); // This should NOT re-compute (already done)

        // Turn 2
        tracker.onTurnStart(2);
        tracker.setResponseTokenUsage({
          inputTokens: 604,
          outputTokens: 50,
          cacheReadTokens: 8000,
        });

        const normalized = tracker.getLastNormalizedUsage();
        expect(normalized?.newInputTokens).toBe(104); // 8604 - 8500
        expect(normalized?.contextWindowTokens).toBe(8604); // 604 + 8000
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
        const normalizedUsage = tracker.getLastNormalizedUsage();

        expect(tokenUsage).toBeDefined();
        expect(normalizedUsage).toBeDefined();
        expect(tokenUsage?.inputTokens).toBe(500);
        expect(normalizedUsage?.newInputTokens).toBe(500);
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
        const normalizedUsage = tracker.getLastNormalizedUsage();

        expect(flushed).not.toBeNull();
        expect(tokenUsage).toBeDefined();
        expect(normalizedUsage).toBeDefined();

        // These values should be correct for Anthropic
        expect(tokenUsage?.inputTokens).toBe(604);
        expect(tokenUsage?.cacheReadTokens).toBe(17332);
        expect(normalizedUsage?.contextWindowTokens).toBe(17936); // 604 + 17332
        expect(normalizedUsage?.newInputTokens).toBe(17936); // First turn
      });
    });

    describe('Provider-specific normalization', () => {
      it('should handle Anthropic semantics (inputTokens excludes cache)', () => {
        tracker.setProviderType('anthropic');
        tracker.onAgentStart();
        tracker.onTurnStart(1);

        tracker.setResponseTokenUsage({
          inputTokens: 502,    // Non-cached only
          outputTokens: 53,
          cacheReadTokens: 17332,  // Cached system prompt
        });

        const normalized = tracker.getLastNormalizedUsage();
        // contextWindow = inputTokens + cacheRead + cacheCreate
        expect(normalized?.contextWindowTokens).toBe(17834); // 502 + 17332
        expect(normalized?.rawInputTokens).toBe(502);
        expect(normalized?.cacheReadTokens).toBe(17332);
      });

      it('should handle OpenAI semantics (inputTokens is full context)', () => {
        tracker.setProviderType('openai');
        tracker.onAgentStart();

        // Turn 1
        tracker.onTurnStart(1);
        tracker.setResponseTokenUsage({
          inputTokens: 5000,  // FULL context
          outputTokens: 100,
        });
        tracker.onTurnEnd();

        // Turn 2
        tracker.onTurnStart(2);
        tracker.setResponseTokenUsage({
          inputTokens: 6000,  // Context grew
          outputTokens: 150,
        });

        const normalized = tracker.getLastNormalizedUsage();
        // For OpenAI, contextWindow = inputTokens (no cache adjustment)
        expect(normalized?.contextWindowTokens).toBe(6000);
        expect(normalized?.newInputTokens).toBe(1000); // 6000 - 5000
      });

      it('should handle Google semantics (same as OpenAI)', () => {
        tracker.setProviderType('google');
        tracker.onAgentStart();
        tracker.onTurnStart(1);

        tracker.setResponseTokenUsage({
          inputTokens: 8000,
          outputTokens: 200,
        });

        const normalized = tracker.getLastNormalizedUsage();
        expect(normalized?.contextWindowTokens).toBe(8000);
        expect(normalized?.newInputTokens).toBe(8000); // First turn
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

        const normalized = tracker.getLastNormalizedUsage();
        // Baseline reset to 0 on provider change
        expect(normalized?.newInputTokens).toBe(5000); // All new (baseline was reset)
      });
    });

    describe('Context delta accuracy', () => {
      it('should calculate accurate deltas across multi-turn sessions', () => {
        tracker.setProviderType('anthropic');
        tracker.onAgentStart();

        // Turn 1: Initial context
        tracker.onTurnStart(1);
        tracker.setResponseTokenUsage({
          inputTokens: 500,
          outputTokens: 100,
          cacheCreationTokens: 8000,
        });
        expect(tracker.getLastNormalizedUsage()?.newInputTokens).toBe(8500);
        expect(tracker.getLastNormalizedUsage()?.contextWindowTokens).toBe(8500);
        tracker.onTurnEnd();

        // Turn 2: Context grew by user message + assistant response
        tracker.onTurnStart(2);
        tracker.setResponseTokenUsage({
          inputTokens: 800,  // Grew by 300 (user + prev assistant)
          outputTokens: 150,
          cacheReadTokens: 8000,  // System prompt from cache
        });
        expect(tracker.getLastNormalizedUsage()?.newInputTokens).toBe(300); // 8800 - 8500
        expect(tracker.getLastNormalizedUsage()?.contextWindowTokens).toBe(8800);
        tracker.onTurnEnd();

        // Turn 3: More growth
        tracker.onTurnStart(3);
        tracker.setResponseTokenUsage({
          inputTokens: 1200,
          outputTokens: 200,
          cacheReadTokens: 8000,
        });
        expect(tracker.getLastNormalizedUsage()?.newInputTokens).toBe(400); // 9200 - 8800
        expect(tracker.getLastNormalizedUsage()?.contextWindowTokens).toBe(9200);
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
          inputTokens: 10000,  // Shrank from 50000
          outputTokens: 100,
        });

        const normalized = tracker.getLastNormalizedUsage();
        // Should report 0, not negative
        expect(normalized?.newInputTokens).toBe(0);
        expect(normalized?.contextWindowTokens).toBe(10000);
      });
    });

    describe('onTurnEnd should not re-compute if already set', () => {
      it('should preserve normalizedUsage from setResponseTokenUsage', () => {
        tracker.onAgentStart();
        tracker.onTurnStart(1);

        // Set token usage early (response complete)
        tracker.setResponseTokenUsage({
          inputTokens: 500,
          outputTokens: 100,
        });

        const beforeEnd = tracker.getLastNormalizedUsage();
        expect(beforeEnd?.newInputTokens).toBe(500);

        // End turn (should NOT overwrite)
        tracker.onTurnEnd();

        const afterEnd = tracker.getLastNormalizedUsage();
        expect(afterEnd?.newInputTokens).toBe(500);
      });
    });
  });

  describe('normalizeTokenUsage function', () => {
    // These tests ensure the core normalization logic is correct

    describe('first turn behavior', () => {
      it('should treat entire context as new on first turn (previousContextSize = 0)', () => {
        const providers: ProviderType[] = ['anthropic', 'openai', 'openai-codex', 'google'];

        for (const provider of providers) {
          const result = normalizeTokenUsage(
            { inputTokens: 5000, outputTokens: 100 },
            provider,
            0
          );
          expect(result.newInputTokens).toBe(5000);
        }
      });
    });

    describe('Anthropic cache handling', () => {
      it('should add cache tokens to context window', () => {
        const result = normalizeTokenUsage(
          { inputTokens: 500, outputTokens: 100, cacheReadTokens: 8000, cacheCreationTokens: 200 },
          'anthropic',
          0
        );

        expect(result.contextWindowTokens).toBe(8700); // 500 + 8000 + 200
        expect(result.rawInputTokens).toBe(500);
        expect(result.cacheReadTokens).toBe(8000);
        expect(result.cacheCreationTokens).toBe(200);
      });

      it('should calculate delta from contextWindowTokens for Anthropic', () => {
        // Previous context was 8500 (500 input + 8000 cache)
        const result = normalizeTokenUsage(
          { inputTokens: 604, outputTokens: 100, cacheReadTokens: 8000 },
          'anthropic',
          8500
        );

        // New context is 8604, delta is 104
        expect(result.newInputTokens).toBe(104);
        expect(result.contextWindowTokens).toBe(8604);
      });
    });

    describe('OpenAI/Google/Codex handling', () => {
      it('should use inputTokens directly as contextWindow for OpenAI', () => {
        const result = normalizeTokenUsage(
          { inputTokens: 5000, outputTokens: 100 },
          'openai',
          0
        );

        expect(result.contextWindowTokens).toBe(5000);
        expect(result.rawInputTokens).toBe(5000);
      });

      it('should calculate simple delta for OpenAI', () => {
        const result = normalizeTokenUsage(
          { inputTokens: 6000, outputTokens: 100 },
          'openai',
          5000
        );

        expect(result.newInputTokens).toBe(1000);
        expect(result.contextWindowTokens).toBe(6000);
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
    expect(tracker.getLastNormalizedUsage()).toBeDefined();

    // Now tools start
    tracker.registerToolIntents([
      { id: 'tc_1', name: 'Read', arguments: {} },
    ]);
    tracker.startToolCall('tc_1', 'Read', {}, new Date().toISOString());

    // Token data should still be the same
    expect(tracker.getLastTurnTokenUsage()?.inputTokens).toBe(500);
    expect(tracker.getLastNormalizedUsage()?.newInputTokens).toBe(500);
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
    expect(tracker.getLastNormalizedUsage()?.contextWindowTokens).toBe(expectedContext);

    // During tools
    tracker.registerToolIntents([{ id: 'tc_1', name: 'Read', arguments: {} }]);
    tracker.startToolCall('tc_1', 'Read', {}, new Date().toISOString());
    expect(tracker.getLastNormalizedUsage()?.contextWindowTokens).toBe(expectedContext);

    // Pre-tool flush
    tracker.flushPreToolContent();
    expect(tracker.getLastNormalizedUsage()?.contextWindowTokens).toBe(expectedContext);

    // Tool end
    tracker.endToolCall('tc_1', 'file contents', false, new Date().toISOString());
    expect(tracker.getLastNormalizedUsage()?.contextWindowTokens).toBe(expectedContext);

    // Turn end
    tracker.onTurnEnd();
    expect(tracker.getLastNormalizedUsage()?.contextWindowTokens).toBe(expectedContext);
  });
});

describe('iOS Reconstruction Compatibility', () => {
  // These tests ensure the data structure is correct for iOS to consume directly

  it('should produce normalizedUsage with all required fields', () => {
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

    const normalized = tracker.getLastNormalizedUsage();

    // All fields iOS needs should be present
    expect(normalized).toHaveProperty('newInputTokens');
    expect(normalized).toHaveProperty('outputTokens');
    expect(normalized).toHaveProperty('contextWindowTokens');
    expect(normalized).toHaveProperty('rawInputTokens');
    expect(normalized).toHaveProperty('cacheReadTokens');
    expect(normalized).toHaveProperty('cacheCreationTokens');

    // Values should be correct
    expect(normalized?.newInputTokens).toBe(17834); // 502 + 17332
    expect(normalized?.outputTokens).toBe(53);
    expect(normalized?.contextWindowTokens).toBe(17834);
    expect(normalized?.rawInputTokens).toBe(502);
    expect(normalized?.cacheReadTokens).toBe(17332);
    expect(normalized?.cacheCreationTokens).toBe(0);
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
