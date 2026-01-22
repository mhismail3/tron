/**
 * @fileoverview Tests for WorkingDirectory
 */
import { describe, it, expect } from 'vitest';
import { WorkingDirectory, createWorkingDirectory } from '../../src/session/working-directory.js';
import { SessionId } from '../../src/events/types.js';

describe('WorkingDirectory', () => {
  const createTestDirectory = (overrides = {}) => {
    return createWorkingDirectory({
      path: '/test/project',
      branch: 'main',
      isolated: false,
      sessionId: SessionId('test-session'),
      baseCommit: 'abc123',
      ...overrides,
    });
  };

  describe('creation', () => {
    it('should create working directory with info', () => {
      const workDir = createTestDirectory();
      expect(workDir).toBeDefined();
      expect(workDir.path).toBe('/test/project');
      expect(workDir.branch).toBe('main');
      expect(workDir.isolated).toBe(false);
    });

    it('should expose all properties', () => {
      const workDir = createTestDirectory({
        path: '/custom/path',
        branch: 'feature/test',
        isolated: true,
        sessionId: SessionId('custom-session'),
        baseCommit: 'def456',
      });

      expect(workDir.path).toBe('/custom/path');
      expect(workDir.branch).toBe('feature/test');
      expect(workDir.isolated).toBe(true);
      expect(workDir.sessionId).toBe('custom-session');
      expect(workDir.baseCommit).toBe('def456');
    });
  });

  describe('getInfo', () => {
    it('should return copy of info', () => {
      const workDir = createTestDirectory();
      const info = workDir.getInfo();

      expect(info.path).toBe('/test/project');
      expect(info.branch).toBe('main');
      expect(info.isolated).toBe(false);
    });
  });

  describe('file modification tracking', () => {
    it('should start with no modifications', () => {
      const workDir = createTestDirectory();
      expect(workDir.getModifications()).toHaveLength(0);
    });

    it('should record file modifications', () => {
      const workDir = createTestDirectory();

      workDir.recordModification('src/index.ts', 'modify');
      workDir.recordModification('src/new-file.ts', 'create');
      workDir.recordModification('src/old-file.ts', 'delete');

      const mods = workDir.getModifications();
      expect(mods).toHaveLength(3);
      expect(mods[0].path).toBe('src/index.ts');
      expect(mods[0].operation).toBe('modify');
      expect(mods[1].operation).toBe('create');
      expect(mods[2].operation).toBe('delete');
    });

    it('should include timestamps', () => {
      const workDir = createTestDirectory();
      workDir.recordModification('test.ts', 'modify');

      const mods = workDir.getModifications();
      expect(mods[0].timestamp).toBeDefined();
      expect(new Date(mods[0].timestamp).getTime()).toBeGreaterThan(0);
    });

    it('should clear modifications', () => {
      const workDir = createTestDirectory();
      workDir.recordModification('test.ts', 'modify');
      expect(workDir.getModifications()).toHaveLength(1);

      workDir.clearModifications();
      expect(workDir.getModifications()).toHaveLength(0);
    });

    it('should normalize absolute paths to relative', () => {
      const workDir = createTestDirectory({ path: '/test/project' });
      workDir.recordModification('/test/project/src/file.ts', 'modify');

      const mods = workDir.getModifications();
      expect(mods[0].path).toBe('src/file.ts');
    });
  });

  describe('resolve', () => {
    it('should resolve relative paths', () => {
      const workDir = createTestDirectory({ path: '/test/project' });

      expect(workDir.resolve('src', 'index.ts')).toBe('/test/project/src/index.ts');
      expect(workDir.resolve('package.json')).toBe('/test/project/package.json');
    });
  });
});
