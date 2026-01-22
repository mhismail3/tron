/**
 * @fileoverview Tests for Session Schemas
 */

import { describe, it, expect } from 'vitest';
import {
  sessionCreateSchema,
  sessionResumeSchema,
  sessionListSchema,
  sessionDeleteSchema,
  sessionForkSchema,
  createSessionSchemas,
} from '../session.js';

describe('Session Schemas', () => {
  describe('sessionCreateSchema', () => {
    it('should accept valid params', () => {
      const result = sessionCreateSchema.safeParse({
        workingDirectory: '/home/user/project',
      });
      expect(result.success).toBe(true);
    });

    it('should accept all optional params', () => {
      const result = sessionCreateSchema.safeParse({
        workingDirectory: '/home/user/project',
        initialModel: 'claude-3-5-sonnet-20241022',
        resumeIfExists: true,
        title: 'My Session',
        metadata: { key: 'value' },
      });
      expect(result.success).toBe(true);
    });

    it('should reject missing workingDirectory', () => {
      const result = sessionCreateSchema.safeParse({});
      expect(result.success).toBe(false);
      expect(result.error?.errors[0]?.path).toContain('workingDirectory');
    });

    it('should reject empty workingDirectory', () => {
      const result = sessionCreateSchema.safeParse({
        workingDirectory: '',
      });
      expect(result.success).toBe(false);
    });
  });

  describe('sessionResumeSchema', () => {
    it('should accept valid UUID sessionId', () => {
      const result = sessionResumeSchema.safeParse({
        sessionId: '123e4567-e89b-12d3-a456-426614174000',
      });
      expect(result.success).toBe(true);
    });

    it('should reject invalid sessionId', () => {
      const result = sessionResumeSchema.safeParse({
        sessionId: 'not-a-uuid',
      });
      expect(result.success).toBe(false);
    });

    it('should reject missing sessionId', () => {
      const result = sessionResumeSchema.safeParse({});
      expect(result.success).toBe(false);
    });
  });

  describe('sessionListSchema', () => {
    it('should accept empty params', () => {
      const result = sessionListSchema.safeParse({});
      expect(result.success).toBe(true);
    });

    it('should accept undefined params', () => {
      const result = sessionListSchema.safeParse(undefined);
      expect(result.success).toBe(true);
      expect(result.data).toEqual({});
    });

    it('should accept filter params', () => {
      const result = sessionListSchema.safeParse({
        workingDirectory: '/home/user/project',
        isActive: true,
        limit: 50,
        offset: 10,
      });
      expect(result.success).toBe(true);
    });

    it('should reject invalid limit', () => {
      const result = sessionListSchema.safeParse({
        limit: 0,
      });
      expect(result.success).toBe(false);
    });

    it('should reject negative offset', () => {
      const result = sessionListSchema.safeParse({
        offset: -1,
      });
      expect(result.success).toBe(false);
    });
  });

  describe('sessionDeleteSchema', () => {
    it('should accept valid UUID sessionId', () => {
      const result = sessionDeleteSchema.safeParse({
        sessionId: '123e4567-e89b-12d3-a456-426614174000',
      });
      expect(result.success).toBe(true);
    });

    it('should reject missing sessionId', () => {
      const result = sessionDeleteSchema.safeParse({});
      expect(result.success).toBe(false);
    });
  });

  describe('sessionForkSchema', () => {
    it('should accept sessionId only', () => {
      const result = sessionForkSchema.safeParse({
        sessionId: '123e4567-e89b-12d3-a456-426614174000',
      });
      expect(result.success).toBe(true);
    });

    it('should accept sessionId with fromEventId', () => {
      const result = sessionForkSchema.safeParse({
        sessionId: '123e4567-e89b-12d3-a456-426614174000',
        fromEventId: 'evt-123',
      });
      expect(result.success).toBe(true);
    });

    it('should reject missing sessionId', () => {
      const result = sessionForkSchema.safeParse({
        fromEventId: 'evt-123',
      });
      expect(result.success).toBe(false);
    });
  });

  describe('createSessionSchemas', () => {
    it('should create registry with all session methods', () => {
      const registry = createSessionSchemas();

      expect(registry.has('session.create')).toBe(true);
      expect(registry.has('session.resume')).toBe(true);
      expect(registry.has('session.list')).toBe(true);
      expect(registry.has('session.delete')).toBe(true);
      expect(registry.has('session.fork')).toBe(true);
      expect(registry.size).toBe(5);
    });
  });
});
