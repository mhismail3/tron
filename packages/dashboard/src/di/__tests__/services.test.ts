/**
 * @fileoverview Tests for DI container
 */

import { describe, it, expect, vi } from 'vitest';
import {
  createContainer,
  type ServiceContainer,
} from '../index.js';
import type { IDashboardSessionRepository, IDashboardEventRepository } from '../../data/repositories/types.js';

describe('ServiceContainer', () => {
  describe('createContainer', () => {
    it('creates a container with provided repositories', () => {
      const mockSessionRepo = {
        listWithStats: vi.fn().mockResolvedValue([]),
        getById: vi.fn().mockResolvedValue(null),
        getSessionTimeline: vi.fn().mockResolvedValue([]),
        getTokenUsageBySession: vi.fn().mockResolvedValue({
          inputTokens: 0,
          outputTokens: 0,
          totalTokens: 0,
          cacheReadTokens: 0,
          cacheCreationTokens: 0,
          estimatedCost: 0,
        }),
        getStats: vi.fn().mockResolvedValue({
          totalSessions: 0,
          activeSessions: 0,
          totalEvents: 0,
          totalTokensUsed: 0,
          totalCost: 0,
        }),
        count: vi.fn().mockResolvedValue(0),
      } satisfies IDashboardSessionRepository;

      const mockEventRepo = {
        getEventsBySession: vi.fn().mockResolvedValue({
          items: [],
          total: 0,
          limit: 500,
          offset: 0,
          hasMore: false,
        }),
        getEventsByType: vi.fn().mockResolvedValue({
          items: [],
          total: 0,
          limit: 500,
          offset: 0,
          hasMore: false,
        }),
        getById: vi.fn().mockResolvedValue(null),
        search: vi.fn().mockResolvedValue({
          items: [],
          total: 0,
          limit: 100,
          offset: 0,
          hasMore: false,
        }),
        countBySession: vi.fn().mockResolvedValue(0),
      } satisfies IDashboardEventRepository;

      const container = createContainer({
        sessions: mockSessionRepo,
        events: mockEventRepo,
      });

      expect(container.sessions).toBe(mockSessionRepo);
      expect(container.events).toBe(mockEventRepo);
    });

    it('provides type-safe access to repositories', async () => {
      const mockSessionRepo = {
        listWithStats: vi.fn().mockResolvedValue([]),
        getById: vi.fn().mockResolvedValue(null),
        getSessionTimeline: vi.fn().mockResolvedValue([]),
        getTokenUsageBySession: vi.fn().mockResolvedValue({
          inputTokens: 0,
          outputTokens: 0,
          totalTokens: 0,
          cacheReadTokens: 0,
          cacheCreationTokens: 0,
          estimatedCost: 0,
        }),
        getStats: vi.fn().mockResolvedValue({
          totalSessions: 0,
          activeSessions: 0,
          totalEvents: 0,
          totalTokensUsed: 0,
          totalCost: 0,
        }),
        count: vi.fn().mockResolvedValue(0),
      } satisfies IDashboardSessionRepository;

      const mockEventRepo = {
        getEventsBySession: vi.fn().mockResolvedValue({
          items: [],
          total: 0,
          limit: 500,
          offset: 0,
          hasMore: false,
        }),
        getEventsByType: vi.fn().mockResolvedValue({
          items: [],
          total: 0,
          limit: 500,
          offset: 0,
          hasMore: false,
        }),
        getById: vi.fn().mockResolvedValue(null),
        search: vi.fn().mockResolvedValue({
          items: [],
          total: 0,
          limit: 100,
          offset: 0,
          hasMore: false,
        }),
        countBySession: vi.fn().mockResolvedValue(0),
      } satisfies IDashboardEventRepository;

      const container = createContainer({
        sessions: mockSessionRepo,
        events: mockEventRepo,
      });

      // Verify we can call methods
      await container.sessions.listWithStats();
      expect(mockSessionRepo.listWithStats).toHaveBeenCalled();

      await container.events.getEventsBySession('sess_test' as any);
      expect(mockEventRepo.getEventsBySession).toHaveBeenCalledWith('sess_test');
    });
  });
});
