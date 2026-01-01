/**
 * @fileoverview Context module exports
 */

export {
  ContextLoader,
  createContextLoader,
  type ContextLoaderConfig,
  type ContextFile,
  type LoadedContext,
  type ContextSection,
} from './loader.js';

export {
  ContextAudit,
  getCurrentContextAudit,
  createContextAudit,
  clearContextAudit,
  type ContextAuditData,
  type ContextFileEntry,
  type HandoffEntry,
  type HookModification,
  type ToolEntry,
} from './audit.js';
