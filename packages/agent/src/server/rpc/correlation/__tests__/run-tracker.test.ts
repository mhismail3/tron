/**
 * @fileoverview Tests for run ID correlation tracking
 *
 * TDD tests written before implementation.
 */

import { describe, it, expect, beforeEach, vi } from 'vitest';
import {
  RunTracker,
  createRunTracker,
  generateRunId,
  type RunInfo,
  type RunStatus,
} from '../run-tracker.js';

describe('generateRunId', () => {
  it('should generate a unique ID', () => {
    const id1 = generateRunId();
    const id2 = generateRunId();

    expect(id1).not.toBe(id2);
  });

  it('should generate IDs with run_ prefix', () => {
    const id = generateRunId();
    expect(id.startsWith('run_')).toBe(true);
  });

  it('should generate IDs of consistent length', () => {
    const id1 = generateRunId();
    const id2 = generateRunId();

    expect(id1.length).toBe(id2.length);
    expect(id1.length).toBeGreaterThan(10);
  });
});

describe('RunTracker', () => {
  let tracker: RunTracker;

  beforeEach(() => {
    tracker = createRunTracker();
  });

  describe('startRun', () => {
    it('should create a new run with pending status', () => {
      const runInfo = tracker.startRun('session-1', 'req-1');

      expect(runInfo.runId).toBeDefined();
      expect(runInfo.sessionId).toBe('session-1');
      expect(runInfo.clientRequestId).toBe('req-1');
      expect(runInfo.status).toBe('pending');
      expect(runInfo.startedAt).toBeDefined();
    });

    it('should return different run IDs for each call', () => {
      const run1 = tracker.startRun('session-1', 'req-1');
      const run2 = tracker.startRun('session-1', 'req-2');

      expect(run1.runId).not.toBe(run2.runId);
    });

    it('should work without clientRequestId', () => {
      const runInfo = tracker.startRun('session-1');

      expect(runInfo.runId).toBeDefined();
      expect(runInfo.clientRequestId).toBeUndefined();
    });

    it('should associate run with session', () => {
      tracker.startRun('session-1', 'req-1');

      const currentRun = tracker.getCurrentRun('session-1');
      expect(currentRun).toBeDefined();
    });
  });

  describe('getCurrentRun', () => {
    it('should return undefined for session with no runs', () => {
      const run = tracker.getCurrentRun('session-nonexistent');
      expect(run).toBeUndefined();
    });

    it('should return the most recent active run', () => {
      const run1 = tracker.startRun('session-1', 'req-1');
      tracker.completeRun(run1.runId);

      const run2 = tracker.startRun('session-1', 'req-2');

      const current = tracker.getCurrentRun('session-1');
      expect(current?.runId).toBe(run2.runId);
    });

    it('should return undefined after run is completed', () => {
      const run = tracker.startRun('session-1', 'req-1');
      tracker.completeRun(run.runId);

      // No active run after completion
      const current = tracker.getCurrentRun('session-1');
      expect(current).toBeUndefined();
    });
  });

  describe('getRun', () => {
    it('should return run info by ID', () => {
      const created = tracker.startRun('session-1', 'req-1');
      const retrieved = tracker.getRun(created.runId);

      expect(retrieved).toBeDefined();
      expect(retrieved?.runId).toBe(created.runId);
      expect(retrieved?.sessionId).toBe('session-1');
    });

    it('should return undefined for non-existent run', () => {
      const run = tracker.getRun('run_nonexistent');
      expect(run).toBeUndefined();
    });
  });

  describe('updateRunStatus', () => {
    it('should update run status to running', () => {
      const run = tracker.startRun('session-1', 'req-1');
      tracker.updateRunStatus(run.runId, 'running');

      const updated = tracker.getRun(run.runId);
      expect(updated?.status).toBe('running');
    });

    it('should return false for non-existent run', () => {
      const result = tracker.updateRunStatus('run_nonexistent', 'running');
      expect(result).toBe(false);
    });

    it('should return true on successful update', () => {
      const run = tracker.startRun('session-1', 'req-1');
      const result = tracker.updateRunStatus(run.runId, 'running');
      expect(result).toBe(true);
    });
  });

  describe('completeRun', () => {
    it('should mark run as completed', () => {
      const run = tracker.startRun('session-1', 'req-1');
      tracker.completeRun(run.runId);

      const completed = tracker.getRun(run.runId);
      expect(completed?.status).toBe('completed');
      expect(completed?.completedAt).toBeDefined();
    });

    it('should include result if provided', () => {
      const run = tracker.startRun('session-1', 'req-1');
      tracker.completeRun(run.runId, { turns: 3, tokenUsage: { input: 100, output: 50 } });

      const completed = tracker.getRun(run.runId);
      expect(completed?.result).toEqual({ turns: 3, tokenUsage: { input: 100, output: 50 } });
    });
  });

  describe('failRun', () => {
    it('should mark run as failed', () => {
      const run = tracker.startRun('session-1', 'req-1');
      tracker.failRun(run.runId, 'Something went wrong');

      const failed = tracker.getRun(run.runId);
      expect(failed?.status).toBe('failed');
      expect(failed?.error).toBe('Something went wrong');
      expect(failed?.completedAt).toBeDefined();
    });
  });

  describe('abortRun', () => {
    it('should mark run as aborted', () => {
      const run = tracker.startRun('session-1', 'req-1');
      tracker.abortRun(run.runId);

      const aborted = tracker.getRun(run.runId);
      expect(aborted?.status).toBe('aborted');
      expect(aborted?.completedAt).toBeDefined();
    });
  });

  describe('getRunsBySession', () => {
    it('should return all runs for a session', () => {
      tracker.startRun('session-1', 'req-1');
      tracker.startRun('session-1', 'req-2');
      tracker.startRun('session-2', 'req-3');

      const runs = tracker.getRunsBySession('session-1');
      expect(runs).toHaveLength(2);
    });

    it('should return empty array for session with no runs', () => {
      const runs = tracker.getRunsBySession('session-nonexistent');
      expect(runs).toHaveLength(0);
    });

    it('should respect limit parameter', () => {
      tracker.startRun('session-1', 'req-1');
      tracker.startRun('session-1', 'req-2');
      tracker.startRun('session-1', 'req-3');

      const runs = tracker.getRunsBySession('session-1', { limit: 2 });
      expect(runs).toHaveLength(2);
    });

    it('should return most recent runs first', () => {
      const run1 = tracker.startRun('session-1', 'req-1');
      const run2 = tracker.startRun('session-1', 'req-2');

      const runs = tracker.getRunsBySession('session-1');
      expect(runs[0].runId).toBe(run2.runId);
      expect(runs[1].runId).toBe(run1.runId);
    });
  });

  describe('cleanup', () => {
    it('should remove old completed runs', () => {
      vi.useFakeTimers();

      const run = tracker.startRun('session-1', 'req-1');
      tracker.completeRun(run.runId);

      // Advance time past retention period
      vi.advanceTimersByTime(25 * 60 * 60 * 1000); // 25 hours

      tracker.cleanup();

      const retrieved = tracker.getRun(run.runId);
      expect(retrieved).toBeUndefined();

      vi.useRealTimers();
    });

    it('should not remove active runs', () => {
      vi.useFakeTimers();

      const run = tracker.startRun('session-1', 'req-1');

      // Advance time
      vi.advanceTimersByTime(25 * 60 * 60 * 1000);

      tracker.cleanup();

      const retrieved = tracker.getRun(run.runId);
      expect(retrieved).toBeDefined();

      vi.useRealTimers();
    });
  });

  describe('stats', () => {
    it('should return run statistics', () => {
      tracker.startRun('session-1', 'req-1');
      const run2 = tracker.startRun('session-1', 'req-2');
      tracker.completeRun(run2.runId);
      const run3 = tracker.startRun('session-2', 'req-3');
      tracker.failRun(run3.runId, 'error');

      const stats = tracker.stats();

      expect(stats.totalRuns).toBe(3);
      expect(stats.activeRuns).toBe(1);
      expect(stats.completedRuns).toBe(1);
      expect(stats.failedRuns).toBe(1);
    });
  });
});

describe('RunInfo type', () => {
  it('should have all required fields', () => {
    const tracker = createRunTracker();
    const run = tracker.startRun('session-1', 'req-1');

    // Type check - all these fields should exist
    const _runId: string = run.runId;
    const _sessionId: string = run.sessionId;
    const _status: RunStatus = run.status;
    const _startedAt: string = run.startedAt;
    const _clientRequestId: string | undefined = run.clientRequestId;

    expect(_runId).toBeDefined();
    expect(_sessionId).toBeDefined();
    expect(_status).toBeDefined();
    expect(_startedAt).toBeDefined();
  });
});
