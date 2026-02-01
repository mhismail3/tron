/**
 * @fileoverview Tests for plugin registry
 */

import { describe, it, expect, vi, beforeEach } from 'vitest';
import {
  PluginRegistry,
  createPluginRegistry,
} from '../registry.js';
import type { EventRendererPlugin, ExportPlugin } from '../types.js';
import type { TronSessionEvent, SessionId, WorkspaceId, EventId } from '@tron/agent';

describe('PluginRegistry', () => {
  let registry: PluginRegistry;

  beforeEach(() => {
    registry = createPluginRegistry();
  });

  describe('event renderers', () => {
    it('registers and retrieves event renderer plugins', () => {
      const mockRenderer: EventRendererPlugin = {
        id: 'test-renderer',
        name: 'Test Renderer',
        canRender: () => true,
        priority: 10,
        render: () => null,
      };

      registry.registerEventRenderer(mockRenderer);

      const renderers = registry.getEventRenderers();
      expect(renderers).toContain(mockRenderer);
    });

    it('finds renderer for event by priority', () => {
      const lowPriorityRenderer: EventRendererPlugin = {
        id: 'low-priority',
        name: 'Low Priority',
        canRender: (e) => e.type === 'message.user',
        priority: 5,
        render: () => 'low',
      };

      const highPriorityRenderer: EventRendererPlugin = {
        id: 'high-priority',
        name: 'High Priority',
        canRender: (e) => e.type === 'message.user',
        priority: 20,
        render: () => 'high',
      };

      registry.registerEventRenderer(lowPriorityRenderer);
      registry.registerEventRenderer(highPriorityRenderer);

      const event = createMockEvent('message.user');
      const renderer = registry.findRendererForEvent(event);

      expect(renderer).toBe(highPriorityRenderer);
    });

    it('returns undefined when no renderer matches', () => {
      const renderer: EventRendererPlugin = {
        id: 'test-renderer',
        name: 'Test Renderer',
        canRender: () => false,
        priority: 10,
        render: () => null,
      };

      registry.registerEventRenderer(renderer);

      const event = createMockEvent('session.start');
      const found = registry.findRendererForEvent(event);

      expect(found).toBeUndefined();
    });

    it('unregisters event renderer', () => {
      const renderer: EventRendererPlugin = {
        id: 'test-renderer',
        name: 'Test Renderer',
        canRender: () => true,
        priority: 10,
        render: () => null,
      };

      registry.registerEventRenderer(renderer);
      expect(registry.getEventRenderers()).toHaveLength(1);

      registry.unregisterEventRenderer('test-renderer');
      expect(registry.getEventRenderers()).toHaveLength(0);
    });
  });

  describe('export plugins', () => {
    it('registers and retrieves export plugins', () => {
      const mockExporter: ExportPlugin = {
        id: 'json-export',
        name: 'JSON Export',
        extension: 'json',
        mimeType: 'application/json',
        export: vi.fn().mockResolvedValue('{}'),
      };

      registry.registerExporter(mockExporter);

      const exporters = registry.getExporters();
      expect(exporters).toContain(mockExporter);
    });

    it('gets exporter by id', () => {
      const exporter: ExportPlugin = {
        id: 'markdown-export',
        name: 'Markdown Export',
        extension: 'md',
        mimeType: 'text/markdown',
        export: vi.fn().mockResolvedValue('# Session'),
      };

      registry.registerExporter(exporter);

      const found = registry.getExporter('markdown-export');
      expect(found).toBe(exporter);
    });

    it('returns undefined for unknown exporter', () => {
      const found = registry.getExporter('unknown');
      expect(found).toBeUndefined();
    });

    it('unregisters exporter', () => {
      const exporter: ExportPlugin = {
        id: 'json-export',
        name: 'JSON Export',
        extension: 'json',
        mimeType: 'application/json',
        export: vi.fn().mockResolvedValue('{}'),
      };

      registry.registerExporter(exporter);
      expect(registry.getExporters()).toHaveLength(1);

      registry.unregisterExporter('json-export');
      expect(registry.getExporters()).toHaveLength(0);
    });
  });
});

function createMockEvent(type: string): TronSessionEvent {
  return {
    id: 'evt_test' as EventId,
    sessionId: 'sess_test' as SessionId,
    workspaceId: 'ws_test' as WorkspaceId,
    parentId: null,
    timestamp: new Date().toISOString(),
    sequence: 0,
    type: type as any,
    payload: {},
  } as TronSessionEvent;
}
