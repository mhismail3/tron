/**
 * @fileoverview Main entry point for @tron/core
 *
 * Tron Core: Agent loop, memory, hooks, tools, and providers
 *
 * This package provides the foundational components for building
 * the Tron coding agent system.
 */

// Re-export all types
export * from './types/index.js';

// Re-export logging
export * from './logging/index.js';

// Re-export auth
export * from './auth/index.js';

// Re-export providers
export * from './providers/index.js';

// Re-export tools
export * from './tools/index.js';

// Re-export memory
export * from './memory/index.js';

// Version info
export const VERSION = '0.1.0';
export const NAME = 'tron';
