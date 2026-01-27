/**
 * @fileoverview Settings Provider Tests
 *
 * Tests for the SettingsProvider interface implementations.
 */
import { describe, it, expect } from 'vitest';
import {
  DefaultSettingsProvider,
  MockSettingsProvider,
  createSettingsProvider,
  type SettingsProvider,
} from '../settings-provider.js';
import { DEFAULT_SETTINGS } from '../../settings/defaults.js';
import type { TronSettings } from '../../settings/types.js';

describe('SettingsProvider', () => {
  describe('DefaultSettingsProvider', () => {
    it('should return the correct settings section', () => {
      const provider = new DefaultSettingsProvider(DEFAULT_SETTINGS);

      const apiSettings = provider.get('api');
      expect(apiSettings).toBeDefined();
      expect(apiSettings.anthropic).toBeDefined();
      expect(apiSettings.anthropic.clientId).toBeDefined();
    });

    it('should return all settings', () => {
      const provider = new DefaultSettingsProvider(DEFAULT_SETTINGS);

      const allSettings = provider.getAll();
      expect(allSettings).toBe(DEFAULT_SETTINGS);
      expect(allSettings.version).toBeDefined();
      expect(allSettings.name).toBe('tron');
    });

    it('should get nested settings by path', () => {
      const provider = new DefaultSettingsProvider(DEFAULT_SETTINGS);

      const timeout = provider.getSetting<number>('tools.bash.defaultTimeoutMs');
      expect(typeof timeout).toBe('number');
      expect(timeout).toBeGreaterThan(0);
    });

    it('should return undefined for non-existent path', () => {
      const provider = new DefaultSettingsProvider(DEFAULT_SETTINGS);

      const result = provider.getSetting<string>('nonexistent.path.to.setting');
      expect(result).toBeUndefined();
    });

    it('should handle deep nested paths', () => {
      const provider = new DefaultSettingsProvider(DEFAULT_SETTINGS);

      const maxTokens = provider.getSetting<number>('context.compactor.maxTokens');
      expect(typeof maxTokens).toBe('number');
    });
  });

  describe('MockSettingsProvider', () => {
    it('should return the mock settings', () => {
      const mockSettings = { ...DEFAULT_SETTINGS };
      mockSettings.name = 'test-mock';

      const provider = new MockSettingsProvider(mockSettings);

      expect(provider.getAll().name).toBe('test-mock');
    });

    it('should allow overriding specific settings', () => {
      const provider = new MockSettingsProvider({ ...DEFAULT_SETTINGS });

      provider.override('tools.bash.defaultTimeoutMs', 99999);

      const timeout = provider.getSetting<number>('tools.bash.defaultTimeoutMs');
      expect(timeout).toBe(99999);
    });

    it('should create nested paths when overriding', () => {
      const provider = new MockSettingsProvider({ ...DEFAULT_SETTINGS });

      provider.override('custom.nested.setting', 'value');

      const result = provider.getSetting<string>('custom.nested.setting');
      expect(result).toBe('value');
    });

    it('should allow overriding top-level sections', () => {
      const provider = new MockSettingsProvider({ ...DEFAULT_SETTINGS });

      provider.override('name', 'overridden');

      expect(provider.get('name' as keyof TronSettings)).toBe('overridden');
    });
  });

  describe('createSettingsProvider', () => {
    it('should create a DefaultSettingsProvider', () => {
      const provider = createSettingsProvider(DEFAULT_SETTINGS);

      expect(provider).toBeInstanceOf(DefaultSettingsProvider);
      expect(provider.getAll()).toBe(DEFAULT_SETTINGS);
    });
  });

  describe('SettingsProvider contract', () => {
    // Test that both implementations satisfy the interface
    const implementations: Array<[string, () => SettingsProvider]> = [
      ['DefaultSettingsProvider', () => new DefaultSettingsProvider(DEFAULT_SETTINGS)],
      ['MockSettingsProvider', () => new MockSettingsProvider({ ...DEFAULT_SETTINGS })],
    ];

    it.each(implementations)(
      '%s should satisfy SettingsProvider interface',
      (_, createProvider) => {
        const provider = createProvider();

        // Should have get method
        expect(typeof provider.get).toBe('function');

        // Should have getAll method
        expect(typeof provider.getAll).toBe('function');

        // Should have getSetting method
        expect(typeof provider.getSetting).toBe('function');

        // Methods should work correctly
        expect(provider.get('api')).toBeDefined();
        expect(provider.getAll()).toBeDefined();
        expect(provider.getSetting('name')).toBe('tron');
      }
    );
  });

  describe('type safety', () => {
    it('should return correctly typed settings sections', () => {
      const provider = new DefaultSettingsProvider(DEFAULT_SETTINGS);

      // These should all type-check correctly
      const apiSettings = provider.get('api');
      const toolSettings = provider.get('tools');
      const serverSettings = provider.get('server');

      // Verify structure
      expect(apiSettings.anthropic.scopes).toBeInstanceOf(Array);
      expect(typeof toolSettings.bash.defaultTimeoutMs).toBe('number');
      expect(typeof serverSettings.wsPort).toBe('number');
    });
  });
});
