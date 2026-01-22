/**
 * @fileoverview Tests for Path Resolution Utilities
 *
 * Ensures that all clients (server, TUI) resolve paths to the canonical
 * ~/.tron directory for shared data access.
 */
import { describe, it, expect, afterEach } from 'vitest';
import { resolveTronPath, getTronDataDir, setSettingsPath, clearSettingsCache } from '../../src/settings/index.js';
import * as path from 'path';
import * as os from 'os';

describe('Path Resolution Utilities', () => {
  afterEach(() => {
    clearSettingsCache();
    setSettingsPath(undefined);
  });

  describe('resolveTronPath', () => {
    it('should return absolute paths unchanged', () => {
      const absolutePath = '/Users/test/.tron/custom/memory.db';
      const result = resolveTronPath(absolutePath);
      expect(result).toBe(absolutePath);
    });

    it('should resolve relative paths against ~/.tron', () => {
      const relativePath = 'sessions';
      const result = resolveTronPath(relativePath);

      const expected = path.join(os.homedir(), '.tron', 'sessions');
      expect(result).toBe(expected);
    });

    it('should resolve nested relative paths', () => {
      const relativePath = 'memory/handoffs.db';
      const result = resolveTronPath(relativePath);

      const expected = path.join(os.homedir(), '.tron', 'memory/handoffs.db');
      expect(result).toBe(expected);
    });

    it('should respect custom tronDir when provided', () => {
      const relativePath = 'sessions';
      const customTronDir = '/custom/tron/dir';
      const result = resolveTronPath(relativePath, customTronDir);

      expect(result).toBe('/custom/tron/dir/sessions');
    });

    it('should handle memory.db default path correctly', () => {
      const result = resolveTronPath('memory.db');
      const expected = path.join(os.homedir(), '.tron', 'memory.db');
      expect(result).toBe(expected);
    });

    it('should work for handoff derivation pattern', () => {
      // Simulates the orchestrator's pattern: memoryDbPath.replace('.db', '-handoffs.db')
      const memoryDbPath = resolveTronPath('memory.db');
      const handoffDbPath = memoryDbPath.replace('.db', '-handoffs.db');

      const expected = path.join(os.homedir(), '.tron', 'memory-handoffs.db');
      expect(handoffDbPath).toBe(expected);
    });
  });

  describe('getTronDataDir', () => {
    it('should return ~/.tron by default', () => {
      const result = getTronDataDir();
      const expected = path.join(os.homedir(), '.tron');
      expect(result).toBe(expected);
    });

    it('should respect custom home directory', () => {
      const result = getTronDataDir('/custom/home');
      expect(result).toBe('/custom/home/.tron');
    });
  });

  describe('integration: server and TUI path consistency', () => {
    it('should produce same paths for TUI and server patterns', () => {
      const tronDir = getTronDataDir();

      // TUI pattern (from tui-session.ts):
      const tuiSessionsDir = path.join(tronDir, 'sessions');
      const tuiHandoffDb = path.join(tronDir, 'memory-handoffs.db');

      // Server pattern (now using resolveTronPath):
      const serverSessionsDir = resolveTronPath('sessions', tronDir);
      const serverMemoryDb = resolveTronPath('memory.db', tronDir);
      const serverHandoffDb = serverMemoryDb.replace('.db', '-handoffs.db');

      expect(serverSessionsDir).toBe(tuiSessionsDir);
      expect(serverHandoffDb).toBe(tuiHandoffDb);
    });
  });
});
