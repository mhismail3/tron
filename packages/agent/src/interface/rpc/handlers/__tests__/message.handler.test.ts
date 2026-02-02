/**
 * @fileoverview Tests for Message RPC Handlers
 *
 * Tests message.delete handler using the registry dispatch pattern.
 */

import { describe, it, expect, vi, beforeEach } from 'vitest';
import { createMessageHandlers } from '../message.handler.js';
import type { RpcRequest } from '../../types.js';
import type { RpcContext } from '../../handler.js';
import { MethodRegistry } from '../../registry.js';

describe('Message Handlers', () => {
  let registry: MethodRegistry;
  let mockContext: RpcContext;
  let mockContextWithoutEventStore: RpcContext;

  beforeEach(() => {
    registry = new MethodRegistry();
    registry.registerAll(createMessageHandlers());

    mockContext = {
      eventStore: {
        deleteMessage: vi.fn(),
      },
    } as unknown as RpcContext;

    mockContextWithoutEventStore = {} as RpcContext;
  });

  describe('message.delete', () => {
    it('should return error when sessionId is missing', async () => {
      const request: RpcRequest = {
        id: '1',
        method: 'message.delete',
        params: { targetEventId: 'event-123' },
      };

      const response = await registry.dispatch(request, mockContext);

      expect(response.success).toBe(false);
      expect(response.error?.code).toBe('INVALID_PARAMS');
      expect(response.error?.message).toContain('sessionId');
    });

    it('should return error when targetEventId is missing', async () => {
      const request: RpcRequest = {
        id: '1',
        method: 'message.delete',
        params: { sessionId: 'session-123' },
      };

      const response = await registry.dispatch(request, mockContext);

      expect(response.success).toBe(false);
      expect(response.error?.code).toBe('INVALID_PARAMS');
      expect(response.error?.message).toContain('targetEventId');
    });

    it('should return NOT_AVAILABLE when eventStore is not available', async () => {
      const request: RpcRequest = {
        id: '1',
        method: 'message.delete',
        params: { sessionId: 'session-123', targetEventId: 'event-123' },
      };

      const response = await registry.dispatch(request, mockContextWithoutEventStore);

      expect(response.success).toBe(false);
      expect(response.error?.code).toBe('NOT_AVAILABLE');
    });

    it('should delete message successfully', async () => {
      const request: RpcRequest = {
        id: '1',
        method: 'message.delete',
        params: {
          sessionId: 'session-123',
          targetEventId: 'event-123',
          reason: 'test deletion',
        },
      };

      const mockDeletionEvent = {
        id: 'deletion-event-456',
        payload: { targetType: 'message.user' },
      };
      vi.mocked(mockContext.eventStore!.deleteMessage).mockResolvedValue(mockDeletionEvent);

      const response = await registry.dispatch(request, mockContext);

      expect(response.success).toBe(true);
      expect(response.result).toEqual({
        success: true,
        deletionEventId: 'deletion-event-456',
        targetType: 'message.user',
      });
      expect(mockContext.eventStore!.deleteMessage).toHaveBeenCalledWith(
        'session-123',
        'event-123',
        'test deletion'
      );
    });

    it('should handle NOT_FOUND error', async () => {
      const request: RpcRequest = {
        id: '1',
        method: 'message.delete',
        params: { sessionId: 'session-123', targetEventId: 'event-123' },
      };

      vi.mocked(mockContext.eventStore!.deleteMessage).mockRejectedValue(
        new Error('Event not found')
      );

      const response = await registry.dispatch(request, mockContext);

      expect(response.success).toBe(false);
      expect(response.error?.code).toBe('NOT_FOUND');
    });

    it('should handle INVALID_OPERATION error', async () => {
      const request: RpcRequest = {
        id: '1',
        method: 'message.delete',
        params: { sessionId: 'session-123', targetEventId: 'event-123' },
      };

      vi.mocked(mockContext.eventStore!.deleteMessage).mockRejectedValue(
        new Error('Cannot delete this message')
      );

      const response = await registry.dispatch(request, mockContext);

      expect(response.success).toBe(false);
      expect(response.error?.code).toBe('INVALID_OPERATION');
    });

    it('should handle generic errors', async () => {
      const request: RpcRequest = {
        id: '1',
        method: 'message.delete',
        params: { sessionId: 'session-123', targetEventId: 'event-123' },
      };

      vi.mocked(mockContext.eventStore!.deleteMessage).mockRejectedValue(
        new Error('Database error')
      );

      const response = await registry.dispatch(request, mockContext);

      expect(response.success).toBe(false);
      expect(response.error?.code).toBe('MESSAGE_DELETE_FAILED');
    });
  });

  describe('createMessageHandlers', () => {
    it('should create handler registrations', () => {
      const registrations = createMessageHandlers();

      expect(registrations).toHaveLength(1);
      expect(registrations[0].method).toBe('message.delete');
      expect(registrations[0].options?.requiredParams).toContain('sessionId');
      expect(registrations[0].options?.requiredParams).toContain('targetEventId');
      expect(registrations[0].options?.requiredManagers).toContain('eventStore');
    });
  });
});
