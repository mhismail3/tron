/**
 * Tests for message.handler.ts
 */

import { describe, it, expect, vi, beforeEach } from 'vitest';
import {
  handleMessageDelete,
  createMessageHandlers,
} from '../message.handler.js';
import type { RpcRequest, RpcResponse } from '../../types.js';
import type { RpcContext } from '../../handler.js';

describe('message.handler', () => {
  let mockContext: RpcContext;

  beforeEach(() => {
    mockContext = {
      eventStore: {
        deleteMessage: vi.fn(),
      },
    } as unknown as RpcContext;
  });

  describe('handleMessageDelete', () => {
    it('should return error when sessionId is missing', async () => {
      const request: RpcRequest = {
        id: '1',
        method: 'message.delete',
        params: { targetEventId: 'event-123' },
      };

      const response = await handleMessageDelete(request, mockContext);

      expect(response.success).toBe(false);
      expect(response.error?.code).toBe('INVALID_PARAMS');
      expect(response.error?.message).toBe('sessionId is required');
    });

    it('should return error when targetEventId is missing', async () => {
      const request: RpcRequest = {
        id: '1',
        method: 'message.delete',
        params: { sessionId: 'session-123' },
      };

      const response = await handleMessageDelete(request, mockContext);

      expect(response.success).toBe(false);
      expect(response.error?.code).toBe('INVALID_PARAMS');
      expect(response.error?.message).toBe('targetEventId is required');
    });

    it('should return error when eventStore is not available', async () => {
      const request: RpcRequest = {
        id: '1',
        method: 'message.delete',
        params: { sessionId: 'session-123', targetEventId: 'event-123' },
      };

      const contextWithoutEventStore = {} as RpcContext;
      const response = await handleMessageDelete(request, contextWithoutEventStore);

      expect(response.success).toBe(false);
      expect(response.error?.code).toBe('NOT_SUPPORTED');
      expect(response.error?.message).toBe('Event store not available');
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

      const response = await handleMessageDelete(request, mockContext);

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

      const response = await handleMessageDelete(request, mockContext);

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

      const response = await handleMessageDelete(request, mockContext);

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

      const response = await handleMessageDelete(request, mockContext);

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

    it('should create handler that returns result on success', async () => {
      const registrations = createMessageHandlers();
      const handler = registrations[0].handler;

      const mockDeletionEvent = {
        id: 'deletion-event-456',
        payload: { targetType: 'message.assistant' },
      };
      vi.mocked(mockContext.eventStore!.deleteMessage).mockResolvedValue(mockDeletionEvent);

      const request: RpcRequest = {
        id: '1',
        method: 'message.delete',
        params: { sessionId: 'session-123', targetEventId: 'event-123' },
      };

      const result = await handler(request, mockContext);

      expect(result).toEqual({
        success: true,
        deletionEventId: 'deletion-event-456',
        targetType: 'message.assistant',
      });
    });

    it('should create handler that throws on error', async () => {
      const registrations = createMessageHandlers();
      const handler = registrations[0].handler;

      const request: RpcRequest = {
        id: '1',
        method: 'message.delete',
        params: {},
      };

      await expect(handler(request, mockContext)).rejects.toThrow('sessionId is required');
    });
  });
});
