/**
 * @fileoverview Tests for InputHistory class
 *
 * Tests for prompt history navigation with up/down arrows.
 */

import { describe, it, expect, beforeEach } from 'vitest';
import { InputHistory } from '../../src/input/input-history.js';

describe('InputHistory', () => {
  let history: InputHistory;

  beforeEach(() => {
    history = new InputHistory();
  });

  describe('basic history management', () => {
    it('should start with empty history', () => {
      expect(history.getHistory()).toEqual([]);
      expect(history.getIndex()).toBe(-1);
    });

    it('should add entries to history', () => {
      history.add('first prompt');
      expect(history.getHistory()).toEqual(['first prompt']);
    });

    it('should add multiple entries to history', () => {
      history.add('first');
      history.add('second');
      history.add('third');
      expect(history.getHistory()).toEqual(['first', 'second', 'third']);
    });

    it('should not add empty strings to history', () => {
      history.add('');
      history.add('   ');
      expect(history.getHistory()).toEqual([]);
    });

    it('should not add duplicates of the last entry', () => {
      history.add('same prompt');
      history.add('same prompt');
      expect(history.getHistory()).toEqual(['same prompt']);
    });

    it('should allow duplicate entries if not consecutive', () => {
      history.add('first');
      history.add('second');
      history.add('first');
      expect(history.getHistory()).toEqual(['first', 'second', 'first']);
    });
  });

  describe('history navigation', () => {
    it('should navigate up through history', () => {
      history.add('first');
      history.add('second');
      history.add('third');

      expect(history.navigateUp()).toBe('third');
      expect(history.getIndex()).toBe(2);

      expect(history.navigateUp()).toBe('second');
      expect(history.getIndex()).toBe(1);

      expect(history.navigateUp()).toBe('first');
      expect(history.getIndex()).toBe(0);
    });

    it('should stop at the beginning when navigating up', () => {
      history.add('only entry');

      history.navigateUp();
      history.navigateUp();
      history.navigateUp();

      expect(history.getCurrent()).toBe('only entry');
      expect(history.getIndex()).toBe(0);
    });

    it('should navigate down through history', () => {
      history.add('first');
      history.add('second');
      history.add('third');

      // Go to the top
      history.navigateUp();
      history.navigateUp();
      history.navigateUp();

      expect(history.getCurrent()).toBe('first');

      // Navigate down
      expect(history.navigateDown()).toBe('second');
      expect(history.navigateDown()).toBe('third');
    });

    it('should return null when navigating past end of history', () => {
      history.add('entry');

      history.navigateUp();
      expect(history.getCurrent()).toBe('entry');

      expect(history.navigateDown()).toBeNull();
      expect(history.getIndex()).toBe(-1);
    });

    it('should reset history index when adding new entry', () => {
      history.add('first');
      history.add('second');

      history.navigateUp();
      expect(history.getIndex()).toBe(1);

      history.add('third');
      expect(history.getIndex()).toBe(-1);
    });

    it('should return null for empty history', () => {
      expect(history.navigateUp()).toBeNull();
      expect(history.getCurrent()).toBeNull();
      expect(history.getIndex()).toBe(-1);
    });
  });

  describe('temporary input storage', () => {
    it('should save and restore temporary input', () => {
      history.add('old prompt');

      // Store the in-progress input before navigating
      history.setTemporary('new in-progress');
      history.navigateUp();

      expect(history.getCurrent()).toBe('old prompt');

      // Navigate back down should restore the in-progress input
      history.navigateDown();

      expect(history.getCurrent()).toBeNull();
      expect(history.getTemporary()).toBe('new in-progress');
    });

    it('should clear temporary input when adding to history', () => {
      history.setTemporary('temporary');
      history.add('submitted');

      expect(history.getTemporary()).toBe('');
    });
  });

  describe('max history limit', () => {
    it('should limit history to max entries', () => {
      const limitedHistory = new InputHistory({ maxEntries: 5 });

      for (let i = 0; i < 10; i++) {
        limitedHistory.add(`entry ${i}`);
      }

      expect(limitedHistory.getHistory()).toHaveLength(5);
      expect(limitedHistory.getHistory()[0]).toBe('entry 5');
      expect(limitedHistory.getHistory()[4]).toBe('entry 9');
    });

    it('should use default max history of 100', () => {
      for (let i = 0; i < 150; i++) {
        history.add(`entry ${i}`);
      }

      expect(history.getHistory()).toHaveLength(100);
    });
  });

  describe('clear history', () => {
    it('should clear all history', () => {
      history.add('first');
      history.add('second');

      history.clear();

      expect(history.getHistory()).toEqual([]);
      expect(history.getIndex()).toBe(-1);
    });
  });

  describe('reset navigation', () => {
    it('should reset navigation index to end', () => {
      history.add('first');
      history.add('second');

      history.navigateUp();
      history.navigateUp();

      expect(history.getIndex()).toBe(0);

      history.resetNavigation();

      expect(history.getIndex()).toBe(-1);
    });
  });
});
