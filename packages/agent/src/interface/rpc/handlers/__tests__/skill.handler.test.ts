/**
 * @fileoverview Tests for Skill RPC Handlers
 *
 * Tests skill.list, skill.get, skill.refresh, skill.remove handlers
 * using the registry dispatch pattern.
 */

import { describe, it, expect, vi, beforeEach } from 'vitest';
import { createSkillHandlers } from '../skill.handler.js';
import type { RpcRequest } from '../../types.js';
import type { RpcContext } from '../../handler.js';
import { MethodRegistry } from '../../registry.js';

describe('Skill Handlers', () => {
  let registry: MethodRegistry;
  let mockContext: RpcContext;
  let mockContextWithoutSkillManager: RpcContext;
  let mockListSkills: ReturnType<typeof vi.fn>;
  let mockGetSkill: ReturnType<typeof vi.fn>;
  let mockRefreshSkills: ReturnType<typeof vi.fn>;
  let mockRemoveSkill: ReturnType<typeof vi.fn>;

  beforeEach(() => {
    registry = new MethodRegistry();
    registry.registerAll(createSkillHandlers());

    mockListSkills = vi.fn();
    mockGetSkill = vi.fn();
    mockRefreshSkills = vi.fn();
    mockRemoveSkill = vi.fn();

    mockContext = {
      skillManager: {
        listSkills: mockListSkills,
        getSkill: mockGetSkill,
        refreshSkills: mockRefreshSkills,
        removeSkill: mockRemoveSkill,
      },
    } as unknown as RpcContext;

    mockContextWithoutSkillManager = {} as RpcContext;
  });

  describe('skill.list', () => {
    it('should return NOT_AVAILABLE when skillManager is not available', async () => {
      const request: RpcRequest = {
        id: '1',
        method: 'skill.list',
        params: {},
      };

      const response = await registry.dispatch(request, mockContextWithoutSkillManager);

      expect(response.success).toBe(false);
      expect(response.error?.code).toBe('NOT_AVAILABLE');
    });

    it('should list skills successfully', async () => {
      const request: RpcRequest = {
        id: '1',
        method: 'skill.list',
        params: { category: 'automation' },
      };

      const mockResult = {
        skills: [
          { name: 'skill1', displayName: 'Skill 1', description: 'First skill', source: 'global' as const },
          { name: 'skill2', displayName: 'Skill 2', description: 'Second skill', source: 'project' as const },
        ],
        totalCount: 2,
      };
      mockListSkills.mockResolvedValue(mockResult);

      const response = await registry.dispatch(request, mockContext);

      expect(response.success).toBe(true);
      expect(response.result).toEqual(mockResult);
      expect(mockListSkills).toHaveBeenCalledWith({ category: 'automation' });
    });

    it('should handle errors', async () => {
      const request: RpcRequest = {
        id: '1',
        method: 'skill.list',
        params: {},
      };

      mockListSkills.mockRejectedValue(new Error('Database error'));

      const response = await registry.dispatch(request, mockContext);

      expect(response.success).toBe(false);
      expect(response.error?.code).toBe('SKILL_ERROR');
    });
  });

  describe('skill.get', () => {
    it('should return NOT_AVAILABLE when skillManager is not available', async () => {
      const request: RpcRequest = {
        id: '1',
        method: 'skill.get',
        params: { name: 'test-skill' },
      };

      const response = await registry.dispatch(request, mockContextWithoutSkillManager);

      expect(response.success).toBe(false);
      expect(response.error?.code).toBe('NOT_AVAILABLE');
    });

    it('should return error when name is missing', async () => {
      const request: RpcRequest = {
        id: '1',
        method: 'skill.get',
        params: {},
      };

      const response = await registry.dispatch(request, mockContext);

      expect(response.success).toBe(false);
      expect(response.error?.code).toBe('INVALID_PARAMS');
      expect(response.error?.message).toContain('name');
    });

    it('should get skill successfully', async () => {
      const request: RpcRequest = {
        id: '1',
        method: 'skill.get',
        params: { name: 'test-skill' },
      };

      const mockResult = {
        skill: {
          name: 'test-skill',
          displayName: 'Test Skill',
          description: 'A test skill',
          source: 'global' as const,
          content: '# Test Skill\n\nSome content',
          path: '/path/to/skill',
          additionalFiles: [],
        },
        found: true,
      };
      mockGetSkill.mockResolvedValue(mockResult);

      const response = await registry.dispatch(request, mockContext);

      expect(response.success).toBe(true);
      expect(response.result).toEqual(mockResult);
      expect(mockGetSkill).toHaveBeenCalledWith({ name: 'test-skill' });
    });

    it('should handle errors', async () => {
      const request: RpcRequest = {
        id: '1',
        method: 'skill.get',
        params: { name: 'test-skill' },
      };

      mockGetSkill.mockRejectedValue(new Error('Skill not found'));

      const response = await registry.dispatch(request, mockContext);

      expect(response.success).toBe(false);
      expect(response.error?.code).toBe('SKILL_ERROR');
    });
  });

  describe('skill.refresh', () => {
    it('should return NOT_AVAILABLE when skillManager is not available', async () => {
      const request: RpcRequest = {
        id: '1',
        method: 'skill.refresh',
        params: {},
      };

      const response = await registry.dispatch(request, mockContextWithoutSkillManager);

      expect(response.success).toBe(false);
      expect(response.error?.code).toBe('NOT_AVAILABLE');
    });

    it('should refresh skills successfully', async () => {
      const request: RpcRequest = {
        id: '1',
        method: 'skill.refresh',
        params: { force: true },
      };

      const mockResult = { success: true, skillCount: 5 };
      mockRefreshSkills.mockResolvedValue(mockResult);

      const response = await registry.dispatch(request, mockContext);

      expect(response.success).toBe(true);
      expect(response.result).toEqual(mockResult);
      expect(mockRefreshSkills).toHaveBeenCalledWith({ force: true });
    });

    it('should handle errors', async () => {
      const request: RpcRequest = {
        id: '1',
        method: 'skill.refresh',
        params: {},
      };

      mockRefreshSkills.mockRejectedValue(new Error('Refresh failed'));

      const response = await registry.dispatch(request, mockContext);

      expect(response.success).toBe(false);
      expect(response.error?.code).toBe('SKILL_ERROR');
    });
  });

  describe('skill.remove', () => {
    it('should return NOT_AVAILABLE when skillManager is not available', async () => {
      const request: RpcRequest = {
        id: '1',
        method: 'skill.remove',
        params: { sessionId: 'session-123', skillName: 'test-skill' },
      };

      const response = await registry.dispatch(request, mockContextWithoutSkillManager);

      expect(response.success).toBe(false);
      expect(response.error?.code).toBe('NOT_AVAILABLE');
    });

    it('should return error when sessionId is missing', async () => {
      const request: RpcRequest = {
        id: '1',
        method: 'skill.remove',
        params: { skillName: 'test-skill' },
      };

      const response = await registry.dispatch(request, mockContext);

      expect(response.success).toBe(false);
      expect(response.error?.code).toBe('INVALID_PARAMS');
      expect(response.error?.message).toContain('sessionId');
    });

    it('should return error when skillName is missing', async () => {
      const request: RpcRequest = {
        id: '1',
        method: 'skill.remove',
        params: { sessionId: 'session-123' },
      };

      const response = await registry.dispatch(request, mockContext);

      expect(response.success).toBe(false);
      expect(response.error?.code).toBe('INVALID_PARAMS');
      expect(response.error?.message).toContain('skillName');
    });

    it('should remove skill successfully', async () => {
      const request: RpcRequest = {
        id: '1',
        method: 'skill.remove',
        params: { sessionId: 'session-123', skillName: 'test-skill' },
      };

      const mockResult = { success: true };
      mockRemoveSkill.mockResolvedValue(mockResult);

      const response = await registry.dispatch(request, mockContext);

      expect(response.success).toBe(true);
      expect(response.result).toEqual(mockResult);
      expect(mockRemoveSkill).toHaveBeenCalledWith({
        sessionId: 'session-123',
        skillName: 'test-skill',
      });
    });

    it('should handle errors', async () => {
      const request: RpcRequest = {
        id: '1',
        method: 'skill.remove',
        params: { sessionId: 'session-123', skillName: 'test-skill' },
      };

      mockRemoveSkill.mockRejectedValue(new Error('Skill not found'));

      const response = await registry.dispatch(request, mockContext);

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

      const getHandler = registrations.find(r => r.method === 'skill.get');
      expect(getHandler?.options?.requiredParams).toContain('name');

      const removeHandler = registrations.find(r => r.method === 'skill.remove');
      expect(removeHandler?.options?.requiredParams).toContain('sessionId');
      expect(removeHandler?.options?.requiredParams).toContain('skillName');
    });
  });
});
