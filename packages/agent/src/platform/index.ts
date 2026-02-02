/**
 * @fileoverview Platform module exports
 *
 * The platform module provides platform-specific integrations:
 * - Session management (worktrees, working directories)
 * - External integrations (terminal, MCP servers)
 * - Deployment (self-deployment tools)
 * - Productivity (canvas, productivity tools)
 * - Transcription (speech-to-text)
 */

export * from './session/index.js';
export * from './external/index.js';
export * from './deployment/index.js';
export * from './productivity/index.js';
export * from './transcription/index.js';
// browser.ts is a browser-safe re-export module, not a service module
