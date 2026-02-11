/**
 * @fileoverview Task Repository
 *
 * SQL layer for the task management system. Extends BaseRepository.
 * Pure data access — no business logic, no auto-transitions.
 */

import { BaseRepository, rowUtils } from '@infrastructure/events/sqlite/repositories/base.js';
import type { DatabaseConnection } from '@infrastructure/events/sqlite/database.js';
import type {
  Task,
  Project,
  TaskDependency,
  TaskActivity,
  TaskFilter,
  ProjectFilter,
  ProjectWithProgress,
  ActivityAction,
  DependencyRelationship,
} from './types.js';

// =============================================================================
// Row Types (SQLite shape → domain)
// =============================================================================

interface TaskRow {
  id: string;
  project_id: string | null;
  parent_task_id: string | null;
  workspace_id: string | null;
  title: string;
  description: string | null;
  active_form: string | null;
  notes: string | null;
  status: string;
  priority: string;
  source: string;
  tags: string;
  due_date: string | null;
  deferred_until: string | null;
  started_at: string | null;
  completed_at: string | null;
  created_at: string;
  updated_at: string;
  estimated_minutes: number | null;
  actual_minutes: number;
  created_by_session_id: string | null;
  last_session_id: string | null;
  last_session_at: string | null;
  sort_order: number;
  metadata: string | null;
}

interface ProjectRow {
  id: string;
  workspace_id: string | null;
  title: string;
  description: string | null;
  status: string;
  tags: string;
  created_at: string;
  updated_at: string;
  completed_at: string | null;
  metadata: string | null;
}

interface ProjectWithProgressRow extends ProjectRow {
  task_count: number;
  completed_task_count: number;
}

interface DependencyRow {
  blocker_task_id: string;
  blocked_task_id: string;
  relationship: string;
  created_at: string;
}

interface ActivityRow {
  id: number;
  task_id: string;
  session_id: string | null;
  event_id: string | null;
  action: string;
  old_value: string | null;
  new_value: string | null;
  detail: string | null;
  minutes_logged: number | null;
  timestamp: string;
}

// =============================================================================
// Repository
// =============================================================================

export class TaskRepository extends BaseRepository {
  constructor(connection: DatabaseConnection) {
    super(connection);
  }

  // ===========================================================================
  // Task CRUD
  // ===========================================================================

  createTask(params: {
    id?: string;
    projectId?: string | null;
    parentTaskId?: string | null;
    workspaceId?: string | null;
    title: string;
    description?: string | null;
    activeForm?: string | null;
    status?: string;
    priority?: string;
    source?: string;
    tags?: string[];
    dueDate?: string | null;
    deferredUntil?: string | null;
    estimatedMinutes?: number | null;
    createdBySessionId?: string | null;
  }): Task {
    const id = params.id ?? this.generateId('task');
    const now = this.now();
    const tags = JSON.stringify(params.tags ?? []);

    this.run(
      `INSERT INTO tasks (
        id, project_id, parent_task_id, workspace_id,
        title, description, active_form,
        status, priority, source, tags,
        due_date, deferred_until,
        estimated_minutes,
        created_by_session_id, last_session_id, last_session_at,
        created_at, updated_at,
        sort_order
      ) VALUES (
        ?, ?, ?, ?,
        ?, ?, ?,
        ?, ?, ?, ?,
        ?, ?,
        ?,
        ?, ?, ?,
        ?, ?,
        (SELECT COALESCE(MAX(sort_order), 0) + 1 FROM tasks WHERE project_id IS ? AND parent_task_id IS ?)
      )`,
      id,
      params.projectId ?? null,
      params.parentTaskId ?? null,
      params.workspaceId ?? null,
      params.title,
      params.description ?? null,
      params.activeForm ?? null,
      params.status ?? 'pending',
      params.priority ?? 'medium',
      params.source ?? 'agent',
      tags,
      params.dueDate ?? null,
      params.deferredUntil ?? null,
      params.estimatedMinutes ?? null,
      params.createdBySessionId ?? null,
      params.createdBySessionId ?? null,
      now,
      now,
      now,
      params.projectId ?? null,
      params.parentTaskId ?? null,
    );

    return this.getTask(id)!;
  }

  getTask(id: string): Task | undefined {
    const row = this.get<TaskRow>('SELECT * FROM tasks WHERE id = ?', id);
    return row ? this.toTask(row) : undefined;
  }

