/**
 * @fileoverview Tests for RPC types
 *
 * TDD: Tests for the RPC protocol type definitions and guards
 */
import { describe, it, expect } from 'vitest';
import {
  isRpcRequest,
  isRpcResponse,
  isRpcEvent,
  type RpcRequest,
  type RpcResponse,
  type RpcEvent,
  type RpcError,
  type SessionCreateParams,
  type AgentPromptParams,
} from '../types.js';

describe('RPC Types', () => {
  describe('RpcRequest', () => {
    it('should define basic request structure', () => {
      const request: RpcRequest = {
        id: 'req_123',
        method: 'session.create',
      };

      expect(request.id).toBe('req_123');
      expect(request.method).toBe('session.create');
    });

    it('should support typed parameters', () => {
      const request: RpcRequest<'session.create', SessionCreateParams> = {
        id: 'req_123',
        method: 'session.create',
        params: {
          workingDirectory: '/home/user/project',
          model: 'claude-sonnet-4-20250514',
        },
      };

      expect(request.params?.workingDirectory).toBe('/home/user/project');
    });

    it('should allow optional params', () => {
      const request: RpcRequest = {
        id: 'req_456',
        method: 'system.ping',
        // No params
      };

      expect(request.params).toBeUndefined();
    });
  });

  describe('RpcResponse', () => {
    it('should define success response', () => {
      const response: RpcResponse<{ sessionId: string }> = {
        id: 'req_123',
        success: true,
        result: { sessionId: 'sess_abc' },
      };

      expect(response.success).toBe(true);
      expect(response.result?.sessionId).toBe('sess_abc');
      expect(response.error).toBeUndefined();
    });

    it('should define error response', () => {
      const response: RpcResponse = {
        id: 'req_123',
        success: false,
        error: {
          code: 'SESSION_NOT_FOUND',
          message: 'Session does not exist',
          details: { sessionId: 'sess_invalid' },
        },
      };

      expect(response.success).toBe(false);
      expect(response.error?.code).toBe('SESSION_NOT_FOUND');
      expect(response.result).toBeUndefined();
    });
  });

  describe('RpcEvent', () => {
    it('should define event structure', () => {
      const event: RpcEvent<'agent.text_delta', { delta: string }> = {
        type: 'agent.text_delta',
        sessionId: 'sess_123',
        timestamp: new Date().toISOString(),
        data: { delta: 'Hello' },
      };

      expect(event.type).toBe('agent.text_delta');
      expect(event.data.delta).toBe('Hello');
    });

    it('should allow events without sessionId', () => {
      const event: RpcEvent<'system.connected', { clientId: string }> = {
        type: 'system.connected',
        timestamp: new Date().toISOString(),
        data: { clientId: 'client_123' },
      };

      expect(event.sessionId).toBeUndefined();
    });
  });

  describe('RpcError', () => {
    it('should define error structure', () => {
      const error: RpcError = {
        code: 'VALIDATION_ERROR',
        message: 'Invalid parameters',
        details: {
          field: 'workingDirectory',
          reason: 'must be absolute path',
        },
      };

      expect(error.code).toBe('VALIDATION_ERROR');
      expect(error.message).toBe('Invalid parameters');
    });
  });

  describe('Type Guards', () => {
    describe('isRpcRequest', () => {
      it('should return true for valid request', () => {
        const valid = {
          id: 'req_123',
          method: 'session.create',
          params: { workingDirectory: '/test' },
        };

        expect(isRpcRequest(valid)).toBe(true);
      });

      it('should return false for missing id', () => {
        const invalid = {
          method: 'session.create',
        };

        expect(isRpcRequest(invalid)).toBe(false);
      });

      it('should return false for missing method', () => {
        const invalid = {
          id: 'req_123',
        };

        expect(isRpcRequest(invalid)).toBe(false);
      });

      it('should return false for null', () => {
        expect(isRpcRequest(null)).toBe(false);
      });

      it('should return false for primitives', () => {
        expect(isRpcRequest('string')).toBe(false);
        expect(isRpcRequest(123)).toBe(false);
        expect(isRpcRequest(undefined)).toBe(false);
      });
    });

    describe('isRpcResponse', () => {
      it('should return true for success response', () => {
        const valid = {
          id: 'req_123',
          success: true,
          result: { data: 'test' },
        };

        expect(isRpcResponse(valid)).toBe(true);
      });

      it('should return true for error response', () => {
        const valid = {
          id: 'req_123',
          success: false,
          error: { code: 'ERROR', message: 'Failed' },
        };

        expect(isRpcResponse(valid)).toBe(true);
      });

      it('should return false for missing success', () => {
        const invalid = {
          id: 'req_123',
          result: {},
        };

        expect(isRpcResponse(invalid)).toBe(false);
      });
    });

    describe('isRpcEvent', () => {
      it('should return true for valid event', () => {
        const valid = {
          type: 'agent.text_delta',
          timestamp: '2025-01-01T00:00:00Z',
          data: { delta: 'test' },
        };

        expect(isRpcEvent(valid)).toBe(true);
      });

      it('should return true for event with sessionId', () => {
        const valid = {
          type: 'agent.complete',
          sessionId: 'sess_123',
          timestamp: '2025-01-01T00:00:00Z',
          data: { success: true },
        };

        expect(isRpcEvent(valid)).toBe(true);
      });

      it('should return false for missing type', () => {
        const invalid = {
          timestamp: '2025-01-01T00:00:00Z',
          data: {},
        };

        expect(isRpcEvent(invalid)).toBe(false);
      });

      it('should return false for missing data', () => {
        const invalid = {
          type: 'test',
          timestamp: '2025-01-01T00:00:00Z',
        };

        expect(isRpcEvent(invalid)).toBe(false);
      });
    });
  });

  describe('Session Types', () => {
    it('should define SessionCreateParams', () => {
      const params: SessionCreateParams = {
        workingDirectory: '/home/user/project',
        model: 'claude-sonnet-4-20250514',
        contextFiles: ['AGENTS.md', 'README.md'],
      };

      expect(params.workingDirectory).toBe('/home/user/project');
      expect(params.contextFiles).toHaveLength(2);
    });
  });

  describe('Agent Types', () => {
    it('should define AgentPromptParams with images', () => {
      const params: AgentPromptParams = {
        sessionId: 'sess_123',
        prompt: 'What is in this image?',
        images: [
          {
            data: 'base64data...',
            mimeType: 'image/png',
          },
        ],
      };

      expect(params.prompt).toBe('What is in this image?');
      expect(params.images?.[0].mimeType).toBe('image/png');
    });
  });
});
