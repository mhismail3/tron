/**
 * @fileoverview Tests for useSessions hook
 */

import { describe, it, expect, vi, beforeEach } from 'vitest';
import { renderHook, waitFor, act } from '@testing-library/react';
import React from 'react';
import { useSessions } from '../useSessions.js';
import { DashboardProvider } from '../../store/context.js';
import { initializeContainer, resetContainer } from '../../di/index.js';
import type { IDashboardSessionRepository, IDashboardEventRepository } from '../../data/repositories/types.js';
import type { SessionId } from '@tron/agent';

describe('useSessions', () => {
  const mockSessionRepo: IDashboardSessionRepository = {
    listWithStats: vi.fn().mockResolvedValue([
      {
        id: 'sess_1' as SessionId,
        title: 'Session 1',
        workingDirectory: '/test',
        model: 'claude-sonnet-4-20250514',
        createdAt: new Date().toISOString(),
        lastActivityAt: new Date().toISOString(),
        isArchived: false,
        eventCount: 10,
        messageCount: 5,
        turnCount: 2,
        totalInputTokens: 1000,
        totalOutputTokens: 500,
        lastTurnInputTokens: 500,
        totalCost: 0.05,
        totalCacheReadTokens: 0,
        totalCacheCreationTokens: 0,
        spawningSessionId: null,
        spawnType: null,
        spawnTask: null,
        tags: [],
      },
    ]),
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
      totalSessions: 1,
      activeSessions: 1,
      totalEvents: 10,
      totalTokensUsed: 1500,
      totalCost: 0.05,
    }),
    count: vi.fn().mockResolvedValue(1),
  };

  const mockEventRepo: IDashboardEventRepository = {
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
  };

  beforeEach(() => {
    vi.clearAllMocks();
    resetContainer();
    initializeContainer({
      sessions: mockSessionRepo,
      events: mockEventRepo,
    });
  });

  const wrapper = ({ children }: { children: React.ReactNode }) => (
    <DashboardProvider>{children}</DashboardProvider>
  );

  it('loads sessions on mount', async () => {
    const { result } = renderHook(() => useSessions(), { wrapper });

    // Initially loading
    expect(result.current.loading).toBe(true);

    // Wait for sessions to load
    await waitFor(() => {
      expect(result.current.loading).toBe(false);
    });

    expect(result.current.sessions).toHaveLength(1);
    expect(result.current.sessions[0].id).toBe('sess_1');
    expect(mockSessionRepo.listWithStats).toHaveBeenCalled();
  });

  it('provides refresh function', async () => {
    const { result } = renderHook(() => useSessions(), { wrapper });

    await waitFor(() => {
      expect(result.current.loading).toBe(false);
    });

    // Clear mock and refresh
    vi.clearAllMocks();

    await act(async () => {
      await result.current.refresh();
    });

    expect(mockSessionRepo.listWithStats).toHaveBeenCalled();
  });

  it('handles errors gracefully', async () => {
    const errorRepo = {
      ...mockSessionRepo,
      listWithStats: vi.fn().mockRejectedValue(new Error('Network error')),
    };

    resetContainer();
    initializeContainer({
      sessions: errorRepo,
      events: mockEventRepo,
    });

    const { result } = renderHook(() => useSessions(), { wrapper });

    await waitFor(() => {
      expect(result.current.loading).toBe(false);
    });

    expect(result.current.error).toBe('Network error');
    expect(result.current.sessions).toEqual([]);
  });
});
