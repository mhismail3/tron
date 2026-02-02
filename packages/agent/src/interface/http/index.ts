/**
 * @fileoverview Server module exports
 *
 * The server module provides:
 * - TronServer: Main server entry point
 * - Gateway: WebSocket and HTTP communication
 * - RPC: Remote procedure call handling
 *
 * @migration This consolidates server components from various locations.
 */

// Main server
export { TronServer, type TronServerConfig, getDefaultServerSettings } from '../server.js';

// Gateway (WebSocket + HTTP)
export * from './gateway/index.js';

// RPC
export * from './rpc/index.js';
