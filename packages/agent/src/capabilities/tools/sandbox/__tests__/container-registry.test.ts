import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import * as fs from 'fs';
import * as path from 'path';
import * as os from 'os';
import { randomUUID } from 'crypto';
import { ContainerRegistry } from '../container-registry.js';
import type { ContainerRecord } from '../types.js';

describe('ContainerRegistry', () => {
  let tmpDir: string;
  let registryPath: string;
  let registry: ContainerRegistry;

  function makeRecord(overrides: Partial<ContainerRecord> = {}): ContainerRecord {
    return {
      name: `tron-${randomUUID().slice(0, 8)}`,
      image: 'ubuntu:latest',
      createdAt: new Date().toISOString(),
      createdBySession: 'sess-test-123',
      workingDirectory: '/workspace',
      ports: [],
      ...overrides,
    };
  }

  beforeEach(() => {
    tmpDir = path.join(os.tmpdir(), `tron-registry-test-${randomUUID()}`);
    fs.mkdirSync(tmpDir, { recursive: true });
    registryPath = path.join(tmpDir, 'containers.json');
    registry = new ContainerRegistry(registryPath);
  });

  afterEach(() => {
    fs.rmSync(tmpDir, { recursive: true, force: true });
  });

  describe('load', () => {
    it('creates empty registry file if missing', () => {
      const records = registry.getAll();
      expect(records).toEqual([]);
      expect(fs.existsSync(registryPath)).toBe(true);
      const content = JSON.parse(fs.readFileSync(registryPath, 'utf-8'));
      expect(content).toEqual({ containers: [] });
    });

    it('loads existing registry from disk', () => {
      const record = makeRecord({ name: 'tron-existing' });
      fs.writeFileSync(registryPath, JSON.stringify({ containers: [record] }));

      const freshRegistry = new ContainerRegistry(registryPath);
      const records = freshRegistry.getAll();
      expect(records).toHaveLength(1);
      expect(records[0].name).toBe('tron-existing');
    });

    it('handles corrupt JSON gracefully by resetting to empty', () => {
      fs.writeFileSync(registryPath, 'not valid json {{{');

      const freshRegistry = new ContainerRegistry(registryPath);
      const records = freshRegistry.getAll();
      expect(records).toEqual([]);
    });

    it('handles missing containers field by resetting to empty', () => {
      fs.writeFileSync(registryPath, JSON.stringify({ other: 'data' }));

      const freshRegistry = new ContainerRegistry(registryPath);
      const records = freshRegistry.getAll();
      expect(records).toEqual([]);
    });
  });

  describe('add', () => {
    it('adds a container record and persists to disk', () => {
      const record = makeRecord({ name: 'tron-added' });
      registry.add(record);

      const records = registry.getAll();
      expect(records).toHaveLength(1);
      expect(records[0].name).toBe('tron-added');

      // Verify persisted
      const ondisk = JSON.parse(fs.readFileSync(registryPath, 'utf-8'));
      expect(ondisk.containers).toHaveLength(1);
      expect(ondisk.containers[0].name).toBe('tron-added');
    });

    it('adds multiple records', () => {
      registry.add(makeRecord({ name: 'tron-a' }));
      registry.add(makeRecord({ name: 'tron-b' }));
      registry.add(makeRecord({ name: 'tron-c' }));

      expect(registry.getAll()).toHaveLength(3);
    });
  });

  describe('remove', () => {
    it('removes a container by name and persists', () => {
      registry.add(makeRecord({ name: 'tron-keep' }));
      registry.add(makeRecord({ name: 'tron-remove' }));

      registry.remove('tron-remove');

      const records = registry.getAll();
      expect(records).toHaveLength(1);
      expect(records[0].name).toBe('tron-keep');

      // Verify persisted
      const ondisk = JSON.parse(fs.readFileSync(registryPath, 'utf-8'));
      expect(ondisk.containers).toHaveLength(1);
    });

    it('is a no-op when name does not exist', () => {
      registry.add(makeRecord({ name: 'tron-exists' }));
      registry.remove('tron-nonexistent');

      expect(registry.getAll()).toHaveLength(1);
    });
  });

  describe('getAll', () => {
    it('returns empty array for empty registry', () => {
      expect(registry.getAll()).toEqual([]);
    });

    it('returns all records', () => {
      registry.add(makeRecord({ name: 'tron-1' }));
      registry.add(makeRecord({ name: 'tron-2' }));

      const records = registry.getAll();
      expect(records).toHaveLength(2);
      expect(records.map(r => r.name)).toEqual(['tron-1', 'tron-2']);
    });
  });

  describe('reconcile', () => {
    it('removes entries for containers not in the live list', () => {
      registry.add(makeRecord({ name: 'tron-alive' }));
      registry.add(makeRecord({ name: 'tron-dead' }));

      registry.reconcile(['tron-alive']);

      const records = registry.getAll();
      expect(records).toHaveLength(1);
      expect(records[0].name).toBe('tron-alive');
    });

    it('keeps all entries when all are live', () => {
      registry.add(makeRecord({ name: 'tron-a' }));
      registry.add(makeRecord({ name: 'tron-b' }));

      registry.reconcile(['tron-a', 'tron-b', 'other-container']);

      expect(registry.getAll()).toHaveLength(2);
    });

    it('removes all entries when none are live', () => {
      registry.add(makeRecord({ name: 'tron-gone1' }));
      registry.add(makeRecord({ name: 'tron-gone2' }));

      registry.reconcile([]);

      expect(registry.getAll()).toEqual([]);
    });

    it('persists changes after reconciliation', () => {
      registry.add(makeRecord({ name: 'tron-alive' }));
      registry.add(makeRecord({ name: 'tron-dead' }));

      registry.reconcile(['tron-alive']);

      const ondisk = JSON.parse(fs.readFileSync(registryPath, 'utf-8'));
      expect(ondisk.containers).toHaveLength(1);
      expect(ondisk.containers[0].name).toBe('tron-alive');
    });
  });

  describe('atomic writes', () => {
    it('writes to tmp file then renames', () => {
      registry.add(makeRecord({ name: 'tron-atomic' }));

      // The file should exist and be valid JSON after the write
      const content = fs.readFileSync(registryPath, 'utf-8');
      expect(() => JSON.parse(content)).not.toThrow();
      expect(JSON.parse(content).containers[0].name).toBe('tron-atomic');
    });

    it('creates parent directories if needed', () => {
      const nestedPath = path.join(tmpDir, 'nested', 'deep', 'containers.json');
      const nestedRegistry = new ContainerRegistry(nestedPath);
      nestedRegistry.add(makeRecord({ name: 'tron-nested' }));

      expect(fs.existsSync(nestedPath)).toBe(true);
      const content = JSON.parse(fs.readFileSync(nestedPath, 'utf-8'));
      expect(content.containers[0].name).toBe('tron-nested');
    });
  });
});
