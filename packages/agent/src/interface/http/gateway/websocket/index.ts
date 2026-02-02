/**
 * @fileoverview WebSocket gateway module
 *
 * Handles WebSocket connections, client management, and message routing.
 *
 * @migration This wraps the existing gateway/websocket.ts during transition.
 */

// Re-export from current location during migration
export {
  TronWebSocketServer,
  type WebSocketServerConfig,
  type ClientConnection,
} from '../../../gateway/websocket.js';