  updateTask(id: string, updates: Record<string, unknown>): Task | undefined {
    const setClauses: string[] = [];
    const values: unknown[] = [];

    for (const [key, value] of Object.entries(updates)) {
      const col = this.toSnakeCase(key);
      if (col === 'tags') {
        setClauses.push(`${col} = ?`);
        values.push(JSON.stringify(value));
      } else if (col === 'metadata') {
        setClauses.push(`${col} = ?`);
        values.push(value != null ? JSON.stringify(value) : null);
      } else {
        setClauses.push(`${col} = ?`);
        values.push(value as string | number | null);
      }
    }

    if (setClauses.length === 0) return this.getTask(id);

    setClauses.push('updated_at = ?');
    values.push(this.now());
    values.push(id);

    this.run(
      `UPDATE tasks SET ${setClauses.join(', ')} WHERE id = ?`,
      ...values as string[],
    );

    return this.getTask(id);
  }

  deleteTask(id: string): boolean {
    const result = this.run('DELETE FROM tasks WHERE id = ?', id);
    return result.changes > 0;
  }

  incrementActualMinutes(id: string, minutes: number): void {
    this.run(
      'UPDATE tasks SET actual_minutes = actual_minutes + ?, updated_at = ? WHERE id = ?',
      minutes,
      this.now(),
      id,
    );
  }

  // ===========================================================================
  // Task Queries
  // ===========================================================================

  listTasks(filter: TaskFilter = {}, limit = 50, offset = 0): { tasks: Task[]; total: number } {
    const where: string[] = [];
    const params: unknown[] = [];

    // Status filter
    if (filter.status) {
      const statuses = Array.isArray(filter.status) ? filter.status : [filter.status];
      where.push(`status IN (${statuses.map(() => '?').join(',')})`);
      params.push(...statuses);
    } else {
      // Default exclusions
      if (!filter.includeCompleted) {
        where.push("status NOT IN ('completed', 'cancelled')");
      }
      if (!filter.includeBacklog) {
        where.push("status != 'backlog'");
      }
    }

    // Deferred filter
    if (!filter.includeDeferred) {
      where.push("(deferred_until IS NULL OR deferred_until <= date('now'))");
    }

    if (filter.priority) {
      const priorities = Array.isArray(filter.priority) ? filter.priority : [filter.priority];
      where.push(`priority IN (${priorities.map(() => '?').join(',')})`);
      params.push(...priorities);
    }

    if (filter.tags && filter.tags.length > 0) {
      for (const tag of filter.tags) {
        where.push("EXISTS (SELECT 1 FROM json_each(tags) WHERE json_each.value = ?)");
        params.push(tag);
      }
    }

    if (filter.projectId !== undefined) {
      where.push('project_id = ?');
      params.push(filter.projectId);
    }

    if (filter.workspaceId !== undefined) {
      where.push('workspace_id = ?');
      params.push(filter.workspaceId);
    }

    if (filter.parentTaskId !== undefined) {
      if (filter.parentTaskId === null) {
        where.push('parent_task_id IS NULL');
      } else {
        where.push('parent_task_id = ?');
        params.push(filter.parentTaskId);
      }
    }

    if (filter.dueBefore) {
      where.push('due_date IS NOT NULL AND due_date <= ?');
      params.push(filter.dueBefore);
    }

    const whereClause = where.length > 0 ? `WHERE ${where.join(' AND ')}` : '';

    const countParams = [...params];
    const total = this.get<{ count: number }>(
      `SELECT COUNT(*) as count FROM tasks ${whereClause}`,
      ...countParams as string[],
    )!.count;

    params.push(limit, offset);
    const rows = this.all<TaskRow>(
      `SELECT * FROM tasks ${whereClause}
       ORDER BY
         CASE priority WHEN 'critical' THEN 0 WHEN 'high' THEN 1 WHEN 'medium' THEN 2 WHEN 'low' THEN 3 END,
         updated_at DESC
       LIMIT ? OFFSET ?`,
      ...params as string[],
    );

    return { tasks: rows.map(r => this.toTask(r)), total };
  }

  getSubtasks(parentTaskId: string): Task[] {
    const rows = this.all<TaskRow>(
      'SELECT * FROM tasks WHERE parent_task_id = ? ORDER BY sort_order',
      parentTaskId,
    );
    return rows.map(r => this.toTask(r));
  }

