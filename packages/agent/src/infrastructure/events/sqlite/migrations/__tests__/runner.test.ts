/**
 * @fileoverview Tests for Migration Runner
 */

import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import { Database } from 'bun:sqlite';
import { MigrationRunner, createMigrationRunner } from '../runner.js';
import type { Migration } from '../types.js';

describe('MigrationRunner', () => {
  let db: Database;

  beforeEach(() => {
    db = new Database(':memory:');
  });

  afterEach(() => {
    db.close();
  });

  describe('run', () => {
    it('should run migrations in order', () => {
      const migrations: Migration[] = [
        {
          version: 1,
          description: 'Create users table',
          up: (db) => db.exec('CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT)'),
        },
        {
          version: 2,
          description: 'Add email column',
          up: (db) => db.exec('ALTER TABLE users ADD COLUMN email TEXT'),
        },
      ];

      const runner = new MigrationRunner(db, migrations);
      const result = runner.run();

      expect(result.fromVersion).toBe(0);
      expect(result.toVersion).toBe(2);
      expect(result.applied).toEqual([1, 2]);
      expect(result.migrated).toBe(true);

      // Verify tables exist
      const tables = db.prepare("SELECT name FROM sqlite_master WHERE type='table'").all() as { name: string }[];
      const tableNames = tables.map(t => t.name);
      expect(tableNames).toContain('users');
      expect(tableNames).toContain('schema_version');

      // Verify column was added
      const columns = db.prepare('PRAGMA table_info(users)').all() as { name: string }[];
      const columnNames = columns.map(c => c.name);
      expect(columnNames).toContain('email');
    });

    it('should skip already applied migrations', () => {
      // Run initial migrations
      const migrations: Migration[] = [
        {
          version: 1,
          description: 'Create users',
          up: (db) => db.exec('CREATE TABLE users (id INTEGER PRIMARY KEY)'),
        },
      ];

      const runner1 = new MigrationRunner(db, migrations);
      runner1.run();

      // Run again with more migrations
      const moreMigrations: Migration[] = [
        ...migrations,
        {
          version: 2,
          description: 'Create posts',
          up: (db) => db.exec('CREATE TABLE posts (id INTEGER PRIMARY KEY)'),
        },
      ];

      const runner2 = new MigrationRunner(db, moreMigrations);
      const result = runner2.run();

      expect(result.fromVersion).toBe(1);
      expect(result.toVersion).toBe(2);
      expect(result.applied).toEqual([2]);
    });

    it('should handle empty migrations list', () => {
      const runner = new MigrationRunner(db, []);
      const result = runner.run();

      expect(result.fromVersion).toBe(0);
      expect(result.toVersion).toBe(0);
      expect(result.applied).toEqual([]);
      expect(result.migrated).toBe(false);
    });

    it('should sort migrations by version', () => {
      const executionOrder: number[] = [];

      const migrations: Migration[] = [
        {
          version: 3,
          description: 'Third',
          up: () => executionOrder.push(3),
        },
        {
          version: 1,
          description: 'First',
          up: () => executionOrder.push(1),
        },
        {
          version: 2,
          description: 'Second',
          up: () => executionOrder.push(2),
        },
      ];

      const runner = new MigrationRunner(db, migrations);
      runner.run();

      expect(executionOrder).toEqual([1, 2, 3]);
    });
  });

  describe('getCurrentVersion', () => {
    it('should return 0 when no migrations run', () => {
      const runner = new MigrationRunner(db, []);
      expect(runner.getCurrentVersion()).toBe(0);
    });

    it('should return highest version after migrations', () => {
      const migrations: Migration[] = [
        { version: 1, description: 'v1', up: () => {} },
        { version: 2, description: 'v2', up: () => {} },
        { version: 3, description: 'v3', up: () => {} },
      ];

      const runner = new MigrationRunner(db, migrations);
      runner.run();

      expect(runner.getCurrentVersion()).toBe(3);
    });
  });

  describe('tableExists', () => {
    it('should return false for non-existent table', () => {
      const runner = new MigrationRunner(db, []);
      runner.run(); // Creates schema_version table

      expect(runner.tableExists('nonexistent')).toBe(false);
    });

    it('should return true for existing table', () => {
      db.exec('CREATE TABLE test_table (id INTEGER)');
      const runner = new MigrationRunner(db, []);

      expect(runner.tableExists('test_table')).toBe(true);
    });
  });

  describe('columnExists', () => {
    beforeEach(() => {
      db.exec('CREATE TABLE test (id INTEGER PRIMARY KEY, name TEXT)');
    });

    it('should return true for existing column', () => {
      const runner = new MigrationRunner(db, []);
      expect(runner.columnExists('test', 'name')).toBe(true);
    });

    it('should return false for non-existent column', () => {
      const runner = new MigrationRunner(db, []);
      expect(runner.columnExists('test', 'email')).toBe(false);
    });
  });

  describe('addColumnIfNotExists', () => {
    beforeEach(() => {
      db.exec('CREATE TABLE test (id INTEGER PRIMARY KEY, name TEXT)');
    });

    it('should add column when it does not exist', () => {
      const runner = new MigrationRunner(db, []);
      const added = runner.addColumnIfNotExists('test', 'email', 'TEXT');

      expect(added).toBe(true);
      expect(runner.columnExists('test', 'email')).toBe(true);
    });

    it('should not add column when it already exists', () => {
      const runner = new MigrationRunner(db, []);
      const added = runner.addColumnIfNotExists('test', 'name', 'TEXT');

      expect(added).toBe(false);
    });
  });

  describe('getTableColumns', () => {
    it('should return all column names', () => {
      db.exec('CREATE TABLE test (id INTEGER PRIMARY KEY, name TEXT, active INTEGER)');
      const runner = new MigrationRunner(db, []);

      const columns = runner.getTableColumns('test');
      expect(columns).toContain('id');
      expect(columns).toContain('name');
      expect(columns).toContain('active');
    });
  });

  describe('getAppliedMigrations', () => {
    it('should return empty array when no migrations applied', () => {
      const runner = new MigrationRunner(db, []);
      expect(runner.getAppliedMigrations()).toEqual([]);
    });

    it('should return applied migrations with metadata', () => {
      const migrations: Migration[] = [
        { version: 1, description: 'First', up: () => {} },
        { version: 2, description: 'Second', up: () => {} },
      ];

      const runner = new MigrationRunner(db, migrations);
      runner.run();

      const applied = runner.getAppliedMigrations();
      expect(applied).toHaveLength(2);
      expect(applied[0].version).toBe(1);
      expect(applied[0].description).toBe('First');
      expect(applied[1].version).toBe(2);
      expect(applied[1].description).toBe('Second');
    });
  });

  describe('getPendingMigrations', () => {
    it('should return all migrations when none applied', () => {
      const migrations: Migration[] = [
        { version: 1, description: 'First', up: () => {} },
        { version: 2, description: 'Second', up: () => {} },
      ];

      const runner = new MigrationRunner(db, migrations);
      const pending = runner.getPendingMigrations();

      expect(pending).toHaveLength(2);
    });

    it('should return only unapplied migrations', () => {
      const migrations: Migration[] = [
        { version: 1, description: 'First', up: () => {} },
        { version: 2, description: 'Second', up: () => {} },
        { version: 3, description: 'Third', up: () => {} },
      ];

      // Run only first two migrations
      const runner1 = new MigrationRunner(db, migrations.slice(0, 2));
      runner1.run();

      // Check pending with all migrations
      const runner2 = new MigrationRunner(db, migrations);
      const pending = runner2.getPendingMigrations();

      expect(pending).toHaveLength(1);
      expect(pending[0].version).toBe(3);
    });
  });
});

describe('createMigrationRunner', () => {
  it('should create a migration runner', () => {
    const db = new Database(':memory:');
    const runner = createMigrationRunner(db, []);

    expect(runner).toBeInstanceOf(MigrationRunner);
    db.close();
  });
});
