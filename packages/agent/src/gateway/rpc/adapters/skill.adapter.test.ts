/**
 * @fileoverview Tests for Skill Adapter
 *
 * The skill adapter manages per-directory skill registries and
 * handles skill listing, loading, refreshing, and removal.
 */

import { describe, it, expect, vi, beforeEach } from 'vitest';
import { createSkillAdapter } from './skill.adapter.js';
import type { EventStoreOrchestrator } from '../../../event-store-orchestrator.js';

// Mock the SkillRegistry
vi.mock('../../../index.js', async () => {
  const actual = await vi.importActual('../../../index.js');
  return {
    ...actual,
    SkillRegistry: vi.fn().mockImplementation(() => ({
      initialize: vi.fn().mockResolvedValue(undefined),
      list: vi.fn().mockReturnValue([]),
      listFull: vi.fn().mockReturnValue([]),
      get: vi.fn().mockReturnValue(null),
      size: 0,
    })),
  };
});

describe('SkillAdapter', () => {
  let mockOrchestrator: Partial<EventStoreOrchestrator>;
  let mockSkillTracker: any;

  beforeEach(() => {
    vi.clearAllMocks();

    mockSkillTracker = {
      hasSkill: vi.fn(),
      removeSkill: vi.fn(),
    };

    mockOrchestrator = {
      getSession: vi.fn(),
      getActiveSession: vi.fn(),
      appendEvent: vi.fn(),
      emit: vi.fn(),
    };
  });

  describe('listSkills', () => {
    it('should return empty list when no skills exist', async () => {
      vi.mocked(mockOrchestrator.getSession!).mockResolvedValue({
        workingDirectory: '/test/project',
      } as any);

      const adapter = createSkillAdapter({
        orchestrator: mockOrchestrator as EventStoreOrchestrator,
      });

      const result = await adapter.listSkills({
        sessionId: 'sess-123',
      });

      expect(result.skills).toEqual([]);
      expect(result.totalCount).toBe(0);
      expect(result.autoInjectCount).toBe(0);
    });

    it('should use process.cwd when no session provided', async () => {
      const adapter = createSkillAdapter({
        orchestrator: mockOrchestrator as EventStoreOrchestrator,
      });

      const result = await adapter.listSkills({});

      expect(mockOrchestrator.getSession).not.toHaveBeenCalled();
      expect(result.skills).toEqual([]);
    });

    it('should return null for session when session not found', async () => {
      vi.mocked(mockOrchestrator.getSession!).mockResolvedValue(null);

      const adapter = createSkillAdapter({
        orchestrator: mockOrchestrator as EventStoreOrchestrator,
      });

      const result = await adapter.listSkills({
        sessionId: 'non-existent',
      });

      // Falls back to process.cwd()
      expect(result.skills).toEqual([]);
    });
  });

  describe('getSkill', () => {
    it('should return not found for non-existent skill', async () => {
      vi.mocked(mockOrchestrator.getSession!).mockResolvedValue({
        workingDirectory: '/test/project',
      } as any);

      const adapter = createSkillAdapter({
        orchestrator: mockOrchestrator as EventStoreOrchestrator,
      });

      const result = await adapter.getSkill({
        sessionId: 'sess-123',
        name: 'non-existent-skill',
      });

      expect(result.found).toBe(false);
      expect(result.skill).toBeNull();
    });
  });

  describe('refreshSkills', () => {
    it('should refresh skills and return success', async () => {
      vi.mocked(mockOrchestrator.getSession!).mockResolvedValue({
        workingDirectory: '/test/project',
      } as any);

      const adapter = createSkillAdapter({
        orchestrator: mockOrchestrator as EventStoreOrchestrator,
      });

      const result = await adapter.refreshSkills({
        sessionId: 'sess-123',
      });

      expect(result.success).toBe(true);
      expect(result.skillCount).toBe(0);
    });

    it('should use process.cwd when no session', async () => {
      const adapter = createSkillAdapter({
        orchestrator: mockOrchestrator as EventStoreOrchestrator,
      });

      const result = await adapter.refreshSkills({});

      expect(result.success).toBe(true);
    });
  });

  describe('removeSkill', () => {
    it('should return error when session not active', async () => {
      vi.mocked(mockOrchestrator.getActiveSession!).mockReturnValue(null);

      const adapter = createSkillAdapter({
        orchestrator: mockOrchestrator as EventStoreOrchestrator,
      });

      const result = await adapter.removeSkill({
        sessionId: 'sess-123',
        skillName: 'some-skill',
      });

      expect(result.success).toBe(false);
      expect(result.error).toBe('Session not active');
    });

    it('should return error when skill not in session', async () => {
      mockSkillTracker.hasSkill.mockReturnValue(false);
      vi.mocked(mockOrchestrator.getActiveSession!).mockReturnValue({
        skillTracker: mockSkillTracker,
      } as any);

      const adapter = createSkillAdapter({
        orchestrator: mockOrchestrator as EventStoreOrchestrator,
      });

      const result = await adapter.removeSkill({
        sessionId: 'sess-123',
        skillName: 'some-skill',
      });

      expect(result.success).toBe(false);
      expect(result.error).toBe('Skill not in session context');
    });

    it('should remove skill successfully', async () => {
      mockSkillTracker.hasSkill.mockReturnValue(true);
      vi.mocked(mockOrchestrator.getActiveSession!).mockReturnValue({
        skillTracker: mockSkillTracker,
      } as any);
      vi.mocked(mockOrchestrator.appendEvent!).mockResolvedValue({ id: 'evt-1' } as any);

      const adapter = createSkillAdapter({
        orchestrator: mockOrchestrator as EventStoreOrchestrator,
      });

      const result = await adapter.removeSkill({
        sessionId: 'sess-123',
        skillName: 'some-skill',
      });

      expect(result.success).toBe(true);
      expect(mockSkillTracker.removeSkill).toHaveBeenCalledWith('some-skill');
      expect(mockOrchestrator.appendEvent).toHaveBeenCalledWith({
        sessionId: 'sess-123',
        type: 'skill.removed',
        payload: {
          skillName: 'some-skill',
          removedVia: 'manual',
        },
      });
      expect(mockOrchestrator.emit).toHaveBeenCalledWith('skill_removed', {
        sessionId: 'sess-123',
        skillName: 'some-skill',
      });
    });
  });
});