  searchTasks(query: string, limit = 20): Task[] {
    const rows = this.all<TaskRow>(
      `SELECT t.* FROM tasks t
       JOIN tasks_fts f ON f.task_id = t.id
       WHERE tasks_fts MATCH ?
       ORDER BY rank
       LIMIT ?`,
      query,
      limit,
    );
    return rows.map(r => this.toTask(r));
  }

  // ===========================================================================
  // Project CRUD
  // ===========================================================================

  createProject(params: {
    id?: string;
    workspaceId?: string | null;
    title: string;
    description?: string | null;
    tags?: string[];
  }): Project {
    const id = params.id ?? this.generateId('proj');
    const now = this.now();
    const tags = JSON.stringify(params.tags ?? []);

    this.run(
      `INSERT INTO projects (id, workspace_id, title, description, status, tags, created_at, updated_at)
       VALUES (?, ?, ?, ?, 'active', ?, ?, ?)`,
      id,
      params.workspaceId ?? null,
      params.title,
      params.description ?? null,
      tags,
      now,
      now,
    );

    return this.getProject(id)!;
  }

  getProject(id: string): Project | undefined {
    const row = this.get<ProjectRow>('SELECT * FROM projects WHERE id = ?', id);
    return row ? this.toProject(row) : undefined;
  }

  updateProject(id: string, updates: Record<string, unknown>): Project | undefined {
    const setClauses: string[] = [];
    const values: unknown[] = [];

    for (const [key, value] of Object.entries(updates)) {
      const col = this.toSnakeCase(key);
      if (col === 'tags') {
        setClauses.push(`${col} = ?`);
        values.push(JSON.stringify(value));
      } else if (col === 'metadata') {
        setClauses.push(`${col} = ?`);
        values.push(value != null ? JSON.stringify(value) : null);
      } else {
        setClauses.push(`${col} = ?`);
        values.push(value as string | number | null);
      }
    }

    if (setClauses.length === 0) return this.getProject(id);

    setClauses.push('updated_at = ?');
    values.push(this.now());
    values.push(id);

    this.run(
      `UPDATE projects SET ${setClauses.join(', ')} WHERE id = ?`,
      ...values as string[],
    );

    return this.getProject(id);
  }

  listProjects(filter: ProjectFilter = {}, limit = 50, offset = 0): { projects: ProjectWithProgress[]; total: number } {
    const where: string[] = [];
    const params: unknown[] = [];

    if (filter.status) {
      const statuses = Array.isArray(filter.status) ? filter.status : [filter.status];
      where.push(`p.status IN (${statuses.map(() => '?').join(',')})`);
      params.push(...statuses);
    }

    if (filter.workspaceId) {
      where.push('p.workspace_id = ?');
      params.push(filter.workspaceId);
    }

    const whereClause = where.length > 0 ? `WHERE ${where.join(' AND ')}` : '';

    const countParams = [...params];
    const total = this.get<{ count: number }>(
      `SELECT COUNT(*) as count FROM projects p ${whereClause}`,
      ...countParams as string[],
    )!.count;

    params.push(limit, offset);
    const rows = this.all<ProjectWithProgressRow>(
      `SELECT p.*,
              COUNT(t.id) as task_count,
              SUM(CASE WHEN t.status IN ('completed', 'cancelled') THEN 1 ELSE 0 END) as completed_task_count
       FROM projects p
       LEFT JOIN tasks t ON t.project_id = p.id AND t.parent_task_id IS NULL
       ${whereClause}
       GROUP BY p.id
       ORDER BY p.updated_at DESC
       LIMIT ? OFFSET ?`,
      ...params as string[],
    );

    return {
      projects: rows.map(r => this.toProjectWithProgress(r)),
      total,
    };
  }

  // ===========================================================================
  // Dependencies
  // ===========================================================================

  addDependency(blockerTaskId: string, blockedTaskId: string, relationship: DependencyRelationship = 'blocks'): void {
    this.run(
      `INSERT OR IGNORE INTO task_dependencies (blocker_task_id, blocked_task_id, relationship, created_at)
       VALUES (?, ?, ?, ?)`,
      blockerTaskId,
      blockedTaskId,
      relationship,
      this.now(),
    );
  }

