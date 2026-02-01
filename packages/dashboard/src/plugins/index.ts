/**
 * @fileoverview Plugin system index
 */

// Registry
export {
  PluginRegistry,
  createPluginRegistry,
  getDefaultRegistry,
  resetDefaultRegistry,
} from './registry.js';

// Types
export type {
  EventRendererPlugin,
  EventRendererProps,
  FilterPlugin,
  ExportPlugin,
  ExportOptions,
  PluginMetadata,
} from './types.js';

// Built-in renderers
export { messageRendererPlugin } from './renderers/message-renderer.js';
export { toolRendererPlugin } from './renderers/tool-renderer.js';

// Built-in exporters
export { jsonExporterPlugin } from './exporters/json-exporter.js';
export { markdownExporterPlugin } from './exporters/markdown-exporter.js';

/**
 * Register all built-in plugins with the default registry
 */
import { getDefaultRegistry } from './registry.js';
import { messageRendererPlugin } from './renderers/message-renderer.js';
import { toolRendererPlugin } from './renderers/tool-renderer.js';
import { jsonExporterPlugin } from './exporters/json-exporter.js';
import { markdownExporterPlugin } from './exporters/markdown-exporter.js';

export function registerBuiltinPlugins(): void {
  const registry = getDefaultRegistry();

  // Renderers
  registry.registerEventRenderer(messageRendererPlugin);
  registry.registerEventRenderer(toolRendererPlugin);

  // Exporters
  registry.registerExporter(jsonExporterPlugin);
  registry.registerExporter(markdownExporterPlugin);
}
