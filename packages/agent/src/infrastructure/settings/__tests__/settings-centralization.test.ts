/**
 * @fileoverview Settings Centralization Tests
 *
 * Validates that all new settings have correct defaults matching
 * the original hardcoded values, and that settings are properly
 * structured.
 */
import { describe, it, expect } from 'vitest';
import { DEFAULT_SETTINGS } from '../defaults.js';

describe('settings centralization', () => {
  describe('compaction trigger defaults', () => {
    const compactor = DEFAULT_SETTINGS.context.compactor;

    it('should have triggerTokenThreshold matching original hardcoded value', () => {
      expect(compactor.triggerTokenThreshold).toBe(0.70);
    });

    it('should have alertZoneThreshold matching original hardcoded value', () => {
      expect(compactor.alertZoneThreshold).toBe(0.50);
    });

    it('should have defaultTurnFallback matching original hardcoded value', () => {
      expect(compactor.defaultTurnFallback).toBe(8);
    });

    it('should have alertTurnFallback matching original hardcoded value', () => {
      expect(compactor.alertTurnFallback).toBe(5);
    });
  });

  describe('web tool defaults', () => {
    const web = DEFAULT_SETTINGS.tools.web;

    it('should have fetch timeout matching original hardcoded value', () => {
      expect(web.fetch.timeoutMs).toBe(30000);
    });

    it('should have cache TTL matching original hardcoded value', () => {
      expect(web.cache.ttlMs).toBe(15 * 60 * 1000);
    });

    it('should have cache max entries matching original hardcoded value', () => {
      expect(web.cache.maxEntries).toBe(100);
    });
  });

  describe('logging defaults', () => {
    it('should have dbLogLevel default to info', () => {
      expect(DEFAULT_SETTINGS.logging.dbLogLevel).toBe('info');
    });
  });

  describe('settings structure', () => {
    it('should have tools.web section', () => {
      expect(DEFAULT_SETTINGS.tools.web).toBeDefined();
      expect(DEFAULT_SETTINGS.tools.web.fetch).toBeDefined();
      expect(DEFAULT_SETTINGS.tools.web.cache).toBeDefined();
    });

    it('should have all compaction trigger fields', () => {
      const compactor = DEFAULT_SETTINGS.context.compactor;
      expect(compactor.triggerTokenThreshold).toBeDefined();
      expect(compactor.alertZoneThreshold).toBeDefined();
      expect(compactor.defaultTurnFallback).toBeDefined();
      expect(compactor.alertTurnFallback).toBeDefined();
    });

    it('should have valid compaction trigger ranges', () => {
      const compactor = DEFAULT_SETTINGS.context.compactor;
      expect(compactor.triggerTokenThreshold).toBeGreaterThan(0);
      expect(compactor.triggerTokenThreshold).toBeLessThanOrEqual(1);
      expect(compactor.alertZoneThreshold).toBeGreaterThan(0);
      expect(compactor.alertZoneThreshold).toBeLessThan(compactor.triggerTokenThreshold!);
      expect(compactor.defaultTurnFallback).toBeGreaterThan(0);
      expect(compactor.alertTurnFallback).toBeGreaterThan(0);
      expect(compactor.alertTurnFallback).toBeLessThanOrEqual(compactor.defaultTurnFallback!);
    });

    it('should have valid web cache ranges', () => {
      const cache = DEFAULT_SETTINGS.tools.web.cache;
      expect(cache.ttlMs).toBeGreaterThan(0);
      expect(cache.maxEntries).toBeGreaterThan(0);
    });
  });
});
