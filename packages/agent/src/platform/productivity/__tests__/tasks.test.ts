/**
 * @fileoverview Task Manager Tests
 */
import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest';
import * as fs from 'fs/promises';
import * as path from 'path';
import * as os from 'os';
import { TaskManager, type Task } from '../tasks.js';

describe('Task Manager', () => {
  let taskManager: TaskManager;
  let testDir: string;

  beforeEach(async () => {
    testDir = await fs.mkdtemp(path.join(os.tmpdir(), 'tron-tasks-'));
    taskManager = new TaskManager({ tasksDir: testDir });
    await taskManager.initialize();
  });

  afterEach(async () => {
    await fs.rm(testDir, { recursive: true, force: true });
  });

  describe('create', () => {
    it('should create a task with basic properties', async () => {
      const task = await taskManager.create({
        description: 'Test task',
      });

      expect(task.id).toBeTruthy();
      expect(task.description).toBe('Test task');
      expect(task.completed).toBe(false);
      expect(task.category).toBe('tasks');
    });

    it('should create a task with tags', async () => {
      const task = await taskManager.create({
        description: 'Tagged task',
        tags: ['#work', '#urgent'],
      });

      expect(task.tags).toContain('#work');
      expect(task.tags).toContain('#urgent');
    });

    it('should create a task in specific category', async () => {
      const task = await taskManager.create({
        description: 'Work task',
        category: 'work',
      });

      expect(task.category).toBe('work');

      // Verify file was created
      const filePath = path.join(testDir, 'work.md');
      const exists = await fs.access(filePath).then(() => true).catch(() => false);
      expect(exists).toBe(true);
    });

    it('should create a task with priority', async () => {
      const task = await taskManager.create({
        description: 'High priority task',
        priority: 'high',
      });

      expect(task.priority).toBe('high');
    });

    it('should create a task with due date', async () => {
      const task = await taskManager.create({
        description: 'Due task',
        dueDate: '2025-12-31',
      });

      expect(task.dueDate).toBe('2025-12-31');
    });

    it('should persist task to markdown file', async () => {
      await taskManager.create({
        description: 'Persisted task',
        category: 'work',
      });

      const content = await fs.readFile(path.join(testDir, 'work.md'), 'utf-8');
      expect(content).toContain('Persisted task');
      expect(content).toContain('[ ]');
    });
  });

  describe('get', () => {
    it('should get task by ID', async () => {
      const created = await taskManager.create({
        description: 'Find me',
      });

      const found = await taskManager.get(created.id);

      expect(found).not.toBeNull();
      expect(found!.description).toBe('Find me');
    });

    it('should return null for non-existent task', async () => {
      const found = await taskManager.get('non_existent_id');

      expect(found).toBeNull();
    });
  });

  describe('complete', () => {
    it('should mark task as completed', async () => {
      const task = await taskManager.create({
        description: 'To complete',
      });

      const result = await taskManager.complete(task.id);

      expect(result).toBe(true);

      const updated = await taskManager.get(task.id);
      expect(updated!.completed).toBe(true);
      expect(updated!.completedAt).toBeTruthy();
    });

    it('should persist completion to file', async () => {
      const task = await taskManager.create({
        description: 'To complete',
        category: 'work',
      });

      await taskManager.complete(task.id);

      const content = await fs.readFile(path.join(testDir, 'work.md'), 'utf-8');
      expect(content).toContain('[x]');
    });

    it('should return false for non-existent task', async () => {
      const result = await taskManager.complete('non_existent');

      expect(result).toBe(false);
    });
  });

  describe('uncomplete', () => {
    it('should mark task as uncompleted', async () => {
      const task = await taskManager.create({
        description: 'To uncomplete',
      });
      await taskManager.complete(task.id);

      const result = await taskManager.uncomplete(task.id);

      expect(result).toBe(true);

      const updated = await taskManager.get(task.id);
      expect(updated!.completed).toBe(false);
    });
  });

  describe('update', () => {
    it('should update task properties', async () => {
      const task = await taskManager.create({
        description: 'Original',
      });

      await taskManager.update(task.id, {
        description: 'Updated',
        priority: 'high',
      });

      const updated = await taskManager.get(task.id);
      expect(updated!.description).toBe('Updated');
      expect(updated!.priority).toBe('high');
    });
  });

  describe('delete', () => {
    it('should delete task', async () => {
      const task = await taskManager.create({
        description: 'To delete',
      });

      const result = await taskManager.delete(task.id);

      expect(result).toBe(true);

      const found = await taskManager.get(task.id);
      expect(found).toBeNull();
    });
  });

  describe('list', () => {
    beforeEach(async () => {
      await taskManager.create({ description: 'Task 1', category: 'work' });
      await taskManager.create({ description: 'Task 2', category: 'work', tags: ['#urgent'] });
      await taskManager.create({ description: 'Task 3', category: 'personal' });
    });

    it('should list all tasks', async () => {
      const tasks = await taskManager.list();

      expect(tasks.length).toBe(3);
    });

    it('should filter by category', async () => {
      const tasks = await taskManager.list({ category: 'work' });

      expect(tasks.length).toBe(2);
    });

    it('should filter by completion status', async () => {
      const allTasks = await taskManager.list();
      await taskManager.complete(allTasks[0].id);

      const pending = await taskManager.list({ completed: false });
      const completed = await taskManager.list({ completed: true });

      expect(pending.length).toBe(2);
      expect(completed.length).toBe(1);
    });

    it('should filter by tags', async () => {
      const tasks = await taskManager.list({ tags: ['#urgent'] });

      expect(tasks.length).toBe(1);
      expect(tasks[0].description).toBe('Task 2');
    });
  });

  describe('listCategories', () => {
    it('should list all categories', async () => {
      await taskManager.create({ description: 'Task 1', category: 'work' });
      await taskManager.create({ description: 'Task 2', category: 'personal' });
      await taskManager.create({ description: 'Task 3', category: 'learning' });

      const categories = await taskManager.listCategories();

      expect(categories).toContain('work');
      expect(categories).toContain('personal');
      expect(categories).toContain('learning');
    });
  });

  describe('search', () => {
    beforeEach(async () => {
      await taskManager.create({ description: 'Implement OAuth flow' });
      await taskManager.create({ description: 'Fix login bug' });
      await taskManager.create({ description: 'Update documentation', tags: ['#docs'] });
    });

    it('should search by description', async () => {
      const tasks = await taskManager.search('OAuth');

      expect(tasks.length).toBe(1);
      expect(tasks[0].description).toContain('OAuth');
    });

    it('should search by tag', async () => {
      const tasks = await taskManager.search('docs');

      expect(tasks.length).toBe(1);
    });

    it('should be case-insensitive', async () => {
      const tasks = await taskManager.search('LOGIN');

      expect(tasks.length).toBe(1);
    });
  });

  describe('getDue', () => {
    it('should get tasks due within specified days', async () => {
      const today = new Date();
      const tomorrow = new Date(today.getTime() + 24 * 60 * 60 * 1000);
      const nextWeek = new Date(today.getTime() + 8 * 24 * 60 * 60 * 1000);

      await taskManager.create({
        description: 'Due tomorrow',
        dueDate: tomorrow.toISOString().split('T')[0],
      });
      await taskManager.create({
        description: 'Due next week',
        dueDate: nextWeek.toISOString().split('T')[0],
      });

      const dueSoon = await taskManager.getDue(3);

      expect(dueSoon.length).toBe(1);
      expect(dueSoon[0].description).toBe('Due tomorrow');
    });

    it('should exclude completed tasks', async () => {
      const tomorrow = new Date(Date.now() + 24 * 60 * 60 * 1000);
      const task = await taskManager.create({
        description: 'Due tomorrow but done',
        dueDate: tomorrow.toISOString().split('T')[0],
      });
      await taskManager.complete(task.id);

      const dueSoon = await taskManager.getDue(7);

      expect(dueSoon.length).toBe(0);
    });
  });

  describe('addTag / removeTag', () => {
    it('should add tag to task', async () => {
      const task = await taskManager.create({ description: 'Test' });

      await taskManager.addTag(task.id, '#newtag');

      const updated = await taskManager.get(task.id);
      expect(updated!.tags).toContain('#newtag');
    });

    it('should normalize tag with # prefix', async () => {
      const task = await taskManager.create({ description: 'Test' });

      await taskManager.addTag(task.id, 'notag');

      const updated = await taskManager.get(task.id);
      expect(updated!.tags).toContain('#notag');
    });

    it('should remove tag from task', async () => {
      const task = await taskManager.create({
        description: 'Test',
        tags: ['#remove', '#keep'],
      });

      await taskManager.removeTag(task.id, '#remove');

      const updated = await taskManager.get(task.id);
      expect(updated!.tags).not.toContain('#remove');
      expect(updated!.tags).toContain('#keep');
    });
  });
});
