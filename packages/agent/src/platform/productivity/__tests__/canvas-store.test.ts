/**
 * @fileoverview Canvas Store Tests
 *
 * Tests for canvas artifact persistence including:
 * - Save/load operations
 * - Delete operations
 * - List operations
 * - Cleanup of old artifacts
 * - Error handling
 */

import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import * as fs from 'fs';
import * as fsAsync from 'fs/promises';
import * as path from 'path';
import type { CanvasArtifact } from '../canvas-store.js';

// Mock the settings module
vi.mock('@infrastructure/settings/index.js', () => ({
  getTronDataDir: vi.fn(() => '/tmp/test-tron-data'),
}));

// Mock logging
vi.mock('@infrastructure/logging/index.js', () => ({
  createLogger: vi.fn(() => ({
    info: vi.fn(),
    warn: vi.fn(),
    error: vi.fn(),
    debug: vi.fn(),
  })),
  categorizeError: vi.fn((e) => ({
    code: 'UNKNOWN',
    message: e?.message || String(e),
    retryable: false,
    category: 'unknown',
  })),
  LogErrorCategory: {
    DATABASE: 'database',
  },
}));

const TEST_DIR = '/tmp/test-tron-data/artifacts/canvases';

describe('canvas-store', () => {
  beforeEach(() => {
    vi.clearAllMocks();
    // Clean up test directory
    if (fs.existsSync(TEST_DIR)) {
      fs.rmSync(TEST_DIR, { recursive: true });
    }
  });

  afterEach(() => {
    // Clean up
    if (fs.existsSync(TEST_DIR)) {
      fs.rmSync(TEST_DIR, { recursive: true });
    }
  });

  describe('getCanvasArtifactsDir', () => {
    it('returns the correct artifacts directory path', async () => {
      vi.resetModules();
      const { getCanvasArtifactsDir } = await import('../canvas-store.js');

      const dir = getCanvasArtifactsDir();
      expect(dir).toBe('/tmp/test-tron-data/artifacts/canvases');
    });
  });

  describe('ensureCanvasArtifactsDir', () => {
    it('creates directory if it does not exist', async () => {
      vi.resetModules();
      const { ensureCanvasArtifactsDir } = await import('../canvas-store.js');

      expect(fs.existsSync(TEST_DIR)).toBe(false);

      ensureCanvasArtifactsDir();

      expect(fs.existsSync(TEST_DIR)).toBe(true);
    });

    it('does nothing if directory already exists', async () => {
      fs.mkdirSync(TEST_DIR, { recursive: true });

      vi.resetModules();
      const { ensureCanvasArtifactsDir } = await import('../canvas-store.js');

      // Should not throw
      expect(() => ensureCanvasArtifactsDir()).not.toThrow();
      expect(fs.existsSync(TEST_DIR)).toBe(true);
    });
  });

  describe('saveCanvasArtifact', () => {
    it('saves artifact to disk', async () => {
      vi.resetModules();
      const { saveCanvasArtifact } = await import('../canvas-store.js');

      const artifact: CanvasArtifact = {
        canvasId: 'test-canvas-1',
        sessionId: 'session-123',
        title: 'Test Canvas',
        ui: { type: 'container', children: [] },
        state: { count: 0 },
        savedAt: new Date().toISOString(),
      };

      await saveCanvasArtifact(artifact);

      const filePath = path.join(TEST_DIR, 'test-canvas-1.json');
      expect(fs.existsSync(filePath)).toBe(true);

      const content = JSON.parse(fs.readFileSync(filePath, 'utf-8'));
      expect(content.canvasId).toBe('test-canvas-1');
      expect(content.sessionId).toBe('session-123');
      expect(content.title).toBe('Test Canvas');
    });

    it('creates artifacts directory if needed', async () => {
      vi.resetModules();
      const { saveCanvasArtifact } = await import('../canvas-store.js');

      expect(fs.existsSync(TEST_DIR)).toBe(false);

      await saveCanvasArtifact({
        canvasId: 'test-canvas',
        sessionId: 'session',
        ui: {},
        savedAt: new Date().toISOString(),
      });

      expect(fs.existsSync(TEST_DIR)).toBe(true);
    });

    it('overwrites existing artifact', async () => {
      vi.resetModules();
      const { saveCanvasArtifact, loadCanvasArtifact } = await import('../canvas-store.js');

      const artifact1: CanvasArtifact = {
        canvasId: 'test-canvas',
        sessionId: 'session-1',
        ui: { version: 1 },
        savedAt: new Date().toISOString(),
      };

      const artifact2: CanvasArtifact = {
        canvasId: 'test-canvas',
        sessionId: 'session-2',
        ui: { version: 2 },
        savedAt: new Date().toISOString(),
      };

      await saveCanvasArtifact(artifact1);
      await saveCanvasArtifact(artifact2);

      const loaded = await loadCanvasArtifact('test-canvas');
      expect(loaded?.sessionId).toBe('session-2');
      expect((loaded?.ui as any).version).toBe(2);
    });
  });

  describe('loadCanvasArtifact', () => {
    it('loads existing artifact from disk', async () => {
      vi.resetModules();
      const { saveCanvasArtifact, loadCanvasArtifact } = await import('../canvas-store.js');

      const artifact: CanvasArtifact = {
        canvasId: 'load-test',
        sessionId: 'session-456',
        title: 'Load Test',
        ui: { components: ['a', 'b'] },
        state: { active: true },
        savedAt: '2024-01-15T10:00:00Z',
      };

      await saveCanvasArtifact(artifact);
      const loaded = await loadCanvasArtifact('load-test');

      expect(loaded).not.toBeNull();
      expect(loaded!.canvasId).toBe('load-test');
      expect(loaded!.sessionId).toBe('session-456');
      expect(loaded!.title).toBe('Load Test');
      expect(loaded!.savedAt).toBe('2024-01-15T10:00:00Z');
    });

    it('returns null for non-existent artifact', async () => {
      vi.resetModules();
      const { loadCanvasArtifact } = await import('../canvas-store.js');

      const loaded = await loadCanvasArtifact('nonexistent-canvas');
      expect(loaded).toBeNull();
    });

    it('returns null for corrupted JSON', async () => {
      vi.resetModules();
      fs.mkdirSync(TEST_DIR, { recursive: true });
      fs.writeFileSync(path.join(TEST_DIR, 'corrupted.json'), 'not valid json');

      const { loadCanvasArtifact } = await import('../canvas-store.js');
      const loaded = await loadCanvasArtifact('corrupted');

      expect(loaded).toBeNull();
    });
  });

  describe('canvasArtifactExists', () => {
    it('returns true for existing artifact', async () => {
      vi.resetModules();
      const { saveCanvasArtifact, canvasArtifactExists } = await import('../canvas-store.js');

      await saveCanvasArtifact({
        canvasId: 'exists-test',
        sessionId: 'session',
        ui: {},
        savedAt: new Date().toISOString(),
      });

      expect(canvasArtifactExists('exists-test')).toBe(true);
    });

    it('returns false for non-existent artifact', async () => {
      vi.resetModules();
      const { canvasArtifactExists } = await import('../canvas-store.js');

      expect(canvasArtifactExists('nonexistent')).toBe(false);
    });
  });

  describe('deleteCanvasArtifact', () => {
    it('deletes existing artifact', async () => {
      vi.resetModules();
      const { saveCanvasArtifact, deleteCanvasArtifact, canvasArtifactExists } = await import(
        '../canvas-store.js'
      );

      await saveCanvasArtifact({
        canvasId: 'delete-test',
        sessionId: 'session',
        ui: {},
        savedAt: new Date().toISOString(),
      });

      expect(canvasArtifactExists('delete-test')).toBe(true);

      const result = await deleteCanvasArtifact('delete-test');

      expect(result).toBe(true);
      expect(canvasArtifactExists('delete-test')).toBe(false);
    });

    it('returns false for non-existent artifact', async () => {
      vi.resetModules();
      const { deleteCanvasArtifact } = await import('../canvas-store.js');

      const result = await deleteCanvasArtifact('nonexistent');
      expect(result).toBe(false);
    });
  });

  describe('listCanvasArtifacts', () => {
    it('returns empty array when no artifacts exist', async () => {
      vi.resetModules();
      const { listCanvasArtifacts } = await import('../canvas-store.js');

      const list = await listCanvasArtifacts();
      expect(list).toEqual([]);
    });

    it('returns list of canvas IDs', async () => {
      vi.resetModules();
      const { saveCanvasArtifact, listCanvasArtifacts } = await import('../canvas-store.js');

      await saveCanvasArtifact({
        canvasId: 'canvas-a',
        sessionId: 'session',
        ui: {},
        savedAt: new Date().toISOString(),
      });

      await saveCanvasArtifact({
        canvasId: 'canvas-b',
        sessionId: 'session',
        ui: {},
        savedAt: new Date().toISOString(),
      });

      await saveCanvasArtifact({
        canvasId: 'canvas-c',
        sessionId: 'session',
        ui: {},
        savedAt: new Date().toISOString(),
      });

      const list = await listCanvasArtifacts();

      expect(list).toHaveLength(3);
      expect(list).toContain('canvas-a');
      expect(list).toContain('canvas-b');
      expect(list).toContain('canvas-c');
    });

    it('filters out non-json files', async () => {
      vi.resetModules();
      fs.mkdirSync(TEST_DIR, { recursive: true });
      fs.writeFileSync(path.join(TEST_DIR, 'valid.json'), '{}');
      fs.writeFileSync(path.join(TEST_DIR, 'readme.txt'), 'not a canvas');
      fs.writeFileSync(path.join(TEST_DIR, '.hidden'), 'hidden file');

      const { listCanvasArtifacts } = await import('../canvas-store.js');
      const list = await listCanvasArtifacts();

      expect(list).toEqual(['valid']);
    });
  });

  describe('deleteOldCanvasArtifacts', () => {
    it('returns 0 when no artifacts exist', async () => {
      vi.resetModules();
      const { deleteOldCanvasArtifacts } = await import('../canvas-store.js');

      const deleted = await deleteOldCanvasArtifacts(new Date());
      expect(deleted).toBe(0);
    });

    it('deletes artifacts older than specified date', async () => {
      vi.resetModules();
      const { saveCanvasArtifact, deleteOldCanvasArtifacts, listCanvasArtifacts } = await import(
        '../canvas-store.js'
      );

      // Save old artifact
      await saveCanvasArtifact({
        canvasId: 'old-canvas',
        sessionId: 'session',
        ui: {},
        savedAt: '2024-01-01T00:00:00Z', // Old date
      });

      // Save new artifact
      await saveCanvasArtifact({
        canvasId: 'new-canvas',
        sessionId: 'session',
        ui: {},
        savedAt: '2024-12-01T00:00:00Z', // Recent date
      });

      // Delete artifacts older than June 2024
      const cutoffDate = new Date('2024-06-01T00:00:00Z');
      const deleted = await deleteOldCanvasArtifacts(cutoffDate);

      expect(deleted).toBe(1);

      const remaining = await listCanvasArtifacts();
      expect(remaining).toEqual(['new-canvas']);
    });

    it('skips files that cannot be parsed', async () => {
      vi.resetModules();
      fs.mkdirSync(TEST_DIR, { recursive: true });
      fs.writeFileSync(path.join(TEST_DIR, 'corrupted.json'), 'not json');
      fs.writeFileSync(
        path.join(TEST_DIR, 'valid.json'),
        JSON.stringify({
          canvasId: 'valid',
          sessionId: 'session',
          ui: {},
          savedAt: '2024-01-01T00:00:00Z',
        })
      );

      const { deleteOldCanvasArtifacts } = await import('../canvas-store.js');
      const deleted = await deleteOldCanvasArtifacts(new Date('2024-12-01'));

      expect(deleted).toBe(1); // Only valid.json should be deleted
    });

    it('keeps artifacts newer than cutoff date', async () => {
      vi.resetModules();
      const { saveCanvasArtifact, deleteOldCanvasArtifacts, listCanvasArtifacts } = await import(
        '../canvas-store.js'
      );

      const recentDate = new Date();
      recentDate.setDate(recentDate.getDate() - 1); // Yesterday

      await saveCanvasArtifact({
        canvasId: 'recent',
        sessionId: 'session',
        ui: {},
        savedAt: recentDate.toISOString(),
      });

      // Try to delete artifacts older than a week ago
      const cutoff = new Date();
      cutoff.setDate(cutoff.getDate() - 7);

      const deleted = await deleteOldCanvasArtifacts(cutoff);

      expect(deleted).toBe(0);
      const remaining = await listCanvasArtifacts();
      expect(remaining).toContain('recent');
    });
  });
});
