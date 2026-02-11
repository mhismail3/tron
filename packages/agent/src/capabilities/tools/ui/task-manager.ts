/**
 * @fileoverview TaskManager Tool
 *
 * Single unified tool for all task and project management operations.
 * Uses action discriminator pattern (like UnifiedSearchTool).
 */

import type { TronTool, TronToolResult, ToolExecutionOptions } from '@core/types/index.js';
import type { TaskService } from '../../tasks/task-service.js';
import type {
  TaskStatus,
  TaskPriority,
  ProjectStatus,
} from '../../tasks/types.js';
import { createLogger } from '@infrastructure/logging/index.js';

const logger = createLogger('tool:task-manager');

// =============================================================================
// Types
// =============================================================================

type TaskManagerAction =
  | 'create'
  | 'update'
  | 'get'
  | 'list'
  | 'search'
  | 'log_time'
  | 'delete'
  | 'create_project'
  | 'update_project'
  | 'list_projects';

interface TaskManagerParams {
  action: TaskManagerAction;

  // create / update
  title?: string;
  description?: string;
  activeForm?: string;
  status?: TaskStatus;
  priority?: TaskPriority;
  addTags?: string[];
  removeTags?: string[];
  dueDate?: string;
  deferredUntil?: string;
  estimatedMinutes?: number;
  notes?: string;
  projectId?: string;
  parentTaskId?: string;

  // update / get / delete / log_time
  taskId?: string;

  // dependencies
  addBlocks?: string[];
  addBlockedBy?: string[];
  removeBlocks?: string[];
  removeBlockedBy?: string[];

  // log_time
  minutes?: number;
  timeNote?: string;

  // list
  filter?: Record<string, unknown>;
  limit?: number;
  offset?: number;

  // search
  query?: string;

  // create_project / update_project
  projectTitle?: string;
  projectDescription?: string;
  projectStatus?: ProjectStatus;
  projectTags?: string[];
  workspaceId?: string;
}

export interface TaskManagerToolConfig {
  service: TaskService;
  getSessionId: () => string;
  getWorkspaceId: () => string | undefined;
}

// =============================================================================
// Tool Implementation
// =============================================================================

export class TaskManagerTool implements TronTool<TaskManagerParams> {
  readonly name = 'TaskManager';
  readonly label = 'Tasks';
  readonly executionContract = 'options' as const;
  readonly description = `Persistent task and project manager. Tasks survive across sessions.

## Actions

- **create**: Create a task. Required: title. Optional: description, activeForm, status, priority, projectId, parentTaskId, addTags, dueDate, deferredUntil, estimatedMinutes
- **update**: Update a task. Required: taskId. Optional: status, title, description, priority, notes (appends), addTags/removeTags, addBlocks/addBlockedBy/removeBlocks/removeBlockedBy, dueDate, deferredUntil, projectId, parentTaskId
- **get**: Get task details. Required: taskId
- **list**: List tasks. Optional: filter (status, priority, tags, projectId, includeCompleted, includeDeferred, includeBacklog), limit, offset
- **search**: Full-text search. Required: query. Optional: limit
- **log_time**: Log time spent. Required: taskId, minutes. Optional: timeNote
- **delete**: Delete a task. Required: taskId
- **create_project**: Create project. Required: projectTitle. Optional: projectDescription, projectTags, workspaceId
- **update_project**: Update project. Required: projectId. Optional: projectTitle, projectDescription, projectStatus, projectTags
- **list_projects**: List projects. Optional: filter by status/workspaceId

## Status Model
backlog → pending → in_progress → completed/cancelled

## Key Behaviors
- status→in_progress auto-sets startedAt; status→completed auto-sets completedAt
- notes append with timestamps (never replace)
- Tasks with deferredUntil > today are hidden from default list
- Dependencies: addBlocks/addBlockedBy create blocking relationships; circular deps rejected`;

