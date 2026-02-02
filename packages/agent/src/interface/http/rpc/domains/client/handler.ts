/**
 * @fileoverview Client identification RPC handlers
 *
 * Handles client.identify and client.list methods.
 */

import type {
  ClientIdentifyParams,
  ClientIdentifyResult,
  ClientInfo,
  IdentifiedClient,
} from './types.js';
import { getDefaultCapabilities } from './types.js';
import { createLogger } from '@infrastructure/logging/index.js';

const logger = createLogger('client-handler');

/**
 * Client registry for tracking identified clients
 */
export class ClientRegistry {
  private clients = new Map<string, IdentifiedClient>();

  /**
   * Register a new client connection
   */
  register(clientId: string, connectedAt: Date = new Date()): void {
    this.clients.set(clientId, {
      id: clientId,
      capabilities: new Set(),
      connectedAt,
    });
  }

  /**
   * Identify a client with role and capabilities
   */
  identify(
    clientId: string,
    params: ClientIdentifyParams
  ): ClientIdentifyResult {
    const client = this.clients.get(clientId);

    if (!client) {
      logger.warn('Client not found for identification', { clientId });
      return {
        success: false,
        clientId,
        capabilities: [],
      };
    }

    // Get default capabilities for role
    const defaultCaps = getDefaultCapabilities(params.role);

    // Merge provided capabilities with defaults
    const capabilities = params.capabilities
      ? [...new Set([...defaultCaps, ...params.capabilities])]
      : defaultCaps;

    // Update client
    client.role = params.role;
    client.capabilities = new Set(capabilities);
    client.version = params.version;
    client.deviceId = params.deviceId;
    client.platform = params.platform;
    client.identifiedAt = new Date();

    logger.info('Client identified', {
      clientId,
      role: params.role,
      capabilities: [...client.capabilities],
      version: params.version,
    });

    return {
      success: true,
      clientId,
      capabilities: [...client.capabilities],
    };
  }

  /**
   * Unregister a client (on disconnect)
   */
  unregister(clientId: string): void {
    this.clients.delete(clientId);
  }

  /**
   * Get a client by ID
   */
  get(clientId: string): IdentifiedClient | undefined {
    return this.clients.get(clientId);
  }

  /**
   * Update client's bound session
   */
  bindSession(clientId: string, sessionId: string): void {
    const client = this.clients.get(clientId);
    if (client) {
      client.sessionId = sessionId;
    }
  }

  /**
   * List all connected clients
   */
  list(): ClientInfo[] {
    return Array.from(this.clients.values()).map((client) => ({
      id: client.id,
      role: client.role,
      capabilities: [...client.capabilities],
      version: client.version,
      platform: client.platform,
      connectedAt: client.connectedAt.toISOString(),
      sessionId: client.sessionId,
    }));
  }

  /**
   * Get clients by role
   */
  getByRole(role: string): IdentifiedClient[] {
    return Array.from(this.clients.values()).filter((c) => c.role === role);
  }

  /**
   * Get clients with a specific capability
   */
  getWithCapability(capability: string): IdentifiedClient[] {
    return Array.from(this.clients.values()).filter((c) =>
      c.capabilities.has(capability)
    );
  }

  /**
   * Check if a client has a capability
   */
  hasCapability(clientId: string, capability: string): boolean {
    const client = this.clients.get(clientId);
    return client?.capabilities.has(capability) ?? false;
  }

  /**
   * Get client count
   */
  count(): number {
    return this.clients.size;
  }

  /**
   * Clear all clients (for testing)
   */
  clear(): void {
    this.clients.clear();
  }
}

/**
 * Singleton client registry instance
 */
let globalRegistry: ClientRegistry | null = null;

/**
 * Get the global client registry
 */
export function getClientRegistry(): ClientRegistry {
  if (!globalRegistry) {
    globalRegistry = new ClientRegistry();
  }
  return globalRegistry;
}

/**
 * Create a new client registry (for testing)
 */
export function createClientRegistry(): ClientRegistry {
  return new ClientRegistry();
}

/**
 * RPC handler for client.identify
 */
export async function handleClientIdentify(
  clientId: string,
  params: ClientIdentifyParams
): Promise<ClientIdentifyResult> {
  const registry = getClientRegistry();
  return registry.identify(clientId, params);
}

/**
 * RPC handler for client.list
 */
export async function handleClientList(): Promise<{ clients: ClientInfo[] }> {
  const registry = getClientRegistry();
  return { clients: registry.list() };
}
