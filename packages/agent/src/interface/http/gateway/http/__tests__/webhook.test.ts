/**
 * @fileoverview Tests for webhook receiver
 */

import { describe, it, expect, beforeEach, vi } from 'vitest';
import {
  WebhookHandler,
  createWebhookHandler,
  type WebhookConfig,
  type WebhookContext,
} from '../webhook.js';

// Mock context
const createMockContext = (): WebhookContext => ({
  sendPrompt: vi.fn().mockResolvedValue({
    acknowledged: true,
    runId: 'run_abc123',
  }),
  getSessionByWorkspace: vi.fn().mockResolvedValue('session-123'),
  createSession: vi.fn().mockResolvedValue({
    sessionId: 'session-new',
    workspaceId: 'workspace-1',
  }),
});

describe('WebhookHandler', () => {
  let handler: WebhookHandler;
  let mockContext: WebhookContext;

  beforeEach(() => {
    mockContext = createMockContext();
    handler = createWebhookHandler({}, mockContext);
  });

  describe('handleTrigger', () => {
    it('should trigger a prompt for existing session', async () => {
      const result = await handler.handleTrigger({
        workspaceId: 'workspace-1',
        prompt: 'Run the tests',
      });

      expect(result.success).toBe(true);
      expect(result.sessionId).toBe('session-123');
      expect(result.runId).toBe('run_abc123');
      expect(mockContext.sendPrompt).toHaveBeenCalledWith('session-123', {
        prompt: 'Run the tests',
      });
    });

    it('should create a session if none exists', async () => {
      mockContext.getSessionByWorkspace = vi.fn().mockResolvedValue(null);

      const result = await handler.handleTrigger({
        workspaceId: 'workspace-1',
        workingDirectory: '/test/path',
        prompt: 'Initialize project',
      });

      expect(result.success).toBe(true);
      expect(mockContext.createSession).toHaveBeenCalledWith({
        workingDirectory: '/test/path',
        workspaceId: 'workspace-1',
      });
    });

    it('should return error if no session and no working directory', async () => {
      mockContext.getSessionByWorkspace = vi.fn().mockResolvedValue(null);

      const result = await handler.handleTrigger({
        workspaceId: 'workspace-1',
        prompt: 'Test',
      });

      expect(result.success).toBe(false);
      expect(result.error).toContain('workingDirectory');
    });

    it('should use explicit sessionId when provided', async () => {
      const result = await handler.handleTrigger({
        sessionId: 'explicit-session',
        prompt: 'Direct prompt',
      });

      expect(result.success).toBe(true);
      expect(mockContext.sendPrompt).toHaveBeenCalledWith('explicit-session', {
        prompt: 'Direct prompt',
      });
    });

    it('should pass optional fields', async () => {
      await handler.handleTrigger({
        workspaceId: 'workspace-1',
        prompt: 'Test',
        metadata: { source: 'ci', jobId: '123' },
        idempotencyKey: 'webhook-123',
      });

      expect(mockContext.sendPrompt).toHaveBeenCalledWith('session-123', {
        prompt: 'Test',
        idempotencyKey: 'webhook-123',
      });
    });
  });

  describe('signature verification', () => {
    it('should verify HMAC signature when configured', async () => {
      const securedHandler = createWebhookHandler(
        { secret: 'webhook-secret' },
        mockContext
      );

      // Valid signature
      const payload = JSON.stringify({ prompt: 'Test', sessionId: 'session-1' });
      const validSig = securedHandler.computeSignature(payload);

      const result = await securedHandler.handleRequest({
        body: payload,
        signature: validSig,
      });

      expect(result.success).toBe(true);
    });

    it('should reject invalid signature', async () => {
      const securedHandler = createWebhookHandler(
        { secret: 'webhook-secret' },
        mockContext
      );

      const result = await securedHandler.handleRequest({
        body: JSON.stringify({ prompt: 'Test', sessionId: 'session-1' }),
        signature: 'invalid-signature',
      });

      expect(result.success).toBe(false);
      expect(result.error).toContain('signature');
    });

    it('should reject missing signature when required', async () => {
      const securedHandler = createWebhookHandler(
        { secret: 'webhook-secret' },
        mockContext
      );

      const result = await securedHandler.handleRequest({
        body: JSON.stringify({ prompt: 'Test', sessionId: 'session-1' }),
      });

      expect(result.success).toBe(false);
      expect(result.error).toContain('signature');
    });

    it('should allow requests without signature when no secret configured', async () => {
      const result = await handler.handleRequest({
        body: JSON.stringify({ prompt: 'Test', sessionId: 'session-1' }),
      });

      expect(result.success).toBe(true);
    });
  });

  describe('rate limiting', () => {
    it('should track requests by source', async () => {
      const limitedHandler = createWebhookHandler(
        { rateLimit: { maxRequests: 2, windowMs: 60000 } },
        mockContext
      );

      // First two requests should succeed
      await limitedHandler.handleTrigger({
        sessionId: 'session-1',
        prompt: 'Test 1',
        metadata: { source: 'test' },
      });

      await limitedHandler.handleTrigger({
        sessionId: 'session-1',
        prompt: 'Test 2',
        metadata: { source: 'test' },
      });

      // Third should be rate limited
      const result = await limitedHandler.handleTrigger({
        sessionId: 'session-1',
        prompt: 'Test 3',
        metadata: { source: 'test' },
      });

      expect(result.success).toBe(false);
      expect(result.error).toContain('Rate limit');
    });
  });

  describe('error handling', () => {
    it('should handle JSON parse errors', async () => {
      const result = await handler.handleRequest({
        body: 'not valid json',
      });

      expect(result.success).toBe(false);
      expect(result.error).toContain('JSON');
    });

    it('should handle missing prompt', async () => {
      const result = await handler.handleRequest({
        body: JSON.stringify({ sessionId: 'session-1' }),
      });

      expect(result.success).toBe(false);
      expect(result.error).toContain('prompt');
    });

    it('should handle context errors gracefully', async () => {
      mockContext.sendPrompt = vi.fn().mockRejectedValue(new Error('Session busy'));

      const result = await handler.handleTrigger({
        sessionId: 'session-1',
        prompt: 'Test',
      });

      expect(result.success).toBe(false);
      expect(result.error).toContain('Session busy');
    });
  });
});