  removeDependency(blockerTaskId: string, blockedTaskId: string): boolean {
    const result = this.run(
      'DELETE FROM task_dependencies WHERE blocker_task_id = ? AND blocked_task_id = ?',
      blockerTaskId,
      blockedTaskId,
    );
    return result.changes > 0;
  }

  getBlockedBy(taskId: string): TaskDependency[] {
    const rows = this.all<DependencyRow>(
      'SELECT * FROM task_dependencies WHERE blocked_task_id = ?',
      taskId,
    );
    return rows.map(r => this.toDependency(r));
  }

  getBlocks(taskId: string): TaskDependency[] {
    const rows = this.all<DependencyRow>(
      'SELECT * FROM task_dependencies WHERE blocker_task_id = ?',
      taskId,
    );
    return rows.map(r => this.toDependency(r));
  }

  hasCircularDependency(blockerTaskId: string, blockedTaskId: string): boolean {
    // Check if blockedTaskId already (transitively) blocks blockerTaskId
    const visited = new Set<string>();
    const queue = [blockedTaskId];

    while (queue.length > 0) {
      const current = queue.shift()!;
      if (current === blockerTaskId) return true;
      if (visited.has(current)) continue;
      visited.add(current);

      const deps = this.all<{ blocked_task_id: string }>(
        'SELECT blocked_task_id FROM task_dependencies WHERE blocker_task_id = ? AND relationship = ?',
        current,
        'blocks',
      );
      for (const dep of deps) {
        queue.push(dep.blocked_task_id);
      }
    }

    return false;
  }

  getBlockedTaskCount(workspaceId?: string): number {
    const query = workspaceId
      ? `SELECT COUNT(DISTINCT t.id) as count FROM tasks t
         JOIN task_dependencies d ON d.blocked_task_id = t.id
         JOIN tasks blocker ON blocker.id = d.blocker_task_id
         WHERE t.status NOT IN ('completed', 'cancelled')
           AND blocker.status NOT IN ('completed', 'cancelled')
           AND d.relationship = 'blocks'
           AND t.workspace_id = ?`
      : `SELECT COUNT(DISTINCT t.id) as count FROM tasks t
         JOIN task_dependencies d ON d.blocked_task_id = t.id
         JOIN tasks blocker ON blocker.id = d.blocker_task_id
         WHERE t.status NOT IN ('completed', 'cancelled')
           AND blocker.status NOT IN ('completed', 'cancelled')
           AND d.relationship = 'blocks'`;

    const params = workspaceId ? [workspaceId] : [];
    return this.get<{ count: number }>(query, ...params)!.count;
  }

  // ===========================================================================
  // Activity
  // ===========================================================================

  logActivity(params: {
    taskId: string;
    sessionId?: string | null;
    eventId?: string | null;
    action: ActivityAction;
    oldValue?: string | null;
    newValue?: string | null;
    detail?: string | null;
    minutesLogged?: number | null;
  }): void {
    this.run(
      `INSERT INTO task_activity (task_id, session_id, event_id, action, old_value, new_value, detail, minutes_logged, timestamp)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`,
      params.taskId,
      params.sessionId ?? null,
      params.eventId ?? null,
      params.action,
      params.oldValue ?? null,
      params.newValue ?? null,
      params.detail ?? null,
      params.minutesLogged ?? null,
      this.now(),
    );
  }

  getActivity(taskId: string, limit = 20): TaskActivity[] {
    const rows = this.all<ActivityRow>(
      'SELECT * FROM task_activity WHERE task_id = ? ORDER BY id DESC LIMIT ?',
      taskId,
      limit,
    );
    return rows.map(r => this.toActivity(r));
  }

  // ===========================================================================
  // Context Summary Queries
  // ===========================================================================

