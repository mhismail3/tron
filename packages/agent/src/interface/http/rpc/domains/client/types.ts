/**
 * @fileoverview Client identification types
 *
 * Types for client role declarations and capability tracking.
 */

/**
 * Client role - identifies the type of client connecting
 */
export type ClientRole = 'ios-app' | 'dashboard' | 'claude-code' | 'cli' | 'web' | string;

/**
 * Client capability - features the client supports
 */
export type ClientCapability =
  | 'streaming'           // Real-time streaming updates
  | 'browser-frames'      // Live browser frame streaming
  | 'thinking-blocks'     // Extended thinking content
  | 'tool-streaming'      // Streaming tool output
  | 'voice-input'         // Voice transcription
  | 'push-notifications'  // Push notification support
  | 'ui-canvas'           // Custom UI rendering
  | string;

/**
 * Client identification request parameters
 */
export interface ClientIdentifyParams {
  /** Client role */
  role: ClientRole;
  /** Client capabilities */
  capabilities?: ClientCapability[];
  /** Client version (semver) */
  version?: string;
  /** Optional device ID for mobile clients */
  deviceId?: string;
  /** Optional platform info */
  platform?: string;
}

/**
 * Extended client connection with identification
 */
export interface IdentifiedClient {
  /** Connection ID */
  id: string;
  /** Client role (after identification) */
  role?: ClientRole;
  /** Client capabilities */
  capabilities: Set<ClientCapability>;
  /** Client version */
  version?: string;
  /** Device ID (for mobile clients) */
  deviceId?: string;
  /** Platform info */
  platform?: string;
  /** When the client identified itself */
  identifiedAt?: Date;
  /** Connection time */
  connectedAt: Date;
  /** Bound session ID (if any) */
  sessionId?: string;
}

/**
 * Client identification result
 */
export interface ClientIdentifyResult {
  /** Whether identification was accepted */
  success: boolean;
  /** Client ID */
  clientId: string;
  /** Acknowledged capabilities */
  capabilities: ClientCapability[];
}

/**
 * Client info for listing
 */
export interface ClientInfo {
  /** Client ID */
  id: string;
  /** Client role */
  role?: ClientRole;
  /** Client capabilities */
  capabilities: ClientCapability[];
  /** Client version */
  version?: string;
  /** Platform info */
  platform?: string;
  /** Connection time */
  connectedAt: string;
  /** Bound session ID */
  sessionId?: string;
}

/**
 * Default capabilities by role
 */
export const DEFAULT_CAPABILITIES_BY_ROLE: Record<ClientRole, ClientCapability[]> = {
  'ios-app': ['streaming', 'browser-frames', 'thinking-blocks', 'voice-input', 'push-notifications', 'ui-canvas'],
  'dashboard': ['streaming', 'browser-frames'],
  'claude-code': ['streaming', 'thinking-blocks', 'tool-streaming'],
  'cli': ['streaming'],
  'web': ['streaming', 'browser-frames', 'thinking-blocks'],
};

/**
 * Get default capabilities for a role
 */
export function getDefaultCapabilities(role: ClientRole): ClientCapability[] {
  return DEFAULT_CAPABILITIES_BY_ROLE[role] ?? ['streaming'];
}
