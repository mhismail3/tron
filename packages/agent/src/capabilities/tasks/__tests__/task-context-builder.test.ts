/**
 * @fileoverview Tests for TaskContextBuilder
 */

import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import { DatabaseConnection } from '@infrastructure/events/sqlite/database.js';
import { runMigrations } from '@infrastructure/events/sqlite/migrations/index.js';
import { TaskRepository } from '../task-repository.js';
import { TaskContextBuilder } from '../task-context-builder.js';

describe('TaskContextBuilder', () => {
  let connection: DatabaseConnection;
  let repo: TaskRepository;
  let builder: TaskContextBuilder;

  beforeEach(() => {
    connection = new DatabaseConnection(':memory:');
    const db = connection.open();
    runMigrations(db);
    repo = new TaskRepository(connection);
    builder = new TaskContextBuilder(repo);
  });

  afterEach(() => {
    connection.close();
  });

  it('returns undefined when no tasks exist', () => {
    expect(builder.buildSummary()).toBeUndefined();
  });

  it('returns undefined when only completed/cancelled/backlog tasks exist', () => {
    repo.createTask({ title: 'Done', status: 'completed' });
    repo.createTask({ title: 'Nope', status: 'cancelled' });
    repo.createTask({ title: 'Later', status: 'backlog' });

    expect(builder.buildSummary()).toBeUndefined();
  });

  it('shows in-progress tasks', () => {
    repo.createTask({ title: 'Fix auth', status: 'in_progress', priority: 'high' });

    const summary = builder.buildSummary();
    expect(summary).toContain('1 in progress');
    expect(summary).toContain('Fix auth');
    expect(summary).toContain('P:high');
  });

  it('shows pending count', () => {
    repo.createTask({ title: 'A', status: 'pending' });
    repo.createTask({ title: 'B', status: 'pending' });

    const summary = builder.buildSummary()!;
    expect(summary).toContain('2 pending');
  });

  it('shows time tracking when estimated', () => {
    repo.createTask({
      title: 'Deploy',
      status: 'in_progress',
      estimatedMinutes: 120,
    });

    const summary = builder.buildSummary()!;
    expect(summary).toContain('0/120min');
  });

  it('shows due date on in-progress tasks', () => {
    repo.createTask({
      title: 'Ship',
      status: 'in_progress',
      dueDate: '2026-03-01',
    });

    const summary = builder.buildSummary()!;
    expect(summary).toContain('due:2026-03-01');
  });

  it('shows project progress', () => {
    const project = repo.createProject({ title: 'Auth Overhaul' });
    repo.createTask({ title: 'T1', projectId: project.id, status: 'completed' });
    repo.createTask({ title: 'T2', projectId: project.id, status: 'pending' });
    repo.createTask({ title: 'T3', projectId: project.id, status: 'pending' });

    const summary = builder.buildSummary()!;
    expect(summary).toContain('Auth Overhaul (1/3)');
  });

  it('shows overdue warning', () => {
    repo.createTask({ title: 'Late', dueDate: '2020-01-01', status: 'pending' });

    const summary = builder.buildSummary()!;
    expect(summary).toContain('1 task overdue');
  });

  it('shows deferred count', () => {
    repo.createTask({ title: 'Future', deferredUntil: '2030-01-01', status: 'pending' });
    // The deferred task won't show in pending count (default filter excludes it)
    // but the builder should show deferred count
    // We also need an active task so the builder doesn't return undefined
    repo.createTask({ title: 'Now', status: 'pending' });

    const summary = builder.buildSummary()!;
    expect(summary).toContain('1 task deferred');
  });

  it('shows blocked count', () => {
    const a = repo.createTask({ title: 'Blocker' });
    const b = repo.createTask({ title: 'Blocked' });
    repo.addDependency(a.id, b.id);

    const summary = builder.buildSummary()!;
    expect(summary).toContain('1 blocked');
  });

  it('does not show medium priority (default)', () => {
    repo.createTask({ title: 'Normal', status: 'in_progress', priority: 'medium' });

    const summary = builder.buildSummary()!;
    expect(summary).not.toContain('P:medium');
  });
});
