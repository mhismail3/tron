/**
 * @fileoverview Gateway module exports
 *
 * The gateway module handles all external communication:
 * - WebSocket connections for real-time bidirectional communication
 * - HTTP endpoints for REST API and health checks
 */

export * from './websocket/index.js';
export * from './http/index.js';
