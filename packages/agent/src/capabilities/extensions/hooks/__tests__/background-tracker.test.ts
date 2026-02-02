/**
 * @fileoverview Tests for BackgroundTracker
 *
 * TDD: Tests for background hook execution tracking
 */

import { describe, it, expect, beforeEach, vi, afterEach } from 'vitest';
import { BackgroundTracker } from '../background-tracker.js';

describe('BackgroundTracker', () => {
  let tracker: BackgroundTracker;

  beforeEach(() => {
    vi.useFakeTimers();
    tracker = new BackgroundTracker();
  });

  afterEach(() => {
    vi.useRealTimers();
  });

  describe('track', () => {
    it('tracks a pending promise', () => {
      const promise = new Promise<void>(() => {}); // never resolves
      tracker.track('exec_1', promise);

      expect(tracker.getPendingCount()).toBe(1);
    });

    it('tracks multiple promises', () => {
      tracker.track('exec_1', new Promise<void>(() => {}));
      tracker.track('exec_2', new Promise<void>(() => {}));
      tracker.track('exec_3', new Promise<void>(() => {}));

      expect(tracker.getPendingCount()).toBe(3);
    });
  });

  describe('automatic cleanup', () => {
    it('removes promise when resolved', async () => {
      let resolve: () => void;
      const promise = new Promise<void>((r) => { resolve = r; });

      tracker.track('exec_1', promise);
      expect(tracker.getPendingCount()).toBe(1);

      resolve!();
      await promise;

      // Need to yield to allow finally() to run
      await vi.runAllTimersAsync();

      expect(tracker.getPendingCount()).toBe(0);
    });

    it('removes promise when rejected', async () => {
      // Create a promise that will reject, with pre-attached catch to prevent unhandled rejection
      let reject: (err: Error) => void;
      const promise = new Promise<void>((_, r) => { reject = r; });

      // Track the original promise but also keep a reference that won't throw
      tracker.track('exec_1', promise.catch(() => {}));
      expect(tracker.getPendingCount()).toBe(1);

      reject!(new Error('test'));

      await vi.runAllTimersAsync();

      expect(tracker.getPendingCount()).toBe(0);
    });
  });

  describe('waitForAll', () => {
    it('resolves immediately when no pending hooks', async () => {
      await expect(tracker.waitForAll(1000)).resolves.toBeUndefined();
    });

    it('resolves when all pending complete', async () => {
      let resolve1: () => void;
      let resolve2: () => void;
      const p1 = new Promise<void>((r) => { resolve1 = r; });
      const p2 = new Promise<void>((r) => { resolve2 = r; });

      tracker.track('exec_1', p1);
      tracker.track('exec_2', p2);

      const waitPromise = tracker.waitForAll(5000);

      resolve1!();
      resolve2!();

      await vi.runAllTimersAsync();

      await expect(waitPromise).resolves.toBeUndefined();
    });

    it('times out if hooks do not complete', async () => {
      const neverResolves = new Promise<void>(() => {});
      tracker.track('exec_1', neverResolves);

      const waitPromise = tracker.waitForAll(100);

      // Advance past timeout
      await vi.advanceTimersByTimeAsync(150);

      // Should resolve (not reject) due to race with timeout
      await expect(waitPromise).resolves.toBeUndefined();

      // Hook is still pending
      expect(tracker.getPendingCount()).toBe(1);
    });
  });

  describe('generateExecutionId', () => {
    it('generates unique IDs', () => {
      const id1 = tracker.generateExecutionId();
      const id2 = tracker.generateExecutionId();
      const id3 = tracker.generateExecutionId();

      expect(id1).not.toBe(id2);
      expect(id2).not.toBe(id3);
      expect(id1).toMatch(/^bg_\d+_\d+$/);
    });

    it('increments counter for each call', () => {
      const id1 = tracker.generateExecutionId();
      const id2 = tracker.generateExecutionId();

      // Extract counter from ID (format: bg_<counter>_<timestamp>)
      const counter1 = parseInt(id1.split('_')[1], 10);
      const counter2 = parseInt(id2.split('_')[1], 10);

      expect(counter2).toBe(counter1 + 1);
    });
  });

  describe('getPendingCount', () => {
    it('returns 0 for empty tracker', () => {
      expect(tracker.getPendingCount()).toBe(0);
    });

    it('reflects current pending count', () => {
      tracker.track('exec_1', new Promise<void>(() => {}));
      expect(tracker.getPendingCount()).toBe(1);

      tracker.track('exec_2', new Promise<void>(() => {}));
      expect(tracker.getPendingCount()).toBe(2);
    });
  });
});
