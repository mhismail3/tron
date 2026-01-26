/**
 * @fileoverview Tests for results-builder
 */
import { describe, it, expect, vi, beforeEach, type Mock } from 'vitest';
import { buildSubagentResultsContext } from '../results-builder.js';
import type { ActiveSession } from '../../../types.js';

describe('buildSubagentResultsContext', () => {
  let mockSession: ActiveSession;
  let hasPendingResults: Mock;
  let consumePendingResults: Mock;

  beforeEach(() => {
    hasPendingResults = vi.fn();
    consumePendingResults = vi.fn();

    mockSession = {
      subagentTracker: {
        hasPendingResults,
        consumePendingResults,
      },
    } as unknown as ActiveSession;
  });

  it('should return undefined when no pending results', () => {
    hasPendingResults.mockReturnValue(false);

    const result = buildSubagentResultsContext(mockSession);

    expect(result).toBeUndefined();
    expect(consumePendingResults).not.toHaveBeenCalled();
  });

  it('should return undefined when pending results array is empty', () => {
    hasPendingResults.mockReturnValue(true);
    consumePendingResults.mockReturnValue([]);

    const result = buildSubagentResultsContext(mockSession);

    expect(result).toBeUndefined();
  });

  it('should format successful result correctly', () => {
    hasPendingResults.mockReturnValue(true);
    consumePendingResults.mockReturnValue([
      {
        sessionId: 'sess_123',
        task: 'Test task',
        success: true,
        totalTurns: 5,
        duration: 3000,
        output: 'Task completed successfully',
      },
    ]);

    const result = buildSubagentResultsContext(mockSession);

    expect(result).toBeDefined();
    expect(result).toContain('# Completed Sub-Agent Results');
    expect(result).toContain('✅ Sub-Agent: `sess_123`');
    expect(result).toContain('**Task**: Test task');
    expect(result).toContain('**Status**: Completed successfully');
    expect(result).toContain('**Turns**: 5');
    expect(result).toContain('**Duration**: 3.0s');
    expect(result).toContain('Task completed successfully');
  });

  it('should format failed result correctly', () => {
    hasPendingResults.mockReturnValue(true);
    consumePendingResults.mockReturnValue([
      {
        sessionId: 'sess_456',
        task: 'Failed task',
        success: false,
        totalTurns: 2,
        duration: 1500,
        error: 'Something went wrong',
      },
    ]);

    const result = buildSubagentResultsContext(mockSession);

    expect(result).toBeDefined();
    expect(result).toContain('❌ Sub-Agent: `sess_456`');
    expect(result).toContain('**Status**: Failed');
    expect(result).toContain('**Error**: Something went wrong');
  });

  it('should truncate long outputs', () => {
    const longOutput = 'x'.repeat(3000);
    hasPendingResults.mockReturnValue(true);
    consumePendingResults.mockReturnValue([
      {
        sessionId: 'sess_789',
        task: 'Long output task',
        success: true,
        totalTurns: 10,
        duration: 5000,
        output: longOutput,
      },
    ]);

    const result = buildSubagentResultsContext(mockSession);

    expect(result).toBeDefined();
    expect(result).toContain('[Output truncated. Use QuerySubagent for full output]');
    expect(result!.length).toBeLessThan(longOutput.length);
  });

  it('should format multiple results', () => {
    hasPendingResults.mockReturnValue(true);
    consumePendingResults.mockReturnValue([
      {
        sessionId: 'sess_1',
        task: 'Task 1',
        success: true,
        totalTurns: 3,
        duration: 2000,
        output: 'Result 1',
      },
      {
        sessionId: 'sess_2',
        task: 'Task 2',
        success: false,
        totalTurns: 1,
        duration: 500,
        error: 'Error 2',
      },
    ]);

    const result = buildSubagentResultsContext(mockSession);

    expect(result).toBeDefined();
    expect(result).toContain('`sess_1`');
    expect(result).toContain('`sess_2`');
    expect(result).toContain('Task 1');
    expect(result).toContain('Task 2');
    expect(result).toContain('✅');
    expect(result).toContain('❌');
  });
});
