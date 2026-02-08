/**
 * @fileoverview Tests for Memory RPC Handlers
 *
 * Tests memory.getLedger handler using the registry dispatch pattern.
 */

import { describe, it, expect, vi, beforeEach } from 'vitest';
import { createMemoryHandlers } from '../memory.handler.js';
import type { RpcRequest } from '../../types.js';
import type { RpcContext } from '../../handler.js';
import { MethodRegistry } from '../../registry.js';

describe('Memory Handlers', () => {
  let registry: MethodRegistry;
  let mockContext: RpcContext;
  let mockGetLedgerEntries: ReturnType<typeof vi.fn>;

  const sampleEntries = [
    {
      id: 'evt-1',
      sessionId: 'sess-1',
      timestamp: '2025-01-15T10:00:00Z',
      title: 'Add login feature',
      entryType: 'feature',
      input: 'Build a login page',
      actions: ['Created LoginView.swift', 'Added auth logic'],
      decisions: [{ choice: 'JWT', reason: 'Stateless auth' }],
      lessons: ['Always validate tokens server-side'],
      insights: [],
      tags: ['ios', 'auth'],
      files: [{ path: 'Sources/LoginView.swift', op: 'C', why: 'New view' }],
      model: 'claude-opus-4',
      tokenCost: { input: 1000, output: 500 },
    },
    {
      id: 'evt-2',
      sessionId: 'sess-2',
      timestamp: '2025-01-14T10:00:00Z',
      title: 'Fix crash on launch',
      entryType: 'bugfix',
      input: 'App crashes on iOS 18',
      actions: ['Fixed nil force unwrap'],
      decisions: [],
      lessons: ['Avoid force unwraps'],
      insights: ['Crash was in AppDelegate'],
      tags: ['ios', 'bugfix'],
      files: [{ path: 'Sources/AppDelegate.swift', op: 'M', why: 'Fix crash' }],
      model: 'claude-sonnet-4',
      tokenCost: { input: 500, output: 200 },
    },
    {
      id: 'evt-3',
      sessionId: 'sess-3',
      timestamp: '2025-01-13T10:00:00Z',
      title: 'Refactor networking',
      entryType: 'refactor',
      input: 'Clean up API client',
      actions: ['Extracted protocol'],
      decisions: [],
      lessons: [],
      insights: [],
      tags: ['refactor'],
      files: [],
      model: 'claude-opus-4',
      tokenCost: { input: 800, output: 400 },
    },
  ];

  beforeEach(() => {
    registry = new MethodRegistry();
    registry.registerAll(createMemoryHandlers());

    mockGetLedgerEntries = vi.fn().mockResolvedValue({
      entries: sampleEntries,
      hasMore: false,
      totalCount: 3,
    });

    mockContext = {
      sessionManager: {} as any,
      agentManager: {} as any,
      eventStore: {
        getEventHistory: vi.fn(),
        getEventsSince: vi.fn(),
        appendEvent: vi.fn(),
        getTreeVisualization: vi.fn(),
        getBranches: vi.fn(),
        getSubtree: vi.fn(),
        getAncestors: vi.fn(),
        searchContent: vi.fn(),
        deleteMessage: vi.fn(),
        getLedgerEntries: mockGetLedgerEntries,
      } as any,
    };
  });

  describe('memory.getLedger', () => {
    it('should return paginated ledger entries', async () => {
      const request: RpcRequest = {
        id: '1',
        method: 'memory.getLedger',
        params: { workingDirectory: '/Users/test/project' },
      };

      const response = await registry.dispatch(request, mockContext);

      expect(response.success).toBe(true);
      expect(mockGetLedgerEntries).toHaveBeenCalledWith('/Users/test/project', {
        limit: undefined,
        offset: undefined,
        tags: undefined,
      });
      const result = response.result as { entries: any[]; hasMore: boolean; totalCount: number };
      expect(result.entries).toHaveLength(3);
      expect(result.hasMore).toBe(false);
      expect(result.totalCount).toBe(3);
    });

    it('should pass pagination options', async () => {
      const request: RpcRequest = {
        id: '1',
        method: 'memory.getLedger',
        params: { workingDirectory: '/Users/test/project', limit: 2, offset: 1 },
      };

      await registry.dispatch(request, mockContext);

      expect(mockGetLedgerEntries).toHaveBeenCalledWith('/Users/test/project', {
        limit: 2,
        offset: 1,
        tags: undefined,
      });
    });

    it('should pass tag filter', async () => {
      const request: RpcRequest = {
        id: '1',
        method: 'memory.getLedger',
        params: { workingDirectory: '/Users/test/project', tags: ['ios', 'auth'] },
      };

      await registry.dispatch(request, mockContext);

      expect(mockGetLedgerEntries).toHaveBeenCalledWith('/Users/test/project', {
        limit: undefined,
        offset: undefined,
        tags: ['ios', 'auth'],
      });
    });

    it('should return error for missing workingDirectory', async () => {
      const request: RpcRequest = {
        id: '1',
        method: 'memory.getLedger',
        params: {},
      };

      const response = await registry.dispatch(request, mockContext);

      expect(response.success).toBe(false);
      expect(response.error?.code).toBe('INVALID_PARAMS');
      expect(response.error?.message).toContain('workingDirectory');
    });

    it('should return NOT_AVAILABLE without eventStore', async () => {
      const contextWithoutEventStore: RpcContext = {
        sessionManager: {} as any,
        agentManager: {} as any,
      };

      const request: RpcRequest = {
        id: '1',
        method: 'memory.getLedger',
        params: { workingDirectory: '/test' },
      };

      const response = await registry.dispatch(request, contextWithoutEventStore);

      expect(response.success).toBe(false);
      expect(response.error?.code).toBe('NOT_AVAILABLE');
    });

    it('should handle empty result', async () => {
      mockGetLedgerEntries.mockResolvedValue({
        entries: [],
        hasMore: false,
        totalCount: 0,
      });

      const request: RpcRequest = {
        id: '1',
        method: 'memory.getLedger',
        params: { workingDirectory: '/empty/workspace' },
      };

      const response = await registry.dispatch(request, mockContext);

      expect(response.success).toBe(true);
      const result = response.result as { entries: any[]; hasMore: boolean; totalCount: number };
      expect(result.entries).toEqual([]);
      expect(result.hasMore).toBe(false);
      expect(result.totalCount).toBe(0);
    });

    it('should handle pagination with hasMore=true', async () => {
      mockGetLedgerEntries.mockResolvedValue({
        entries: sampleEntries.slice(0, 2),
        hasMore: true,
        totalCount: 3,
      });

      const request: RpcRequest = {
        id: '1',
        method: 'memory.getLedger',
        params: { workingDirectory: '/test', limit: 2, offset: 0 },
      };

      const response = await registry.dispatch(request, mockContext);

      expect(response.success).toBe(true);
      const result = response.result as { entries: any[]; hasMore: boolean; totalCount: number };
      expect(result.entries).toHaveLength(2);
      expect(result.hasMore).toBe(true);
      expect(result.totalCount).toBe(3);
    });
  });

  describe('createMemoryHandlers', () => {
    it('should create handlers for registration', () => {
      const handlers = createMemoryHandlers();

      expect(handlers).toHaveLength(1);
      expect(handlers[0].method).toBe('memory.getLedger');
    });

    it('should have eventStore as required manager', () => {
      const handlers = createMemoryHandlers();

      expect(handlers[0].options?.requiredManagers).toContain('eventStore');
    });

    it('should require workingDirectory param', () => {
      const handlers = createMemoryHandlers();

      expect(handlers[0].options?.requiredParams).toContain('workingDirectory');
    });
  });
});
