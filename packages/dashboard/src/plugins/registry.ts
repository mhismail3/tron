/**
 * @fileoverview Plugin registry for dashboard extensions
 */

import type { TronSessionEvent } from '@tron/agent';
import type {
  EventRendererPlugin,
  FilterPlugin,
  ExportPlugin,
} from './types.js';

/**
 * Plugin registry that manages all dashboard plugins
 */
export class PluginRegistry {
  private eventRenderers: Map<string, EventRendererPlugin> = new Map();
  private filters: Map<string, FilterPlugin> = new Map();
  private exporters: Map<string, ExportPlugin> = new Map();

  // ===========================================================================
  // Event Renderers
  // ===========================================================================

  /**
   * Register an event renderer plugin
   */
  registerEventRenderer(plugin: EventRendererPlugin): void {
    this.eventRenderers.set(plugin.id, plugin);
  }

  /**
   * Unregister an event renderer plugin
   */
  unregisterEventRenderer(id: string): void {
    this.eventRenderers.delete(id);
  }

  /**
   * Get all registered event renderers
   */
  getEventRenderers(): EventRendererPlugin[] {
    return Array.from(this.eventRenderers.values());
  }

  /**
   * Find the best renderer for an event
   */
  findRendererForEvent(event: TronSessionEvent): EventRendererPlugin | undefined {
    const renderers = this.getEventRenderers()
      .filter((r) => r.canRender(event))
      .sort((a, b) => b.priority - a.priority);

    return renderers[0];
  }

  // ===========================================================================
  // Filters
  // ===========================================================================

  /**
   * Register a filter plugin
   */
  registerFilter(plugin: FilterPlugin): void {
    this.filters.set(plugin.id, plugin);
  }

  /**
   * Unregister a filter plugin
   */
  unregisterFilter(id: string): void {
    this.filters.delete(id);
  }

  /**
   * Get all registered filters
   */
  getFilters(): FilterPlugin[] {
    return Array.from(this.filters.values());
  }

  /**
   * Get a filter by ID
   */
  getFilter(id: string): FilterPlugin | undefined {
    return this.filters.get(id);
  }

  // ===========================================================================
  // Exporters
  // ===========================================================================

  /**
   * Register an export plugin
   */
  registerExporter(plugin: ExportPlugin): void {
    this.exporters.set(plugin.id, plugin);
  }

  /**
   * Unregister an export plugin
   */
  unregisterExporter(id: string): void {
    this.exporters.delete(id);
  }

  /**
   * Get all registered exporters
   */
  getExporters(): ExportPlugin[] {
    return Array.from(this.exporters.values());
  }

  /**
   * Get an exporter by ID
   */
  getExporter(id: string): ExportPlugin | undefined {
    return this.exporters.get(id);
  }

  // ===========================================================================
  // Utilities
  // ===========================================================================

  /**
   * Clear all plugins
   */
  clear(): void {
    this.eventRenderers.clear();
    this.filters.clear();
    this.exporters.clear();
  }
}

/**
 * Create a new plugin registry
 */
export function createPluginRegistry(): PluginRegistry {
  return new PluginRegistry();
}

/**
 * Default global registry
 */
let defaultRegistry: PluginRegistry | null = null;

/**
 * Get the default registry (creates one if needed)
 */
export function getDefaultRegistry(): PluginRegistry {
  if (!defaultRegistry) {
    defaultRegistry = createPluginRegistry();
  }
  return defaultRegistry;
}

/**
 * Reset the default registry
 */
export function resetDefaultRegistry(): void {
  defaultRegistry = null;
}
