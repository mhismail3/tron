/**
 * @fileoverview Tests for client identification handlers
 */

import { describe, it, expect, beforeEach } from 'vitest';
import {
  ClientRegistry,
  createClientRegistry,
  handleClientIdentify,
  handleClientList,
} from '../handler.js';
import { getDefaultCapabilities, DEFAULT_CAPABILITIES_BY_ROLE } from '../types.js';

describe('ClientRegistry', () => {
  let registry: ClientRegistry;

  beforeEach(() => {
    registry = createClientRegistry();
  });

  describe('register', () => {
    it('should register a new client', () => {
      registry.register('client-1');

      const client = registry.get('client-1');
      expect(client).toBeDefined();
      expect(client?.id).toBe('client-1');
      expect(client?.capabilities.size).toBe(0);
    });

    it('should set connectedAt time', () => {
      const before = new Date();
      registry.register('client-1');
      const after = new Date();

      const client = registry.get('client-1');
      expect(client?.connectedAt.getTime()).toBeGreaterThanOrEqual(before.getTime());
      expect(client?.connectedAt.getTime()).toBeLessThanOrEqual(after.getTime());
    });

    it('should accept custom connectedAt time', () => {
      const customDate = new Date('2024-01-01');
      registry.register('client-1', customDate);

      const client = registry.get('client-1');
      expect(client?.connectedAt).toEqual(customDate);
    });
  });

  describe('identify', () => {
    beforeEach(() => {
      registry.register('client-1');
    });

    it('should identify client with role', () => {
      const result = registry.identify('client-1', { role: 'ios-app' });

      expect(result.success).toBe(true);
      expect(result.clientId).toBe('client-1');

      const client = registry.get('client-1');
      expect(client?.role).toBe('ios-app');
    });

    it('should set default capabilities for role', () => {
      registry.identify('client-1', { role: 'ios-app' });

      const client = registry.get('client-1');
      expect(client?.capabilities.has('streaming')).toBe(true);
      expect(client?.capabilities.has('browser-frames')).toBe(true);
      expect(client?.capabilities.has('push-notifications')).toBe(true);
    });

    it('should merge custom capabilities with defaults', () => {
      registry.identify('client-1', {
        role: 'cli',
        capabilities: ['custom-capability'],
      });

      const client = registry.get('client-1');
      expect(client?.capabilities.has('streaming')).toBe(true); // default
      expect(client?.capabilities.has('custom-capability')).toBe(true);
    });

    it('should set version and platform', () => {
      registry.identify('client-1', {
        role: 'ios-app',
        version: '2.0.0',
        platform: 'iOS 18.0',
      });

      const client = registry.get('client-1');
      expect(client?.version).toBe('2.0.0');
      expect(client?.platform).toBe('iOS 18.0');
    });

    it('should set deviceId', () => {
      registry.identify('client-1', {
        role: 'ios-app',
        deviceId: 'device-abc-123',
      });

      const client = registry.get('client-1');
      expect(client?.deviceId).toBe('device-abc-123');
    });

    it('should set identifiedAt time', () => {
      const before = new Date();
      registry.identify('client-1', { role: 'cli' });
      const after = new Date();

      const client = registry.get('client-1');
      expect(client?.identifiedAt?.getTime()).toBeGreaterThanOrEqual(before.getTime());
      expect(client?.identifiedAt?.getTime()).toBeLessThanOrEqual(after.getTime());
    });

    it('should return false for unregistered client', () => {
      const result = registry.identify('unknown-client', { role: 'cli' });

      expect(result.success).toBe(false);
      expect(result.capabilities).toHaveLength(0);
    });

    it('should return capabilities in result', () => {
      const result = registry.identify('client-1', {
        role: 'ios-app',
        capabilities: ['extra-cap'],
      });

      expect(result.capabilities).toContain('streaming');
      expect(result.capabilities).toContain('extra-cap');
    });
  });

  describe('unregister', () => {
    it('should remove client', () => {
      registry.register('client-1');
      registry.unregister('client-1');

      expect(registry.get('client-1')).toBeUndefined();
    });

    it('should handle unregistering non-existent client', () => {
      expect(() => registry.unregister('unknown')).not.toThrow();
    });
  });

  describe('bindSession', () => {
    it('should bind session to client', () => {
      registry.register('client-1');
      registry.bindSession('client-1', 'session-abc');

      const client = registry.get('client-1');
      expect(client?.sessionId).toBe('session-abc');
    });

    it('should handle binding to non-existent client', () => {
      expect(() => registry.bindSession('unknown', 'session')).not.toThrow();
    });
  });

  describe('list', () => {
    it('should return all clients', () => {
      registry.register('client-1');
      registry.register('client-2');
      registry.identify('client-1', { role: 'ios-app' });

      const clients = registry.list();

      expect(clients).toHaveLength(2);
      expect(clients.find((c) => c.id === 'client-1')?.role).toBe('ios-app');
      expect(clients.find((c) => c.id === 'client-2')?.role).toBeUndefined();
    });

    it('should include all client info', () => {
      registry.register('client-1');
      registry.identify('client-1', {
        role: 'ios-app',
        version: '1.0.0',
        platform: 'iOS',
      });
      registry.bindSession('client-1', 'session-1');

      const clients = registry.list();
      const client = clients[0];

      expect(client.id).toBe('client-1');
      expect(client.role).toBe('ios-app');
      expect(client.version).toBe('1.0.0');
      expect(client.platform).toBe('iOS');
      expect(client.sessionId).toBe('session-1');
      expect(client.connectedAt).toBeDefined();
      expect(client.capabilities).toContain('streaming');
    });
  });

  describe('getByRole', () => {
    it('should return clients with matching role', () => {
      registry.register('client-1');
      registry.register('client-2');
      registry.register('client-3');
      registry.identify('client-1', { role: 'ios-app' });
      registry.identify('client-2', { role: 'ios-app' });
      registry.identify('client-3', { role: 'cli' });

      const iosClients = registry.getByRole('ios-app');

      expect(iosClients).toHaveLength(2);
      expect(iosClients.map((c) => c.id)).toContain('client-1');
      expect(iosClients.map((c) => c.id)).toContain('client-2');
    });
  });

  describe('getWithCapability', () => {
    it('should return clients with matching capability', () => {
      registry.register('client-1');
      registry.register('client-2');
      registry.identify('client-1', { role: 'ios-app' }); // has push-notifications
      registry.identify('client-2', { role: 'cli' }); // no push-notifications

      const clients = registry.getWithCapability('push-notifications');

      expect(clients).toHaveLength(1);
      expect(clients[0].id).toBe('client-1');
    });
  });

  describe('hasCapability', () => {
    it('should return true if client has capability', () => {
      registry.register('client-1');
      registry.identify('client-1', { role: 'ios-app' });

      expect(registry.hasCapability('client-1', 'streaming')).toBe(true);
    });

    it('should return false if client lacks capability', () => {
      registry.register('client-1');
      registry.identify('client-1', { role: 'cli' });

      expect(registry.hasCapability('client-1', 'push-notifications')).toBe(false);
    });

    it('should return false for unknown client', () => {
      expect(registry.hasCapability('unknown', 'streaming')).toBe(false);
    });
  });

  describe('count', () => {
    it('should return client count', () => {
      expect(registry.count()).toBe(0);

      registry.register('client-1');
      expect(registry.count()).toBe(1);

      registry.register('client-2');
      expect(registry.count()).toBe(2);

      registry.unregister('client-1');
      expect(registry.count()).toBe(1);
    });
  });
});

describe('getDefaultCapabilities', () => {
  it('should return ios-app capabilities', () => {
    const caps = getDefaultCapabilities('ios-app');
    expect(caps).toEqual(DEFAULT_CAPABILITIES_BY_ROLE['ios-app']);
  });

  it('should return streaming for unknown role', () => {
    const caps = getDefaultCapabilities('unknown-role');
    expect(caps).toEqual(['streaming']);
  });
});

describe('RPC handlers', () => {
  // Note: These tests use the global registry, so they're integration-like
  // In production, you'd want to inject the registry

  describe('handleClientList', () => {
    it('should return list of clients', async () => {
      const result = await handleClientList();
      expect(result.clients).toBeDefined();
      expect(Array.isArray(result.clients)).toBe(true);
    });
  });
});
