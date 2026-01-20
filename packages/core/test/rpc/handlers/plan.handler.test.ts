/**
 * @fileoverview Tests for Plan RPC Handlers
 *
 * Tests plan.enter, plan.exit, plan.getState handlers.
 */

import { describe, it, expect, vi, beforeEach } from 'vitest';
import {
  createPlanHandlers,
  handlePlanEnter,
  handlePlanExit,
  handlePlanGetState,
} from '../../../src/rpc/handlers/plan.handler.js';
import type { RpcRequest } from '../../../src/rpc/types.js';
import type { RpcContext } from '../../../src/rpc/handler.js';
import { MethodRegistry } from '../../../src/rpc/registry.js';
import { DEFAULT_PLAN_MODE_BLOCKED_TOOLS } from '../../../src/rpc/types.js';

describe('Plan Handlers', () => {
  let mockContext: RpcContext;
  let mockContextWithoutPlanManager: RpcContext;
  let mockEnterPlanMode: ReturnType<typeof vi.fn>;
  let mockExitPlanMode: ReturnType<typeof vi.fn>;
  let mockGetPlanModeState: ReturnType<typeof vi.fn>;

  beforeEach(() => {
    mockEnterPlanMode = vi.fn().mockResolvedValue({
      success: true,
      blockedTools: DEFAULT_PLAN_MODE_BLOCKED_TOOLS,
    });

    mockExitPlanMode = vi.fn().mockResolvedValue({
      success: true,
    });

    mockGetPlanModeState = vi.fn().mockReturnValue({
      isActive: false,
      blockedTools: [],
    });

    mockContext = {
      sessionManager: {} as any,
      agentManager: {} as any,
      memoryStore: {} as any,
      planManager: {
        enterPlanMode: mockEnterPlanMode,
        exitPlanMode: mockExitPlanMode,
        getPlanModeState: mockGetPlanModeState,
      } as any,
    };

    mockContextWithoutPlanManager = {
      sessionManager: {} as any,
      agentManager: {} as any,
      memoryStore: {} as any,
    };
  });

  describe('handlePlanEnter', () => {
    it('should enter plan mode with default blocked tools', async () => {
      const request: RpcRequest = {
        id: 'req-1',
        method: 'plan.enter',
        params: {
          sessionId: 'sess-123',
          skillName: 'plan',
        },
      };

      const response = await handlePlanEnter(request, mockContext);

      expect(response.success).toBe(true);
      expect(response.result).toEqual({
        success: true,
        blockedTools: DEFAULT_PLAN_MODE_BLOCKED_TOOLS,
      });
      expect(mockEnterPlanMode).toHaveBeenCalledWith(
        'sess-123',
        'plan',
        undefined
      );
    });

    it('should enter plan mode with custom blocked tools', async () => {
      const customTools = ['Write', 'Edit'];
      mockEnterPlanMode.mockResolvedValue({
        success: true,
        blockedTools: customTools,
      });

      const request: RpcRequest = {
        id: 'req-1',
        method: 'plan.enter',
        params: {
          sessionId: 'sess-123',
          skillName: 'custom-plan',
          blockedTools: customTools,
        },
      };

      const response = await handlePlanEnter(request, mockContext);

      expect(response.success).toBe(true);
      expect(response.result).toEqual({
        success: true,
        blockedTools: customTools,
      });
      expect(mockEnterPlanMode).toHaveBeenCalledWith(
        'sess-123',
        'custom-plan',
        customTools
      );
    });

    it('should return error when sessionId is missing', async () => {
      const request: RpcRequest = {
        id: 'req-1',
        method: 'plan.enter',
        params: {
          skillName: 'plan',
        },
      };

      const response = await handlePlanEnter(request, mockContext);

      expect(response.success).toBe(false);
      expect(response.error?.code).toBe('INVALID_PARAMS');
      expect(response.error?.message).toBe('sessionId is required');
    });

    it('should return error when skillName is missing', async () => {
      const request: RpcRequest = {
        id: 'req-1',
        method: 'plan.enter',
        params: {
          sessionId: 'sess-123',
        },
      };

      const response = await handlePlanEnter(request, mockContext);

      expect(response.success).toBe(false);
      expect(response.error?.code).toBe('INVALID_PARAMS');
      expect(response.error?.message).toBe('skillName is required');
    });

    it('should return error when plan manager is not available', async () => {
      const request: RpcRequest = {
        id: 'req-1',
        method: 'plan.enter',
        params: {
          sessionId: 'sess-123',
          skillName: 'plan',
        },
      };

      const response = await handlePlanEnter(request, mockContextWithoutPlanManager);

      expect(response.success).toBe(false);
      expect(response.error?.code).toBe('NOT_SUPPORTED');
      expect(response.error?.message).toBe('Plan manager not available');
    });

    it('should return error when already in plan mode', async () => {
      mockEnterPlanMode.mockRejectedValue(new Error('Already in plan mode'));

      const request: RpcRequest = {
        id: 'req-1',
        method: 'plan.enter',
        params: {
          sessionId: 'sess-123',
          skillName: 'plan',
        },
      };

      const response = await handlePlanEnter(request, mockContext);

      expect(response.success).toBe(false);
      expect(response.error?.code).toBe('ALREADY_IN_PLAN_MODE');
      expect(response.error?.message).toBe('Session is already in plan mode');
    });

    it('should return error when session is not found', async () => {
      mockEnterPlanMode.mockRejectedValue(new Error('Session not found'));

      const request: RpcRequest = {
        id: 'req-1',
        method: 'plan.enter',
        params: {
          sessionId: 'nonexistent-sess',
          skillName: 'plan',
        },
      };

      const response = await handlePlanEnter(request, mockContext);

      expect(response.success).toBe(false);
      expect(response.error?.code).toBe('SESSION_NOT_FOUND');
      expect(response.error?.message).toBe('Session does not exist');
    });
  });

  describe('handlePlanExit', () => {
    it('should exit plan mode with approved reason', async () => {
      const request: RpcRequest = {
        id: 'req-1',
        method: 'plan.exit',
        params: {
          sessionId: 'sess-123',
          reason: 'approved',
        },
      };

      const response = await handlePlanExit(request, mockContext);

      expect(response.success).toBe(true);
      expect(response.result).toEqual({
        success: true,
      });
      expect(mockExitPlanMode).toHaveBeenCalledWith(
        'sess-123',
        'approved',
        undefined
      );
    });

    it('should exit plan mode with cancelled reason', async () => {
      const request: RpcRequest = {
        id: 'req-1',
        method: 'plan.exit',
        params: {
          sessionId: 'sess-123',
          reason: 'cancelled',
        },
      };

      const response = await handlePlanExit(request, mockContext);

      expect(response.success).toBe(true);
      expect(mockExitPlanMode).toHaveBeenCalledWith(
        'sess-123',
        'cancelled',
        undefined
      );
    });

    it('should exit plan mode with plan path', async () => {
      const request: RpcRequest = {
        id: 'req-1',
        method: 'plan.exit',
        params: {
          sessionId: 'sess-123',
          reason: 'approved',
          planPath: '/path/to/plan.md',
        },
      };

      const response = await handlePlanExit(request, mockContext);

      expect(response.success).toBe(true);
      expect(mockExitPlanMode).toHaveBeenCalledWith(
        'sess-123',
        'approved',
        '/path/to/plan.md'
      );
    });

    it('should return error when sessionId is missing', async () => {
      const request: RpcRequest = {
        id: 'req-1',
        method: 'plan.exit',
        params: {
          reason: 'approved',
        },
      };

      const response = await handlePlanExit(request, mockContext);

      expect(response.success).toBe(false);
      expect(response.error?.code).toBe('INVALID_PARAMS');
      expect(response.error?.message).toBe('sessionId is required');
    });

    it('should return error when reason is missing', async () => {
      const request: RpcRequest = {
        id: 'req-1',
        method: 'plan.exit',
        params: {
          sessionId: 'sess-123',
        },
      };

      const response = await handlePlanExit(request, mockContext);

      expect(response.success).toBe(false);
      expect(response.error?.code).toBe('INVALID_PARAMS');
      expect(response.error?.message).toBe('reason is required');
    });

    it('should return error when plan manager is not available', async () => {
      const request: RpcRequest = {
        id: 'req-1',
        method: 'plan.exit',
        params: {
          sessionId: 'sess-123',
          reason: 'approved',
        },
      };

      const response = await handlePlanExit(request, mockContextWithoutPlanManager);

      expect(response.success).toBe(false);
      expect(response.error?.code).toBe('NOT_SUPPORTED');
      expect(response.error?.message).toBe('Plan manager not available');
    });

    it('should return error when not in plan mode', async () => {
      mockExitPlanMode.mockRejectedValue(new Error('Not in plan mode'));

      const request: RpcRequest = {
        id: 'req-1',
        method: 'plan.exit',
        params: {
          sessionId: 'sess-123',
          reason: 'approved',
        },
      };

      const response = await handlePlanExit(request, mockContext);

      expect(response.success).toBe(false);
      expect(response.error?.code).toBe('NOT_IN_PLAN_MODE');
      expect(response.error?.message).toBe('Session is not in plan mode');
    });
  });

  describe('handlePlanGetState', () => {
    it('should get inactive plan mode state', async () => {
      mockGetPlanModeState.mockReturnValue({
        isActive: false,
        blockedTools: [],
      });

      const request: RpcRequest = {
        id: 'req-1',
        method: 'plan.getState',
        params: {
          sessionId: 'sess-123',
        },
      };

      const response = await handlePlanGetState(request, mockContext);

      expect(response.success).toBe(true);
      expect(response.result).toEqual({
        isActive: false,
        blockedTools: [],
      });
      expect(mockGetPlanModeState).toHaveBeenCalledWith('sess-123');
    });

    it('should get active plan mode state with blocked tools', async () => {
      mockGetPlanModeState.mockReturnValue({
        isActive: true,
        skillName: 'plan',
        blockedTools: DEFAULT_PLAN_MODE_BLOCKED_TOOLS,
      });

      const request: RpcRequest = {
        id: 'req-1',
        method: 'plan.getState',
        params: {
          sessionId: 'sess-123',
        },
      };

      const response = await handlePlanGetState(request, mockContext);

      expect(response.success).toBe(true);
      expect(response.result).toEqual({
        isActive: true,
        skillName: 'plan',
        blockedTools: DEFAULT_PLAN_MODE_BLOCKED_TOOLS,
      });
    });

    it('should return error when sessionId is missing', async () => {
      const request: RpcRequest = {
        id: 'req-1',
        method: 'plan.getState',
        params: {},
      };

      const response = await handlePlanGetState(request, mockContext);

      expect(response.success).toBe(false);
      expect(response.error?.code).toBe('INVALID_PARAMS');
      expect(response.error?.message).toBe('sessionId is required');
    });

    it('should return error when plan manager is not available', async () => {
      const request: RpcRequest = {
        id: 'req-1',
        method: 'plan.getState',
        params: {
          sessionId: 'sess-123',
        },
      };

      const response = await handlePlanGetState(request, mockContextWithoutPlanManager);

      expect(response.success).toBe(false);
      expect(response.error?.code).toBe('NOT_SUPPORTED');
      expect(response.error?.message).toBe('Plan manager not available');
    });

    it('should return error when session is not found', async () => {
      mockGetPlanModeState.mockImplementation(() => {
        throw new Error('Session not found');
      });

      const request: RpcRequest = {
        id: 'req-1',
        method: 'plan.getState',
        params: {
          sessionId: 'nonexistent-sess',
        },
      };

      const response = await handlePlanGetState(request, mockContext);

      expect(response.success).toBe(false);
      expect(response.error?.code).toBe('SESSION_NOT_FOUND');
      expect(response.error?.message).toBe('Session does not exist');
    });
  });

  describe('createPlanHandlers', () => {
    it('should return all plan method registrations', () => {
      const handlers = createPlanHandlers();

      expect(handlers).toHaveLength(3);
      expect(handlers.map(h => h.method)).toEqual([
        'plan.enter',
        'plan.exit',
        'plan.getState',
      ]);
      expect(handlers.every(h => typeof h.handler === 'function')).toBe(true);
    });
  });
});