  readonly parameters = {
    type: 'object' as const,
    properties: {
      action: {
        type: 'string' as const,
        enum: ['create', 'update', 'get', 'list', 'search', 'log_time', 'delete', 'create_project', 'update_project', 'list_projects'],
        description: 'Action to perform',
      },
      title: { type: 'string' as const, description: 'Task title (imperative form)' },
      description: { type: 'string' as const, description: 'Task description (markdown)' },
      activeForm: { type: 'string' as const, description: 'Present continuous form for spinner display' },
      taskId: { type: 'string' as const, description: 'Task ID for update/get/delete/log_time' },
      status: { type: 'string' as const, enum: ['backlog', 'pending', 'in_progress', 'completed', 'cancelled'] },
      priority: { type: 'string' as const, enum: ['low', 'medium', 'high', 'critical'] },
      addTags: { type: 'array' as const, items: { type: 'string' as const } },
      removeTags: { type: 'array' as const, items: { type: 'string' as const } },
      dueDate: { type: 'string' as const, description: 'YYYY-MM-DD deadline' },
      deferredUntil: { type: 'string' as const, description: 'YYYY-MM-DD: hidden until this date' },
      estimatedMinutes: { type: 'number' as const },
      notes: { type: 'string' as const, description: 'Appended to existing notes with timestamp' },
      projectId: { type: 'string' as const },
      parentTaskId: { type: 'string' as const },
      addBlocks: { type: 'array' as const, items: { type: 'string' as const }, description: 'Task IDs this task blocks' },
      addBlockedBy: { type: 'array' as const, items: { type: 'string' as const }, description: 'Task IDs blocking this task' },
      removeBlocks: { type: 'array' as const, items: { type: 'string' as const } },
      removeBlockedBy: { type: 'array' as const, items: { type: 'string' as const } },
      minutes: { type: 'number' as const, description: 'Minutes to log' },
      timeNote: { type: 'string' as const },
      query: { type: 'string' as const, description: 'Search query' },
      filter: { type: 'object' as const, description: 'Filter object for list actions' },
      limit: { type: 'number' as const },
      offset: { type: 'number' as const },
      projectTitle: { type: 'string' as const },
      projectDescription: { type: 'string' as const },
      projectStatus: { type: 'string' as const, enum: ['active', 'paused', 'completed', 'archived'] },
      projectTags: { type: 'array' as const, items: { type: 'string' as const } },
      workspaceId: { type: 'string' as const },
    },
    required: ['action'] as string[],
  };

  private config: TaskManagerToolConfig;

  constructor(config: TaskManagerToolConfig) {
    this.config = config;
  }

