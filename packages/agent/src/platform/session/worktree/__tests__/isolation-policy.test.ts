/**
 * @fileoverview Isolation Policy Tests
 */
import { describe, it, expect, vi } from 'vitest';
import { IsolationPolicy, createIsolationPolicy } from '../isolation-policy.js';
import { SessionId } from '@infrastructure/events/types.js';

describe('IsolationPolicy', () => {
  describe('never mode', () => {
    it('should never isolate in never mode', () => {
      const policy = createIsolationPolicy({
        isolationMode: 'never',
        getMainDirectoryOwner: () => null,
      });

      const sessionId = SessionId('sess_test');
      expect(policy.shouldIsolate(sessionId)).toBe(false);
    });

    it('should not isolate even with forceIsolation in never mode', () => {
      const policy = createIsolationPolicy({
        isolationMode: 'never',
        getMainDirectoryOwner: () => null,
      });

      const sessionId = SessionId('sess_test');
      expect(policy.shouldIsolate(sessionId, { forceIsolation: true })).toBe(false);
    });

    it('should not isolate forked sessions in never mode', () => {
      const policy = createIsolationPolicy({
        isolationMode: 'never',
        getMainDirectoryOwner: () => null,
      });

      const sessionId = SessionId('sess_child');
      const parentId = SessionId('sess_parent');
      expect(policy.shouldIsolate(sessionId, { parentSessionId: parentId })).toBe(false);
    });
  });

  describe('always mode', () => {
    it('should always isolate in always mode', () => {
      const policy = createIsolationPolicy({
        isolationMode: 'always',
        getMainDirectoryOwner: () => null,
      });

      const sessionId = SessionId('sess_test');
      expect(policy.shouldIsolate(sessionId)).toBe(true);
    });

    it('should isolate first session in always mode', () => {
      const policy = createIsolationPolicy({
        isolationMode: 'always',
        getMainDirectoryOwner: () => null,
      });

      const sessionId = SessionId('sess_first');
      expect(policy.shouldIsolate(sessionId)).toBe(true);
    });
  });

  describe('lazy mode', () => {
    it('should not isolate first session when no owner', () => {
      const policy = createIsolationPolicy({
        isolationMode: 'lazy',
        getMainDirectoryOwner: () => null,
      });

      const sessionId = SessionId('sess_first');
      expect(policy.shouldIsolate(sessionId)).toBe(false);
    });

    it('should isolate when another session owns main directory', () => {
      const policy = createIsolationPolicy({
        isolationMode: 'lazy',
        getMainDirectoryOwner: () => 'sess_first',
      });

      const sessionId = SessionId('sess_second');
      expect(policy.shouldIsolate(sessionId)).toBe(true);
    });

    it('should not isolate when same session owns main directory', () => {
      const policy = createIsolationPolicy({
        isolationMode: 'lazy',
        getMainDirectoryOwner: () => 'sess_same',
      });

      const sessionId = SessionId('sess_same');
      expect(policy.shouldIsolate(sessionId)).toBe(false);
    });

    it('should isolate when forceIsolation is true', () => {
      const policy = createIsolationPolicy({
        isolationMode: 'lazy',
        getMainDirectoryOwner: () => null,
      });

      const sessionId = SessionId('sess_forced');
      expect(policy.shouldIsolate(sessionId, { forceIsolation: true })).toBe(true);
    });

    it('should isolate forked sessions', () => {
      const policy = createIsolationPolicy({
        isolationMode: 'lazy',
        getMainDirectoryOwner: () => null,
      });

      const sessionId = SessionId('sess_child');
      const parentId = SessionId('sess_parent');
      expect(policy.shouldIsolate(sessionId, { parentSessionId: parentId })).toBe(true);
    });
  });

  describe('getMode', () => {
    it('should return the current isolation mode', () => {
      const lazyPolicy = createIsolationPolicy({
        isolationMode: 'lazy',
        getMainDirectoryOwner: () => null,
      });
      expect(lazyPolicy.getMode()).toBe('lazy');

      const alwaysPolicy = createIsolationPolicy({
        isolationMode: 'always',
        getMainDirectoryOwner: () => null,
      });
      expect(alwaysPolicy.getMode()).toBe('always');

      const neverPolicy = createIsolationPolicy({
        isolationMode: 'never',
        getMainDirectoryOwner: () => null,
      });
      expect(neverPolicy.getMode()).toBe('never');
    });
  });

  describe('priority order', () => {
    it('should check never mode first', () => {
      const policy = createIsolationPolicy({
        isolationMode: 'never',
        getMainDirectoryOwner: () => 'other_session', // Would normally trigger isolation
      });

      const sessionId = SessionId('sess_test');
      // Despite another session owning main, never mode prevents isolation
      expect(policy.shouldIsolate(sessionId, {
        forceIsolation: true,
        parentSessionId: SessionId('parent')
      })).toBe(false);
    });

    it('should check always mode before lazy logic', () => {
      const policy = createIsolationPolicy({
        isolationMode: 'always',
        getMainDirectoryOwner: () => null, // No owner would normally skip isolation
      });

      const sessionId = SessionId('sess_first');
      // Despite being first session with no owner, always mode forces isolation
      expect(policy.shouldIsolate(sessionId)).toBe(true);
    });
  });
});
