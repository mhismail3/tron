/**
 * @fileoverview Task Tracking Module
 *
 * Provides persistent markdown-based task tracking with tags and categories.
 */
import * as fs from 'fs/promises';
import * as path from 'path';
import { createLogger } from '../logging/index.js';

const logger = createLogger('tasks');

// =============================================================================
// Types
// =============================================================================

export interface Task {
  id: string;
  description: string;
  completed: boolean;
  tags: string[];
  category: string;
  createdAt: string;
  completedAt?: string;
  sessionId?: string;
  priority?: 'low' | 'medium' | 'high';
  dueDate?: string;
  notes?: string;
}

export interface TaskCategory {
  name: string;
  description?: string;
  tasks: Task[];
}

export interface TaskManagerConfig {
  /** Directory to store task files */
  tasksDir: string;
  /** Default category for new tasks */
  defaultCategory?: string;
}

// =============================================================================
// Task Parsing
// =============================================================================

const TASK_REGEX = /^- \[([ xX])\] (.+)$/;
const TAG_REGEX = /#[\w-]+/g;
const PRIORITY_REGEX = /!(high|medium|low)/i;
const DUE_REGEX = /@(\d{4}-\d{2}-\d{2})/;
const SESSION_REGEX = /\[session:([^\]]+)\]/;
const ID_REGEX = /\[id:([^\]]+)\]/;

function parseTaskLine(line: string): Partial<Task> | null {
  const match = line.match(TASK_REGEX);
  if (!match || !match[1] || !match[2]) return null;

  const completed = match[1].toLowerCase() === 'x';
  const content = match[2];

  // Extract tags
  const tags = content.match(TAG_REGEX) || [];

  // Extract priority
  const priorityMatch = content.match(PRIORITY_REGEX);
  const priority = priorityMatch?.[1]
    ? (priorityMatch[1].toLowerCase() as Task['priority'])
    : undefined;

  // Extract due date
  const dueMatch = content.match(DUE_REGEX);
  const dueDate = dueMatch?.[1] ?? undefined;

  // Extract session ID
  const sessionMatch = content.match(SESSION_REGEX);
  const sessionId = sessionMatch?.[1] ?? undefined;

  // Extract ID
  const idMatch = content.match(ID_REGEX);
  const id = idMatch?.[1] ?? `task_${Date.now().toString(36)}`;

  // Clean description (remove metadata)
  let description = content
    .replace(TAG_REGEX, '')
    .replace(PRIORITY_REGEX, '')
    .replace(DUE_REGEX, '')
    .replace(SESSION_REGEX, '')
    .replace(ID_REGEX, '')
    .replace(/\s+/g, ' ')
    .trim();

  return {
    id,
    description,
    completed,
    tags,
    priority,
    dueDate,
    sessionId,
  };
}

function formatTaskLine(task: Task): string {
  const checkbox = task.completed ? '[x]' : '[ ]';
  const parts = [task.description];

  if (task.tags.length > 0) {
    parts.push(task.tags.join(' '));
  }

  if (task.priority && task.priority !== 'medium') {
    parts.push(`!${task.priority}`);
  }

  if (task.dueDate) {
    parts.push(`@${task.dueDate}`);
  }

  if (task.sessionId) {
    parts.push(`[session:${task.sessionId}]`);
  }

  parts.push(`[id:${task.id}]`);

  return `- ${checkbox} ${parts.join(' ')}`;
}

// =============================================================================
// Task Manager
// =============================================================================

export class TaskManager {
  private config: TaskManagerConfig;
  private categoriesCache: Map<string, TaskCategory> = new Map();

  constructor(config: TaskManagerConfig) {
    this.config = {
      defaultCategory: 'tasks',
      ...config,
    };
  }

  /**
   * Initialize task manager (create directories)
   */
  async initialize(): Promise<void> {
    await fs.mkdir(this.config.tasksDir, { recursive: true });
    logger.debug('Task manager initialized', { tasksDir: this.config.tasksDir });
  }

  /**
   * Get path to category file
   */
  private getCategoryPath(category: string): string {
    return path.join(this.config.tasksDir, `${category}.md`);
  }

