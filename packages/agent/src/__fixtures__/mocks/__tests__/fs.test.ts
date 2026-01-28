/**
 * @fileoverview Tests for fs mock factories
 *
 * TDD: Verify that mock factories produce properly typed objects
 */

import { describe, it, expect } from 'vitest';
import type { Stats, Dirent } from 'fs';
import {
  createMockStats,
  createMockDirent,
  createFsError,
  createMockDirents,
} from '../fs.js';

describe('fs mock factories', () => {
  describe('createMockStats', () => {
    it('should create a valid Stats object with defaults', () => {
      const stats = createMockStats();

      // Should have all required Stats methods
      expect(typeof stats.isFile).toBe('function');
      expect(typeof stats.isDirectory).toBe('function');
      expect(typeof stats.isSymbolicLink).toBe('function');
      expect(typeof stats.isBlockDevice).toBe('function');
      expect(typeof stats.isCharacterDevice).toBe('function');
      expect(typeof stats.isFIFO).toBe('function');
      expect(typeof stats.isSocket).toBe('function');

      // Should have all required Stats properties
      expect(typeof stats.dev).toBe('number');
      expect(typeof stats.ino).toBe('number');
      expect(typeof stats.mode).toBe('number');
      expect(typeof stats.nlink).toBe('number');
      expect(typeof stats.uid).toBe('number');
      expect(typeof stats.gid).toBe('number');
      expect(typeof stats.rdev).toBe('number');
      expect(typeof stats.size).toBe('number');
      expect(typeof stats.blksize).toBe('number');
      expect(typeof stats.blocks).toBe('number');
      expect(stats.atime).toBeInstanceOf(Date);
      expect(stats.mtime).toBeInstanceOf(Date);
      expect(stats.ctime).toBeInstanceOf(Date);
      expect(stats.birthtime).toBeInstanceOf(Date);
    });

    it('should create a file stats by default', () => {
      const stats = createMockStats();

      expect(stats.isFile()).toBe(true);
      expect(stats.isDirectory()).toBe(false);
    });

    it('should create directory stats when isDirectory is true', () => {
      const stats = createMockStats({ isDirectory: true });

      expect(stats.isFile()).toBe(false);
      expect(stats.isDirectory()).toBe(true);
    });

    it('should set size correctly', () => {
      const stats = createMockStats({ size: 1024 });

      expect(stats.size).toBe(1024);
    });

    it('should set mtime correctly', () => {
      const mtime = new Date('2024-01-15T10:00:00Z');
      const stats = createMockStats({ mtime });

      expect(stats.mtime).toBe(mtime);
      expect(stats.mtimeMs).toBe(mtime.getTime());
    });

    it('should set directory mode for directories', () => {
      const stats = createMockStats({ isDirectory: true });

      expect(stats.mode).toBe(0o755);
    });

    it('should set file mode for files', () => {
      const stats = createMockStats({ isFile: true });

      expect(stats.mode).toBe(0o644);
    });

    it('should allow custom mode override', () => {
      const stats = createMockStats({ mode: 0o777 });

      expect(stats.mode).toBe(0o777);
    });

    it('should be assignable to Stats type', () => {
      // This test verifies TypeScript compatibility
      const stats: Stats = createMockStats({ size: 100 });

      expect(stats.size).toBe(100);
    });
  });

  describe('createMockDirent', () => {
    it('should create a valid Dirent object', () => {
      const dirent = createMockDirent('test.txt');

      expect(dirent.name).toBe('test.txt');
      expect(typeof dirent.isFile).toBe('function');
      expect(typeof dirent.isDirectory).toBe('function');
      expect(typeof dirent.isSymbolicLink).toBe('function');
      expect(typeof dirent.isBlockDevice).toBe('function');
      expect(typeof dirent.isCharacterDevice).toBe('function');
      expect(typeof dirent.isFIFO).toBe('function');
      expect(typeof dirent.isSocket).toBe('function');
    });

    it('should create a file dirent by default', () => {
      const dirent = createMockDirent('file.ts');

      expect(dirent.isFile()).toBe(true);
      expect(dirent.isDirectory()).toBe(false);
    });

    it('should create a directory dirent when isDirectory is true', () => {
      const dirent = createMockDirent('src', { isDirectory: true });

      expect(dirent.isFile()).toBe(false);
      expect(dirent.isDirectory()).toBe(true);
    });

    it('should create a symlink dirent', () => {
      const dirent = createMockDirent('link', { isSymbolicLink: true });

      expect(dirent.isSymbolicLink()).toBe(true);
    });

    it('should set parentPath', () => {
      const dirent = createMockDirent('file.ts', { parentPath: '/src' });

      expect(dirent.parentPath).toBe('/src');
      expect(dirent.path).toBe('/src');
    });

    it('should be assignable to Dirent type', () => {
      // This test verifies TypeScript compatibility
      const dirent: Dirent = createMockDirent('test.txt', { isFile: true });

      expect(dirent.name).toBe('test.txt');
    });
  });

  describe('createFsError', () => {
    it('should create an ENOENT error', () => {
      const error = createFsError('ENOENT');

      expect(error).toBeInstanceOf(Error);
      expect(error.code).toBe('ENOENT');
      expect(error.errno).toBe(-2);
      expect(error.message).toContain('no such file or directory');
    });

    it('should create an EACCES error', () => {
      const error = createFsError('EACCES');

      expect(error.code).toBe('EACCES');
      expect(error.errno).toBe(-13);
      expect(error.message).toContain('permission denied');
    });

    it('should include path in error message', () => {
      const error = createFsError('ENOENT', undefined, '/path/to/file');

      expect(error.path).toBe('/path/to/file');
      expect(error.message).toContain('/path/to/file');
    });

    it('should include syscall in error', () => {
      const error = createFsError('ENOENT', undefined, '/path', 'open');

      expect(error.syscall).toBe('open');
      expect(error.message).toContain('open');
    });

    it('should allow custom error message', () => {
      const error = createFsError('ENOENT', 'Custom message');

      expect(error.message).toContain('Custom message');
    });

    it('should be throwable', () => {
      const error = createFsError('ENOENT');

      expect(() => {
        throw error;
      }).toThrow('ENOENT');
    });
  });

  describe('createMockDirents', () => {
    it('should create multiple dirents from array', () => {
      const dirents = createMockDirents([
        ['file1.ts'],
        ['file2.ts', { isFile: true }],
        ['src', { isDirectory: true }],
      ]);

      expect(dirents).toHaveLength(3);
      expect(dirents[0].name).toBe('file1.ts');
      expect(dirents[1].name).toBe('file2.ts');
      expect(dirents[2].name).toBe('src');
      expect(dirents[2].isDirectory()).toBe(true);
    });

    it('should return empty array for empty input', () => {
      const dirents = createMockDirents([]);

      expect(dirents).toHaveLength(0);
    });

    it('should be assignable to Dirent[] type', () => {
      const dirents: Dirent[] = createMockDirents([
        ['a.ts'],
        ['b.ts'],
      ]);

      expect(dirents).toHaveLength(2);
    });
  });
});
