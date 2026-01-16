/**
 * Tests for skill.handler.ts
 */

import { describe, it, expect, vi, beforeEach } from 'vitest';
import {
  handleSkillList,
  handleSkillGet,
  handleSkillRefresh,
  handleSkillRemove,
  createSkillHandlers,
} from '../../../src/rpc/handlers/skill.handler.js';
import type { RpcRequest, RpcResponse } from '../../../src/rpc/types.js';
import type { RpcContext } from '../../../src/rpc/handler.js';

describe('skill.handler', () => {
  let mockContext: RpcContext;

  beforeEach(() => {
    mockContext = {
      skillManager: {
        listSkills: vi.fn(),
        getSkill: vi.fn(),
        refreshSkills: vi.fn(),
        removeSkill: vi.fn(),
      },
    } as unknown as RpcContext;
  });

  describe('handleSkillList', () => {
    it('should return error when skillManager is not available', async () => {
      const request: RpcRequest = {
        jsonrpc: '2.0',
        id: '1',
        method: 'skill.list',
        params: {},
      };

      const contextWithoutSkillManager = {} as RpcContext;
      const response = await handleSkillList(request, contextWithoutSkillManager);

      expect(response.success).toBe(false);
      expect(response.error?.code).toBe('NOT_SUPPORTED');
      expect(response.error?.message).toBe('Skill manager not available');
    });

    it('should list skills successfully', async () => {
      const request: RpcRequest = {
        jsonrpc: '2.0',
        id: '1',
        method: 'skill.list',
        params: { category: 'automation' },
      };

      const mockResult = {
        skills: [
          { name: 'skill1', description: 'First skill' },
          { name: 'skill2', description: 'Second skill' },
        ],
      };
      vi.mocked(mockContext.skillManager!.listSkills).mockResolvedValue(mockResult);

      const response = await handleSkillList(request, mockContext);

      expect(response.success).toBe(true);
      expect(response.result).toEqual(mockResult);
      expect(mockContext.skillManager!.listSkills).toHaveBeenCalledWith({ category: 'automation' });
    });

    it('should handle errors', async () => {
      const request: RpcRequest = {
        jsonrpc: '2.0',
        id: '1',
        method: 'skill.list',
        params: {},
      };

      vi.mocked(mockContext.skillManager!.listSkills).mockRejectedValue(new Error('Database error'));

      const response = await handleSkillList(request, mockContext);

      expect(response.success).toBe(false);
      expect(response.error?.code).toBe('SKILL_ERROR');
    });
  });

  describe('handleSkillGet', () => {
    it('should return error when skillManager is not available', async () => {
      const request: RpcRequest = {
        jsonrpc: '2.0',
        id: '1',
        method: 'skill.get',
        params: { name: 'test-skill' },
      };

      const contextWithoutSkillManager = {} as RpcContext;
      const response = await handleSkillGet(request, contextWithoutSkillManager);

      expect(response.success).toBe(false);
      expect(response.error?.code).toBe('NOT_SUPPORTED');
    });

    it('should return error when name is missing', async () => {
      const request: RpcRequest = {
        jsonrpc: '2.0',
        id: '1',
        method: 'skill.get',
        params: {},
      };

      const response = await handleSkillGet(request, mockContext);

      expect(response.success).toBe(false);
      expect(response.error?.code).toBe('INVALID_PARAMS');
      expect(response.error?.message).toBe('name is required');
    });

    it('should get skill successfully', async () => {
      const request: RpcRequest = {
        jsonrpc: '2.0',
        id: '1',
        method: 'skill.get',
        params: { name: 'test-skill' },
      };

      const mockResult = {
        name: 'test-skill',
        description: 'A test skill',
        enabled: true,
      };
      vi.mocked(mockContext.skillManager!.getSkill).mockResolvedValue(mockResult);

      const response = await handleSkillGet(request, mockContext);

      expect(response.success).toBe(true);
      expect(response.result).toEqual(mockResult);
      expect(mockContext.skillManager!.getSkill).toHaveBeenCalledWith({ name: 'test-skill' });
    });

    it('should handle errors', async () => {
      const request: RpcRequest = {
        jsonrpc: '2.0',
        id: '1',
        method: 'skill.get',
        params: { name: 'test-skill' },
      };

      vi.mocked(mockContext.skillManager!.getSkill).mockRejectedValue(new Error('Skill not found'));

      const response = await handleSkillGet(request, mockContext);

      expect(response.success).toBe(false);
      expect(response.error?.code).toBe('SKILL_ERROR');
    });
  });

  describe('handleSkillRefresh', () => {
    it('should return error when skillManager is not available', async () => {
      const request: RpcRequest = {
        jsonrpc: '2.0',
        id: '1',
        method: 'skill.refresh',
        params: {},
      };

      const contextWithoutSkillManager = {} as RpcContext;
      const response = await handleSkillRefresh(request, contextWithoutSkillManager);

      expect(response.success).toBe(false);
      expect(response.error?.code).toBe('NOT_SUPPORTED');
    });

    it('should refresh skills successfully', async () => {
      const request: RpcRequest = {
        jsonrpc: '2.0',
        id: '1',
        method: 'skill.refresh',
        params: { force: true },
      };

      const mockResult = { refreshedCount: 5 };
      vi.mocked(mockContext.skillManager!.refreshSkills).mockResolvedValue(mockResult);

      const response = await handleSkillRefresh(request, mockContext);

      expect(response.success).toBe(true);
      expect(response.result).toEqual(mockResult);
      expect(mockContext.skillManager!.refreshSkills).toHaveBeenCalledWith({ force: true });
    });

    it('should handle errors', async () => {
      const request: RpcRequest = {
        jsonrpc: '2.0',
        id: '1',
        method: 'skill.refresh',
        params: {},
      };

      vi.mocked(mockContext.skillManager!.refreshSkills).mockRejectedValue(new Error('Refresh failed'));

      const response = await handleSkillRefresh(request, mockContext);

      expect(response.success).toBe(false);
      expect(response.error?.code).toBe('SKILL_ERROR');
    });
  });

  describe('handleSkillRemove', () => {
    it('should return error when skillManager is not available', async () => {
      const request: RpcRequest = {
        jsonrpc: '2.0',
        id: '1',
        method: 'skill.remove',
        params: { sessionId: 'session-123', skillName: 'test-skill' },
      };

      const contextWithoutSkillManager = {} as RpcContext;
      const response = await handleSkillRemove(request, contextWithoutSkillManager);

      expect(response.success).toBe(false);
      expect(response.error?.code).toBe('NOT_SUPPORTED');
    });

    it('should return error when sessionId is missing', async () => {
      const request: RpcRequest = {
        jsonrpc: '2.0',
        id: '1',
        method: 'skill.remove',
        params: { skillName: 'test-skill' },
      };

      const response = await handleSkillRemove(request, mockContext);

      expect(response.success).toBe(false);
      expect(response.error?.code).toBe('INVALID_PARAMS');
      expect(response.error?.message).toBe('sessionId is required');
    });

    it('should return error when skillName is missing', async () => {
      const request: RpcRequest = {
        jsonrpc: '2.0',
        id: '1',
        method: 'skill.remove',
        params: { sessionId: 'session-123' },
      };

      const response = await handleSkillRemove(request, mockContext);

      expect(response.success).toBe(false);
      expect(response.error?.code).toBe('INVALID_PARAMS');
      expect(response.error?.message).toBe('skillName is required');
    });

    it('should remove skill successfully', async () => {
      const request: RpcRequest = {
        jsonrpc: '2.0',
        id: '1',
        method: 'skill.remove',
        params: { sessionId: 'session-123', skillName: 'test-skill' },
      };

      const mockResult = { removed: true };
      vi.mocked(mockContext.skillManager!.removeSkill).mockResolvedValue(mockResult);

      const response = await handleSkillRemove(request, mockContext);

      expect(response.success).toBe(true);
      expect(response.result).toEqual(mockResult);
      expect(mockContext.skillManager!.removeSkill).toHaveBeenCalledWith({
        sessionId: 'session-123',
        skillName: 'test-skill',
      });
    });

    it('should handle errors', async () => {
      const request: RpcRequest = {
        jsonrpc: '2.0',
        id: '1',
        method: 'skill.remove',
        params: { sessionId: 'session-123', skillName: 'test-skill' },
      };

      vi.mocked(mockContext.skillManager!.removeSkill).mockRejectedValue(new Error('Skill not found'));

      const response = await handleSkillRemove(request, mockContext);

      expect(response.success).toBe(false);
      expect(response.error?.code).toBe('SKILL_ERROR');
    });
  });

  describe('createSkillHandlers', () => {
    it('should create handler registrations', () => {
      const registrations = createSkillHandlers();

      expect(registrations).toHaveLength(4);

      const methods = registrations.map(r => r.method);
      expect(methods).toContain('skill.list');
      expect(methods).toContain('skill.get');
      expect(methods).toContain('skill.refresh');
      expect(methods).toContain('skill.remove');

      for (const reg of registrations) {
        expect(reg.options?.requiredManagers).toContain('skillManager');
      }

      // Check specific required params
      const getHandler = registrations.find(r => r.method === 'skill.get');
      expect(getHandler?.options?.requiredParams).toContain('name');

      const removeHandler = registrations.find(r => r.method === 'skill.remove');
      expect(removeHandler?.options?.requiredParams).toContain('sessionId');
      expect(removeHandler?.options?.requiredParams).toContain('skillName');
    });

    it('should create handlers that return results on success', async () => {
      const registrations = createSkillHandlers();
      const listHandler = registrations.find(r => r.method === 'skill.list')!.handler;

      const mockResult = { skills: [] };
      vi.mocked(mockContext.skillManager!.listSkills).mockResolvedValue(mockResult);

      const request: RpcRequest = {
        jsonrpc: '2.0',
        id: '1',
        method: 'skill.list',
        params: {},
      };

      const result = await listHandler(request, mockContext);

      expect(result).toEqual(mockResult);
    });

    it('should create handlers that throw on error', async () => {
      const registrations = createSkillHandlers();
      const getHandler = registrations.find(r => r.method === 'skill.get')!.handler;

      const request: RpcRequest = {
        jsonrpc: '2.0',
        id: '1',
        method: 'skill.get',
        params: {},
      };

      await expect(getHandler(request, mockContext)).rejects.toThrow('name is required');
    });
  });
});