  getActiveTaskSummary(workspaceId?: string): {
    inProgress: Task[];
    pendingCount: number;
    overdueCount: number;
    deferredCount: number;
  } {
    const wsClause = workspaceId ? 'AND workspace_id = ?' : '';
    const wsParams = workspaceId ? [workspaceId] : [];

    const inProgress = this.all<TaskRow>(
      `SELECT * FROM tasks WHERE status = 'in_progress' ${wsClause} ORDER BY updated_at DESC`,
      ...wsParams as string[],
    ).map(r => this.toTask(r));

    const pendingCount = this.get<{ count: number }>(
      `SELECT COUNT(*) as count FROM tasks
       WHERE status = 'pending'
         AND (deferred_until IS NULL OR deferred_until <= date('now'))
         ${wsClause}`,
      ...wsParams as string[],
    )!.count;

    const overdueCount = this.get<{ count: number }>(
      `SELECT COUNT(*) as count FROM tasks
       WHERE due_date IS NOT NULL
         AND due_date < date('now')
         AND status NOT IN ('completed', 'cancelled')
         ${wsClause}`,
      ...wsParams as string[],
    )!.count;

    const deferredCount = this.get<{ count: number }>(
      `SELECT COUNT(*) as count FROM tasks
       WHERE deferred_until IS NOT NULL
         AND deferred_until > date('now')
         AND status NOT IN ('completed', 'cancelled')
         ${wsClause}`,
      ...wsParams as string[],
    )!.count;

    return { inProgress, pendingCount, overdueCount, deferredCount };
  }

  getActiveProjectProgress(workspaceId?: string): Array<{ title: string; done: number; total: number }> {
    const wsClause = workspaceId ? 'AND p.workspace_id = ?' : '';
    const wsParams = workspaceId ? [workspaceId] : [];

    return this.all<{ title: string; done: number; total: number }>(
      `SELECT p.title,
              SUM(CASE WHEN t.status IN ('completed', 'cancelled') THEN 1 ELSE 0 END) as done,
              COUNT(t.id) as total
       FROM projects p
       JOIN tasks t ON t.project_id = p.id AND t.parent_task_id IS NULL
       WHERE p.status = 'active' ${wsClause}
       GROUP BY p.id
       HAVING total > 0
       ORDER BY p.updated_at DESC`,
      ...wsParams as string[],
    );
  }

  // ===========================================================================
  // Row Converters
  // ===========================================================================

  private toTask(row: TaskRow): Task {
    return {
      id: row.id,
      projectId: row.project_id,
      parentTaskId: row.parent_task_id,
      workspaceId: row.workspace_id,
      title: row.title,
      description: row.description,
      activeForm: row.active_form,
      notes: row.notes,
      status: row.status as Task['status'],
      priority: row.priority as Task['priority'],
      source: row.source as Task['source'],
      tags: rowUtils.parseJson<string[]>(row.tags, []),
      dueDate: row.due_date,
      deferredUntil: row.deferred_until,
      startedAt: row.started_at,
      completedAt: row.completed_at,
      createdAt: row.created_at,
      updatedAt: row.updated_at,
      estimatedMinutes: row.estimated_minutes,
      actualMinutes: row.actual_minutes,
      createdBySessionId: row.created_by_session_id,
      lastSessionId: row.last_session_id,
      lastSessionAt: row.last_session_at,
      sortOrder: row.sort_order,
      metadata: rowUtils.parseJson<Record<string, unknown> | null>(row.metadata, null),
    };
  }

  private toProject(row: ProjectRow): Project {
    return {
      id: row.id,
      workspaceId: row.workspace_id,
      title: row.title,
      description: row.description,
      status: row.status as Project['status'],
      tags: rowUtils.parseJson<string[]>(row.tags, []),
      createdAt: row.created_at,
      updatedAt: row.updated_at,
      completedAt: row.completed_at,
      metadata: rowUtils.parseJson<Record<string, unknown> | null>(row.metadata, null),
    };
  }

  private toProjectWithProgress(row: ProjectWithProgressRow): ProjectWithProgress {
    return {
      ...this.toProject(row),
      taskCount: row.task_count ?? 0,
      completedTaskCount: row.completed_task_count ?? 0,
    };
  }

  private toDependency(row: DependencyRow): TaskDependency {
    return {
      blockerTaskId: row.blocker_task_id,
      blockedTaskId: row.blocked_task_id,
      relationship: row.relationship as TaskDependency['relationship'],
      createdAt: row.created_at,
    };
  }

  private toActivity(row: ActivityRow): TaskActivity {
    return {
      id: row.id,
      taskId: row.task_id,
      sessionId: row.session_id,
      eventId: row.event_id,
      action: row.action as TaskActivity['action'],
      oldValue: row.old_value,
      newValue: row.new_value,
      detail: row.detail,
      minutesLogged: row.minutes_logged,
      timestamp: row.timestamp,
    };
  }

  private toSnakeCase(key: string): string {
    return key.replace(/([A-Z])/g, '_$1').toLowerCase();
  }
}
