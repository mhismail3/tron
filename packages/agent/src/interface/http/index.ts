/**
 * @fileoverview HTTP Server Module
 *
 * This module provides HTTP-based communication infrastructure for future
 * expansion beyond WebSocket-based RPC. Intended use cases include:
 * - Cron jobs and scheduled tasks
 * - Webhook handlers
 * - REST API endpoints
 * - HTTP-based integrations
 *
 * The server module provides:
 * - TronServer: Main server entry point
 * - Gateway: WebSocket and HTTP communication
 * - RPC: Remote procedure call handling with domain organization
 *
 * @status Future infrastructure - domains/ structure provides organized
 *         handler namespacing for when HTTP endpoints are fully implemented.
 */

// Main server
export { TronServer, type TronServerConfig, getDefaultServerSettings } from '../server.js';

// Gateway (WebSocket + HTTP)
export * from './gateway/index.js';

// RPC
export * from './rpc/index.js';