  async execute(args: TaskManagerParams, _options?: ToolExecutionOptions): Promise<TronToolResult> {
    try {
      switch (args.action) {
        case 'create': return this.handleCreate(args);
        case 'update': return this.handleUpdate(args);
        case 'get': return this.handleGet(args);
        case 'list': return this.handleList(args);
        case 'search': return this.handleSearch(args);
        case 'log_time': return this.handleLogTime(args);
        case 'delete': return this.handleDelete(args);
        case 'create_project': return this.handleCreateProject(args);
        case 'update_project': return this.handleUpdateProject(args);
        case 'list_projects': return this.handleListProjects(args);
        default:
          return { content: `Unknown action: ${args.action}`, isError: true };
      }
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err);
      logger.error('TaskManager error', { action: args.action, error: message });
      return { content: `Error: ${message}`, isError: true };
    }
  }

  // ===========================================================================
  // Action Handlers
  // ===========================================================================

  private handleCreate(args: TaskManagerParams): TronToolResult {
    if (!args.title) return { content: 'Error: title is required for create', isError: true };

    const task = this.config.service.createTask({
      title: args.title,
      description: args.description,
      activeForm: args.activeForm,
      status: args.status,
      priority: args.priority,
      tags: args.addTags,
      dueDate: args.dueDate,
      deferredUntil: args.deferredUntil,
      estimatedMinutes: args.estimatedMinutes,
      projectId: args.projectId,
      parentTaskId: args.parentTaskId,
      sessionId: this.config.getSessionId(),
      workspaceId: this.config.getWorkspaceId(),
    });

    return {
      content: `Created task ${task.id}: ${task.title} [${task.status}]`,
      isError: false,
    };
  }

  private handleUpdate(args: TaskManagerParams): TronToolResult {
    if (!args.taskId) return { content: 'Error: taskId is required for update', isError: true };

    const task = this.config.service.updateTask(args.taskId, {
      status: args.status,
      title: args.title,
      description: args.description,
      activeForm: args.activeForm,
      priority: args.priority,
      dueDate: args.dueDate,
      deferredUntil: args.deferredUntil,
      estimatedMinutes: args.estimatedMinutes,
      notes: args.notes,
      addTags: args.addTags,
      removeTags: args.removeTags,
      projectId: args.projectId,
      parentTaskId: args.parentTaskId,
      sessionId: this.config.getSessionId(),
    });

    // Handle dependencies
    if (args.addBlocks) {
      for (const blockedId of args.addBlocks) {
        this.config.service.addDependency(args.taskId, blockedId);
      }
    }
    if (args.addBlockedBy) {
      for (const blockerId of args.addBlockedBy) {
        this.config.service.addDependency(blockerId, args.taskId);
      }
    }
    if (args.removeBlocks) {
      for (const blockedId of args.removeBlocks) {
        this.config.service.removeDependency(args.taskId, blockedId);
      }
    }
    if (args.removeBlockedBy) {
      for (const blockerId of args.removeBlockedBy) {
        this.config.service.removeDependency(blockerId, args.taskId);
      }
    }

    return {
      content: `Updated task ${task.id}: ${task.title} [${task.status}]`,
      isError: false,
    };
  }

  private handleGet(args: TaskManagerParams): TronToolResult {
    if (!args.taskId) return { content: 'Error: taskId is required for get', isError: true };

    const details = this.config.service.getTask(args.taskId);
    if (!details) return { content: `Task not found: ${args.taskId}`, isError: true };

    const lines: string[] = [
      `# ${details.title}`,
      `ID: ${details.id} | Status: ${details.status} | Priority: ${details.priority}`,
    ];

    if (details.description) lines.push(`\n${details.description}`);
    if (details.activeForm) lines.push(`Active form: ${details.activeForm}`);
    if (details.projectId) lines.push(`Project: ${details.projectId}`);
    if (details.parentTaskId) lines.push(`Parent: ${details.parentTaskId}`);
    if (details.dueDate) lines.push(`Due: ${details.dueDate}`);
    if (details.deferredUntil) lines.push(`Deferred until: ${details.deferredUntil}`);
    if (details.estimatedMinutes) lines.push(`Time: ${details.actualMinutes}/${details.estimatedMinutes}min`);
    if (details.tags.length > 0) lines.push(`Tags: ${details.tags.join(', ')}`);
    if (details.notes) lines.push(`\nNotes:\n${details.notes}`);

    if (details.subtasks.length > 0) {
      lines.push(`\nSubtasks (${details.subtasks.length}):`);
      for (const sub of details.subtasks) {
        const mark = sub.status === 'completed' ? 'x' : sub.status === 'in_progress' ? '>' : ' ';
        lines.push(`  [${mark}] ${sub.id}: ${sub.title}`);
      }
    }

    if (details.blockedBy.length > 0) {
      lines.push(`\nBlocked by: ${details.blockedBy.map(d => d.blockerTaskId).join(', ')}`);
    }
    if (details.blocks.length > 0) {
      lines.push(`Blocks: ${details.blocks.map(d => d.blockedTaskId).join(', ')}`);
    }

    if (details.recentActivity.length > 0) {
      lines.push(`\nRecent activity:`);
      for (const act of details.recentActivity.slice(0, 5)) {
        lines.push(`  ${act.timestamp.split('T')[0]}: ${act.action}${act.detail ? ` - ${act.detail}` : ''}`);
      }
    }

    return { content: lines.join('\n'), isError: false };
  }

  private handleList(args: TaskManagerParams): TronToolResult {
    const filter = (args.filter ?? {}) as Record<string, unknown>;
    if (args.workspaceId) filter.workspaceId = args.workspaceId;

    const result = this.config.service.listTasks(
      filter as any,
      args.limit ?? 20,
      args.offset ?? 0,
    );

    if (result.tasks.length === 0) {
      return { content: 'No tasks found.', isError: false };
    }

    const lines: string[] = [`Tasks (${result.tasks.length}/${result.total}):`];
    for (const task of result.tasks) {
      const mark = task.status === 'completed' ? 'x'
        : task.status === 'in_progress' ? '>'
        : task.status === 'cancelled' ? '-'
        : task.status === 'backlog' ? 'b'
        : ' ';
      const meta: string[] = [];
      if (task.priority !== 'medium') meta.push(`P:${task.priority}`);
      if (task.dueDate) meta.push(`due:${task.dueDate}`);
      const suffix = meta.length > 0 ? ` (${meta.join(', ')})` : '';
      lines.push(`[${mark}] ${task.id}: ${task.title}${suffix}`);
    }

    return { content: lines.join('\n'), isError: false };
  }

  private handleSearch(args: TaskManagerParams): TronToolResult {
    if (!args.query) return { content: 'Error: query is required for search', isError: true };

    const results = this.config.service.searchTasks(args.query, args.limit ?? 10);

    if (results.length === 0) {
      return { content: `No tasks matching "${args.query}"`, isError: false };
    }

    const lines: string[] = [`Search results for "${args.query}" (${results.length}):`];
    for (const task of results) {
      lines.push(`  ${task.id}: ${task.title} [${task.status}]`);
    }

    return { content: lines.join('\n'), isError: false };
  }

  private handleLogTime(args: TaskManagerParams): TronToolResult {
    if (!args.taskId) return { content: 'Error: taskId is required for log_time', isError: true };
    if (!args.minutes || args.minutes <= 0) return { content: 'Error: minutes must be a positive number', isError: true };

    const task = this.config.service.logTime(
      args.taskId,
      args.minutes,
      this.config.getSessionId(),
      args.timeNote,
    );

    return {
      content: `Logged ${args.minutes}min on ${task.id}. Total: ${task.actualMinutes}min${task.estimatedMinutes ? `/${task.estimatedMinutes}min` : ''}`,
      isError: false,
    };
  }

  private handleDelete(args: TaskManagerParams): TronToolResult {
    if (!args.taskId) return { content: 'Error: taskId is required for delete', isError: true };

    const deleted = this.config.service.deleteTask(args.taskId);
    if (!deleted) return { content: `Task not found: ${args.taskId}`, isError: true };

    return { content: `Deleted task ${args.taskId}`, isError: false };
  }

  private handleCreateProject(args: TaskManagerParams): TronToolResult {
    if (!args.projectTitle) return { content: 'Error: projectTitle is required', isError: true };

    const project = this.config.service.createProject({
      title: args.projectTitle,
      description: args.projectDescription,
      tags: args.projectTags,
      workspaceId: args.workspaceId ?? this.config.getWorkspaceId(),
    });

    return {
      content: `Created project ${project.id}: ${project.title}`,
      isError: false,
    };
  }

  private handleUpdateProject(args: TaskManagerParams): TronToolResult {
    if (!args.projectId) return { content: 'Error: projectId is required', isError: true };

    const project = this.config.service.updateProject(args.projectId, {
      title: args.projectTitle,
      description: args.projectDescription,
      status: args.projectStatus,
      tags: args.projectTags,
    });

    return {
      content: `Updated project ${project.id}: ${project.title} [${project.status}]`,
      isError: false,
    };
  }

  private handleListProjects(args: TaskManagerParams): TronToolResult {
    const filter: Record<string, unknown> = {};
    if (args.projectStatus) filter.status = args.projectStatus;
    if (args.workspaceId) filter.workspaceId = args.workspaceId;

    const result = this.config.service.listProjects(filter as any);

    if (result.projects.length === 0) {
      return { content: 'No projects found.', isError: false };
    }

    const lines: string[] = [`Projects (${result.projects.length}):`];
    for (const project of result.projects) {
      const progress = project.taskCount > 0
        ? ` (${project.completedTaskCount}/${project.taskCount} tasks)`
        : '';
      lines.push(`  ${project.id}: ${project.title} [${project.status}]${progress}`);
    }

    return { content: lines.join('\n'), isError: false };
  }
}
