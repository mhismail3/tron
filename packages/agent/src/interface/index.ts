/**
 * @fileoverview Interface module exports
 *
 * The interface module provides external API interfaces including:
 * - HTTP server (Express/Hono)
 * - Gateway (WebSocket, HTTP API)
 * - RPC handlers
 * - UI components
 */

export * from './rpc/index.js';
export * from './gateway/index.js';
export * from './ui/index.js';
export { TronServer, type TronServerConfig } from './server.js';