  /**
   * Load tasks from a category file
   */
  async loadCategory(category: string): Promise<TaskCategory> {
    const filePath = this.getCategoryPath(category);

    try {
      const content = await fs.readFile(filePath, 'utf-8');
      const lines = content.split('\n');
      const tasks: Task[] = [];

      for (const line of lines) {
        const parsed = parseTaskLine(line);
        if (parsed) {
          // Check if we have this task in cache (to preserve completedAt, etc.)
          const existingCategory = this.categoriesCache.get(category);
          const existingTask = existingCategory?.tasks.find(t => t.id === parsed.id);

          tasks.push({
            id: parsed.id!,
            description: parsed.description || '',
            completed: parsed.completed || false,
            tags: parsed.tags || [],
            category,
            createdAt: existingTask?.createdAt || new Date().toISOString(),
            completedAt: existingTask?.completedAt || (parsed.completed ? new Date().toISOString() : undefined),
            ...parsed,
          });
        }
      }

      const categoryData: TaskCategory = {
        name: category,
        tasks,
      };

      this.categoriesCache.set(category, categoryData);
      return categoryData;
    } catch (error) {
      // File doesn't exist, return empty category
      const categoryData: TaskCategory = {
        name: category,
        tasks: [],
      };
      this.categoriesCache.set(category, categoryData);
      return categoryData;
    }
  }

  /**
   * Save tasks to a category file
   */
  async saveCategory(category: string): Promise<void> {
    const categoryData = this.categoriesCache.get(category);
    if (!categoryData) {
      return;
    }

    const filePath = this.getCategoryPath(category);
    const lines = [
      `# ${category.charAt(0).toUpperCase() + category.slice(1)} Tasks`,
      '',
      ...categoryData.tasks.map(formatTaskLine),
      '',
    ];

    await fs.writeFile(filePath, lines.join('\n'), 'utf-8');
    logger.debug('Category saved', { category, taskCount: categoryData.tasks.length });
  }

  /**
   * Create a new task
   */
  async create(options: {
    description: string;
    tags?: string[];
    category?: string;
    priority?: Task['priority'];
    dueDate?: string;
    sessionId?: string;
    notes?: string;
  }): Promise<Task> {
    const category = options.category || this.config.defaultCategory!;
    await this.loadCategory(category);

    const task: Task = {
      id: `task_${Date.now().toString(36)}_${Math.random().toString(36).slice(2, 6)}`,
      description: options.description,
      completed: false,
      tags: options.tags || [],
      category,
      createdAt: new Date().toISOString(),
      priority: options.priority || 'medium',
      dueDate: options.dueDate,
      sessionId: options.sessionId,
      notes: options.notes,
    };

    const categoryData = this.categoriesCache.get(category)!;
    categoryData.tasks.push(task);

    await this.saveCategory(category);
    logger.info('Task created', { taskId: task.id, description: task.description });

    return task;
  }

  /**
   * Get a task by ID
   */
  async get(taskId: string, category?: string): Promise<Task | null> {
    if (category) {
      const categoryData = await this.loadCategory(category);
      return categoryData.tasks.find(t => t.id === taskId) || null;
    }

    // Search all categories
    const categories = await this.listCategories();
    for (const cat of categories) {
      const categoryData = await this.loadCategory(cat);
      const task = categoryData.tasks.find(t => t.id === taskId);
      if (task) return task;
    }

    return null;
  }

  /**
   * Complete a task
   */
  async complete(taskId: string, category?: string): Promise<boolean> {
    const task = await this.get(taskId, category);
    if (!task) {
      return false;
    }

    task.completed = true;
    task.completedAt = new Date().toISOString();

    await this.saveCategory(task.category);
    logger.info('Task completed', { taskId });

    return true;
  }

  /**
   * Uncomplete a task
   */
  async uncomplete(taskId: string, category?: string): Promise<boolean> {
    const task = await this.get(taskId, category);
    if (!task) {
      return false;
    }

    task.completed = false;
    task.completedAt = undefined;

    await this.saveCategory(task.category);
    logger.info('Task uncompleted', { taskId });

    return true;
  }

