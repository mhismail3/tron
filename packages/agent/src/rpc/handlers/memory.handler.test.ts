/**
 * @fileoverview Tests for Memory RPC Handlers
 *
 * Tests memory.search, memory.addEntry, and memory.getHandoffs handlers.
 */

import { describe, it, expect, vi, beforeEach } from 'vitest';
import {
  createMemoryHandlers,
  handleMemorySearch,
  handleMemoryAddEntry,
  handleMemoryGetHandoffs,
} from './memory.handler.js';
import type { RpcRequest } from '../types.js';
import type { RpcContext } from '../handler.js';
import { MethodRegistry } from '../registry.js';

describe('Memory Handlers', () => {
  let mockContext: RpcContext;
  let mockSearchEntries: ReturnType<typeof vi.fn>;
  let mockAddEntry: ReturnType<typeof vi.fn>;
  let mockListHandoffs: ReturnType<typeof vi.fn>;

  beforeEach(() => {
    mockSearchEntries = vi.fn().mockResolvedValue({
      entries: [
        {
          id: 'entry-1',
          type: 'note',
          content: 'Test content',
          source: 'user',
          relevance: 0.95,
          timestamp: '2024-01-15T10:00:00Z',
        },
        {
          id: 'entry-2',
          type: 'code',
          content: 'function test() {}',
          source: 'assistant',
          timestamp: '2024-01-15T11:00:00Z',
        },
      ],
      totalCount: 2,
    });

    mockAddEntry = vi.fn().mockResolvedValue({ id: 'new-entry-123' });

    mockListHandoffs = vi.fn().mockResolvedValue([
      {
        id: 'handoff-1',
        sessionId: 'sess-123',
        summary: 'Worked on feature X',
        createdAt: '2024-01-15T12:00:00Z',
      },
      {
        id: 'handoff-2',
        sessionId: 'sess-456',
        summary: 'Fixed bug Y',
        createdAt: '2024-01-15T13:00:00Z',
      },
    ]);

    mockContext = {
      sessionManager: {} as any,
      agentManager: {} as any,
      memoryStore: {
        searchEntries: mockSearchEntries,
        addEntry: mockAddEntry,
        listHandoffs: mockListHandoffs,
      } as any,
    };
  });

  describe('handleMemorySearch', () => {
    it('should search memory entries', async () => {
      const request: RpcRequest = {
        id: '1',
        method: 'memory.search',
        params: { query: 'test', limit: 10 },
      };

      const response = await handleMemorySearch(request, mockContext);

      expect(response.success).toBe(true);
      expect(mockSearchEntries).toHaveBeenCalledWith({ query: 'test', limit: 10 });
      const result = response.result as { entries: any[]; totalCount: number };
      expect(result.entries).toHaveLength(2);
      expect(result.totalCount).toBe(2);
    });

    it('should handle empty params', async () => {
      const request: RpcRequest = {
        id: '1',
        method: 'memory.search',
      };

      const response = await handleMemorySearch(request, mockContext);

      expect(response.success).toBe(true);
      expect(mockSearchEntries).toHaveBeenCalledWith({});
    });

    it('should map entry fields correctly', async () => {
      const request: RpcRequest = {
        id: '1',
        method: 'memory.search',
        params: {},
      };

      const response = await handleMemorySearch(request, mockContext);

      expect(response.success).toBe(true);
      const result = response.result as { entries: any[] };

      // First entry has all fields
      expect(result.entries[0]).toEqual({
        id: 'entry-1',
        type: 'note',
        content: 'Test content',
        source: 'user',
        relevance: 0.95,
        timestamp: '2024-01-15T10:00:00Z',
      });

      // Second entry has default relevance
      expect(result.entries[1].relevance).toBe(1.0);
    });
  });

  describe('handleMemoryAddEntry', () => {
    it('should add a memory entry', async () => {
      const request: RpcRequest = {
        id: '1',
        method: 'memory.addEntry',
        params: {
          type: 'note',
          content: 'This is a test note',
          source: 'user',
        },
      };

      const response = await handleMemoryAddEntry(request, mockContext);

      expect(response.success).toBe(true);
      expect(mockAddEntry).toHaveBeenCalledWith({
        type: 'note',
        content: 'This is a test note',
        source: 'user',
      });
      const result = response.result as { id: string; created: boolean };
      expect(result.id).toBe('new-entry-123');
      expect(result.created).toBe(true);
    });

    it('should return error for missing type', async () => {
      const request: RpcRequest = {
        id: '1',
        method: 'memory.addEntry',
        params: { content: 'Some content' },
      };

      const response = await handleMemoryAddEntry(request, mockContext);

      expect(response.success).toBe(false);
      expect(response.error?.code).toBe('INVALID_PARAMS');
      expect(response.error?.message).toContain('type');
    });

    it('should return error for missing content', async () => {
      const request: RpcRequest = {
        id: '1',
        method: 'memory.addEntry',
        params: { type: 'note' },
      };

      const response = await handleMemoryAddEntry(request, mockContext);

      expect(response.success).toBe(false);
      expect(response.error?.code).toBe('INVALID_PARAMS');
      expect(response.error?.message).toContain('content');
    });

    it('should return error for empty params', async () => {
      const request: RpcRequest = {
        id: '1',
        method: 'memory.addEntry',
        params: {},
      };

      const response = await handleMemoryAddEntry(request, mockContext);

      expect(response.success).toBe(false);
      expect(response.error?.code).toBe('INVALID_PARAMS');
    });
  });

  describe('handleMemoryGetHandoffs', () => {
    it('should list handoffs', async () => {
      const request: RpcRequest = {
        id: '1',
        method: 'memory.getHandoffs',
      };

      const response = await handleMemoryGetHandoffs(request, mockContext);

      expect(response.success).toBe(true);
      expect(mockListHandoffs).toHaveBeenCalledWith(undefined, undefined);
      const result = response.result as { handoffs: any[] };
      expect(result.handoffs).toHaveLength(2);
    });

    it('should filter by workingDirectory', async () => {
      const request: RpcRequest = {
        id: '1',
        method: 'memory.getHandoffs',
        params: { workingDirectory: '/projects/myapp' },
      };

      const response = await handleMemoryGetHandoffs(request, mockContext);

      expect(response.success).toBe(true);
      expect(mockListHandoffs).toHaveBeenCalledWith('/projects/myapp', undefined);
    });

    it('should respect limit parameter', async () => {
      const request: RpcRequest = {
        id: '1',
        method: 'memory.getHandoffs',
        params: { limit: 5 },
      };

      const response = await handleMemoryGetHandoffs(request, mockContext);

      expect(response.success).toBe(true);
      expect(mockListHandoffs).toHaveBeenCalledWith(undefined, 5);
    });

    it('should map handoff fields correctly', async () => {
      const request: RpcRequest = {
        id: '1',
        method: 'memory.getHandoffs',
        params: {},
      };

      const response = await handleMemoryGetHandoffs(request, mockContext);

      expect(response.success).toBe(true);
      const result = response.result as { handoffs: any[] };
      expect(result.handoffs[0]).toEqual({
        id: 'handoff-1',
        sessionId: 'sess-123',
        summary: 'Worked on feature X',
        createdAt: '2024-01-15T12:00:00Z',
      });
    });
  });

  describe('createMemoryHandlers', () => {
    it('should create handlers for registration', () => {
      const handlers = createMemoryHandlers();

      expect(handlers).toHaveLength(3);
      expect(handlers.map(h => h.method)).toContain('memory.search');
      expect(handlers.map(h => h.method)).toContain('memory.addEntry');
      expect(handlers.map(h => h.method)).toContain('memory.getHandoffs');
    });

    it('should have correct options for memory.addEntry', () => {
      const handlers = createMemoryHandlers();
      const addEntryHandler = handlers.find(h => h.method === 'memory.addEntry');

      expect(addEntryHandler?.options?.requiredParams).toContain('type');
      expect(addEntryHandler?.options?.requiredParams).toContain('content');
      expect(addEntryHandler?.options?.requiredManagers).toContain('memoryStore');
    });

    it('should have memoryStore as required manager for all handlers', () => {
      const handlers = createMemoryHandlers();

      for (const handler of handlers) {
        expect(handler.options?.requiredManagers).toContain('memoryStore');
      }
    });
  });

  describe('Registry Integration', () => {
    it('should register and dispatch memory handlers', async () => {
      const registry = new MethodRegistry();
      const handlers = createMemoryHandlers();
      registry.registerAll(handlers);

      expect(registry.has('memory.search')).toBe(true);
      expect(registry.has('memory.addEntry')).toBe(true);
      expect(registry.has('memory.getHandoffs')).toBe(true);

      // Test memory.search through registry
      const request: RpcRequest = {
        id: '1',
        method: 'memory.search',
        params: { query: 'test' },
      };

      const response = await registry.dispatch(request, mockContext);
      expect(response.success).toBe(true);
      expect(response.result).toHaveProperty('entries');
      expect(response.result).toHaveProperty('totalCount');
    });

    it('should dispatch memory.addEntry through registry', async () => {
      const registry = new MethodRegistry();
      const handlers = createMemoryHandlers();
      registry.registerAll(handlers);

      const request: RpcRequest = {
        id: '1',
        method: 'memory.addEntry',
        params: { type: 'note', content: 'Test content' },
      };

      const response = await registry.dispatch(request, mockContext);
      expect(response.success).toBe(true);
      expect(response.result).toHaveProperty('id');
      expect(response.result).toHaveProperty('created');
    });

    it('should dispatch memory.getHandoffs through registry', async () => {
      const registry = new MethodRegistry();
      const handlers = createMemoryHandlers();
      registry.registerAll(handlers);

      const request: RpcRequest = {
        id: '1',
        method: 'memory.getHandoffs',
      };

      const response = await registry.dispatch(request, mockContext);
      expect(response.success).toBe(true);
      expect(response.result).toHaveProperty('handoffs');
    });
  });
});