  /**
   * Update a task
   */
  async update(taskId: string, updates: Partial<Omit<Task, 'id' | 'createdAt'>>): Promise<boolean> {
    const task = await this.get(taskId);
    if (!task) {
      return false;
    }

    Object.assign(task, updates);

    if (updates.completed && !task.completedAt) {
      task.completedAt = new Date().toISOString();
    }

    await this.saveCategory(task.category);
    logger.info('Task updated', { taskId, updates: Object.keys(updates) });

    return true;
  }

  /**
   * Delete a task
   */
  async delete(taskId: string, category?: string): Promise<boolean> {
    const task = await this.get(taskId, category);
    if (!task) {
      return false;
    }

    const categoryData = this.categoriesCache.get(task.category);
    if (!categoryData) {
      return false;
    }

    const index = categoryData.tasks.findIndex(t => t.id === taskId);
    if (index === -1) {
      return false;
    }

    categoryData.tasks.splice(index, 1);
    await this.saveCategory(task.category);
    logger.info('Task deleted', { taskId });

    return true;
  }

  /**
   * List all tasks, optionally filtered
   */
  async list(options?: {
    category?: string;
    completed?: boolean;
    tags?: string[];
    sessionId?: string;
  }): Promise<Task[]> {
    let tasks: Task[] = [];

    if (options?.category) {
      const categoryData = await this.loadCategory(options.category);
      tasks = categoryData.tasks;
    } else {
      const categories = await this.listCategories();
      for (const cat of categories) {
        const categoryData = await this.loadCategory(cat);
        tasks.push(...categoryData.tasks);
      }
    }

    // Apply filters
    if (options?.completed !== undefined) {
      tasks = tasks.filter(t => t.completed === options.completed);
    }

    if (options?.tags && options.tags.length > 0) {
      tasks = tasks.filter(t =>
        options.tags!.some(tag => t.tags.includes(tag))
      );
    }

    if (options?.sessionId) {
      tasks = tasks.filter(t => t.sessionId === options.sessionId);
    }

    return tasks;
  }

  /**
   * List all categories
   */
  async listCategories(): Promise<string[]> {
    try {
      const files = await fs.readdir(this.config.tasksDir);
      return files
        .filter(f => f.endsWith('.md'))
        .map(f => f.replace('.md', ''));
    } catch {
      return [];
    }
  }

  /**
   * Search tasks by description
   */
  async search(query: string): Promise<Task[]> {
    const allTasks = await this.list();
    const lowerQuery = query.toLowerCase();

    return allTasks.filter(t =>
      t.description.toLowerCase().includes(lowerQuery) ||
      t.tags.some(tag => tag.toLowerCase().includes(lowerQuery)) ||
      (t.notes && t.notes.toLowerCase().includes(lowerQuery))
    );
  }

  /**
   * Get tasks due soon
   */
  async getDue(withinDays: number = 7): Promise<Task[]> {
    const allTasks = await this.list({ completed: false });
    const now = new Date();
    const cutoff = new Date(now.getTime() + withinDays * 24 * 60 * 60 * 1000);

    return allTasks.filter(t => {
      if (!t.dueDate) return false;
      const due = new Date(t.dueDate);
      return due <= cutoff;
    }).sort((a, b) => {
      const dateA = new Date(a.dueDate!);
      const dateB = new Date(b.dueDate!);
      return dateA.getTime() - dateB.getTime();
    });
  }

  /**
   * Get pending tasks for current session
   */
  async getSessionTasks(sessionId: string): Promise<Task[]> {
    return this.list({ sessionId, completed: false });
  }

  /**
   * Add tag to task
   */
  async addTag(taskId: string, tag: string): Promise<boolean> {
    const task = await this.get(taskId);
    if (!task) return false;

    const normalizedTag = tag.startsWith('#') ? tag : `#${tag}`;
    if (!task.tags.includes(normalizedTag)) {
      task.tags.push(normalizedTag);
      await this.saveCategory(task.category);
    }

    return true;
  }

  /**
   * Remove tag from task
   */
  async removeTag(taskId: string, tag: string): Promise<boolean> {
    const task = await this.get(taskId);
    if (!task) return false;

    const normalizedTag = tag.startsWith('#') ? tag : `#${tag}`;
    const index = task.tags.indexOf(normalizedTag);
    if (index !== -1) {
      task.tags.splice(index, 1);
      await this.saveCategory(task.category);
    }

    return true;
  }
}
