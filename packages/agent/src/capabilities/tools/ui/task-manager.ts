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
  AreaStatus,
  TaskWithDetails,
  ProjectWithDetails,
  AreaWithCounts,
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
  | 'list_projects'
  | 'get_project'
  | 'delete_project'
  | 'create_area'
  | 'update_area'
  | 'get_area'
  | 'delete_area'
  | 'list_areas';

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

  // area operations
  areaId?: string;
  areaTitle?: string;
  areaDescription?: string;
  areaStatus?: AreaStatus;
  areaTags?: string[];
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
  readonly description = `Persistent task, project, and area manager (PARA model). Tasks survive across sessions.

## PARA Model
- **Projects**: Time-bound scoped efforts with tasks
- **Areas**: Ongoing responsibilities the agent maintains awareness of (e.g., "Security", "Code Quality")
- **Tasks**: Individual work items, optionally linked to a project and/or area

## Actions

### Tasks
- **create**: Create a task. Required: title. Optional: description, activeForm, status, priority, projectId, parentTaskId, areaId, addTags, dueDate, deferredUntil, estimatedMinutes
- **update**: Update a task. Required: taskId. Optional: status, title, description, priority, notes (appends), addTags/removeTags, addBlocks/addBlockedBy/removeBlocks/removeBlockedBy, dueDate, deferredUntil, projectId, parentTaskId, areaId
- **get**: Get task details. Required: taskId
- **list**: List tasks. Optional: filter (status, priority, tags, projectId, areaId, includeCompleted, includeDeferred, includeBacklog), limit, offset
- **search**: Full-text search. Required: query. Optional: limit
- **log_time**: Log time spent. Required: taskId, minutes. Optional: timeNote
- **delete**: Delete a task. Required: taskId

### Projects
- **create_project**: Create project. Required: projectTitle. Optional: projectDescription, projectTags, workspaceId, areaId
- **update_project**: Update project. Required: projectId. Optional: projectTitle, projectDescription, projectStatus, projectTags, areaId
- **get_project**: Get project details with tasks. Required: projectId
- **delete_project**: Delete project (orphans tasks). Required: projectId
- **list_projects**: List projects. Optional: filter by status/workspaceId/areaId

### Areas
- **create_area**: Create area. Required: areaTitle. Optional: areaDescription, areaTags
- **update_area**: Update area. Required: areaId. Optional: areaTitle, areaDescription, areaStatus (active/archived), areaTags
- **get_area**: Get area details with counts. Required: areaId
- **delete_area**: Delete area (unlinks projects/tasks). Required: areaId
- **list_areas**: List areas. Optional: areaStatus filter

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
        enum: ['create', 'update', 'get', 'list', 'search', 'log_time', 'delete', 'create_project', 'update_project', 'list_projects', 'get_project', 'delete_project', 'create_area', 'update_area', 'get_area', 'delete_area', 'list_areas'],
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
      areaId: { type: 'string' as const, description: 'Area ID for linking or area operations' },
      areaTitle: { type: 'string' as const, description: 'Area title' },
      areaDescription: { type: 'string' as const, description: 'Area description' },
      areaStatus: { type: 'string' as const, enum: ['active', 'archived'], description: 'Area status' },
      areaTags: { type: 'array' as const, items: { type: 'string' as const }, description: 'Area tags' },
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
        case 'get_project': return this.handleGetProject(args);
        case 'delete_project': return this.handleDeleteProject(args);
        case 'create_area': return this.handleCreateArea(args);
        case 'update_area': return this.handleUpdateArea(args);
        case 'get_area': return this.handleGetArea(args);
        case 'delete_area': return this.handleDeleteArea(args);
        case 'list_areas': return this.handleListAreas(args);
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
  // Format Helpers — Rich Entity Snapshots
  // ===========================================================================

  private formatTaskDetail(details: TaskWithDetails): string {
    const lines: string[] = [
      `# ${details.title}`,
      `ID: ${details.id} | Status: ${details.status} | Priority: ${details.priority}`,
    ];

    if (details.description) lines.push(`\n${details.description}`);
    if (details.activeForm) lines.push(`Active form: ${details.activeForm}`);

    // Resolve project name
    if (details.projectId) {
      const project = this.config.service.getProjectWithDetails(details.projectId);
      if (project) {
        lines.push(`Project: ${project.title} (${project.id})`);
      } else {
        lines.push(`Project: ${details.projectId}`);
      }
    }

    // Resolve area name
    if (details.areaId) {
      const area = this.config.service.getArea(details.areaId);
      if (area) {
        lines.push(`Area: ${area.title} (${area.id})`);
      } else {
        lines.push(`Area: ${details.areaId}`);
      }
    }

    if (details.parentTaskId) lines.push(`Parent: ${details.parentTaskId}`);
    if (details.dueDate) lines.push(`Due: ${details.dueDate}`);
    if (details.deferredUntil) lines.push(`Deferred until: ${details.deferredUntil}`);
    if (details.estimatedMinutes) lines.push(`Time: ${details.actualMinutes}/${details.estimatedMinutes}min`);
    if (details.tags.length > 0) lines.push(`Tags: ${details.tags.join(', ')}`);
    lines.push(`Source: ${details.source}`);
    if (details.startedAt) lines.push(`Started: ${details.startedAt}`);
    if (details.completedAt) lines.push(`Completed: ${details.completedAt}`);
    lines.push(`Created: ${details.createdAt}`);
    lines.push(`Updated: ${details.updatedAt}`);

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

    return lines.join('\n');
  }

  private formatProjectDetail(details: ProjectWithDetails): string {
    const lines: string[] = [
      `# ${details.title}`,
      `ID: ${details.id} | Status: ${details.status} | ${details.completedTaskCount}/${details.taskCount} tasks`,
    ];

    if (details.description) lines.push(`\n${details.description}`);
    if (details.area) lines.push(`Area: ${details.area.title} (${details.area.id})`);
    if (details.tags.length > 0) lines.push(`Tags: ${details.tags.join(', ')}`);
    lines.push(`Created: ${details.createdAt}`);
    lines.push(`Updated: ${details.updatedAt}`);

    if (details.tasks.length > 0) {
      lines.push(`\nTasks (${details.tasks.length}):`);
      for (const task of details.tasks) {
        const mark = task.status === 'completed' ? 'x' : task.status === 'in_progress' ? '>' : ' ';
        const prioritySuffix = task.priority !== 'medium' ? ` [${task.priority}]` : '';
        lines.push(`  [${mark}] ${task.id}: ${task.title}${prioritySuffix}`);
      }
    }

    return lines.join('\n');
  }

  private formatAreaDetail(area: AreaWithCounts): string {
    const lines: string[] = [
      `# ${area.title}`,
      `ID: ${area.id} | Status: ${area.status}`,
      `${area.projectCount} project${area.projectCount !== 1 ? 's' : ''}, ${area.taskCount} task${area.taskCount !== 1 ? 's' : ''} (${area.activeTaskCount} active)`,
    ];

    if (area.description) lines.push(`\n${area.description}`);
    if (area.tags.length > 0) lines.push(`Tags: ${area.tags.join(', ')}`);
    lines.push(`Created: ${area.createdAt}`);
    lines.push(`Updated: ${area.updatedAt}`);

    return lines.join('\n');
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
      areaId: args.areaId,
      sessionId: this.config.getSessionId(),
      workspaceId: this.config.getWorkspaceId(),
    });

    const details = this.config.service.getTask(task.id)!;
    const actionLine = `Created task ${task.id}: ${task.title} [${task.status}]`;

    return {
      content: `${actionLine}\n\n${this.formatTaskDetail(details)}`,
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
      areaId: args.areaId,
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

    const details = this.config.service.getTask(args.taskId)!;
    const actionLine = `Updated task ${task.id}: ${task.title} [${task.status}]`;

    return {
      content: `${actionLine}\n\n${this.formatTaskDetail(details)}`,
      isError: false,
    };
  }

  private handleGet(args: TaskManagerParams): TronToolResult {
    if (!args.taskId) return { content: 'Error: taskId is required for get', isError: true };

    const details = this.config.service.getTask(args.taskId);
    if (!details) return { content: `Task not found: ${args.taskId}`, isError: true };

    return { content: this.formatTaskDetail(details), isError: false };
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

    const details = this.config.service.getTask(args.taskId)!;
    const actionLine = `Logged ${args.minutes}min on ${task.id}. Total: ${task.actualMinutes}min${task.estimatedMinutes ? `/${task.estimatedMinutes}min` : ''}`;

    return {
      content: `${actionLine}\n\n${this.formatTaskDetail(details)}`,
      isError: false,
    };
  }

  private handleDelete(args: TaskManagerParams): TronToolResult {
    if (!args.taskId) return { content: 'Error: taskId is required for delete', isError: true };

    const details = this.config.service.getTask(args.taskId);
    if (!details) return { content: `Task not found: ${args.taskId}`, isError: true };

    // Capture snapshot before deletion
    const snapshot = this.formatTaskDetail(details);
    this.config.service.deleteTask(args.taskId);

    const actionLine = `Deleted task ${args.taskId}: ${details.title}`;

    return {
      content: `${actionLine}\n\n${snapshot}`,
      isError: false,
    };
  }

  private handleCreateProject(args: TaskManagerParams): TronToolResult {
    if (!args.projectTitle) return { content: 'Error: projectTitle is required', isError: true };

    const project = this.config.service.createProject({
      title: args.projectTitle,
      description: args.projectDescription,
      tags: args.projectTags,
      workspaceId: args.workspaceId ?? this.config.getWorkspaceId(),
      areaId: args.areaId,
    });

    const details = this.config.service.getProjectWithDetails(project.id)!;
    const actionLine = `Created project ${project.id}: ${project.title}`;

    return {
      content: `${actionLine}\n\n${this.formatProjectDetail(details)}`,
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
      areaId: args.areaId,
    });

    const details = this.config.service.getProjectWithDetails(args.projectId)!;
    const actionLine = `Updated project ${project.id}: ${project.title} [${project.status}]`;

    return {
      content: `${actionLine}\n\n${this.formatProjectDetail(details)}`,
      isError: false,
    };
  }

  private handleListProjects(args: TaskManagerParams): TronToolResult {
    const filter: Record<string, unknown> = {};
    if (args.projectStatus) filter.status = args.projectStatus;
    if (args.workspaceId) filter.workspaceId = args.workspaceId;
    if (args.areaId) filter.areaId = args.areaId;

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

  private handleGetProject(args: TaskManagerParams): TronToolResult {
    if (!args.projectId) return { content: 'Error: projectId is required for get_project', isError: true };

    const details = this.config.service.getProjectWithDetails(args.projectId);
    if (!details) return { content: `Project not found: ${args.projectId}`, isError: true };

    return { content: this.formatProjectDetail(details), isError: false };
  }

  private handleDeleteProject(args: TaskManagerParams): TronToolResult {
    if (!args.projectId) return { content: 'Error: projectId is required for delete_project', isError: true };

    const project = this.config.service.getProjectWithDetails(args.projectId);
    if (!project) return { content: `Project not found: ${args.projectId}`, isError: true };

    // Capture snapshot before deletion
    const snapshot = this.formatProjectDetail(project);
    this.config.service.deleteProject(args.projectId);

    const actionLine = `Deleted project ${args.projectId}: ${project.title}`;

    return {
      content: `${actionLine}\n\n${snapshot}`,
      isError: false,
    };
  }

  private handleCreateArea(args: TaskManagerParams): TronToolResult {
    if (!args.areaTitle) return { content: 'Error: areaTitle is required for create_area', isError: true };

    const area = this.config.service.createArea({
      title: args.areaTitle,
      description: args.areaDescription,
      tags: args.areaTags,
    });

    const areaWithCounts = this.config.service.getArea(area.id)!;
    const actionLine = `Created area ${area.id}: ${area.title} [${area.status}]`;

    return {
      content: `${actionLine}\n\n${this.formatAreaDetail(areaWithCounts)}`,
      isError: false,
    };
  }

  private handleUpdateArea(args: TaskManagerParams): TronToolResult {
    if (!args.areaId) return { content: 'Error: areaId is required for update_area', isError: true };

    const area = this.config.service.updateArea(args.areaId, {
      title: args.areaTitle,
      description: args.areaDescription,
      status: args.areaStatus,
      tags: args.areaTags,
    });

    const areaWithCounts = this.config.service.getArea(args.areaId)!;
    const actionLine = `Updated area ${area.id}: ${area.title} [${area.status}]`;

    return {
      content: `${actionLine}\n\n${this.formatAreaDetail(areaWithCounts)}`,
      isError: false,
    };
  }

  private handleGetArea(args: TaskManagerParams): TronToolResult {
    if (!args.areaId) return { content: 'Error: areaId is required for get_area', isError: true };

    const area = this.config.service.getArea(args.areaId);
    if (!area) return { content: `Area not found: ${args.areaId}`, isError: true };

    return { content: this.formatAreaDetail(area), isError: false };
  }

  private handleDeleteArea(args: TaskManagerParams): TronToolResult {
    if (!args.areaId) return { content: 'Error: areaId is required for delete_area', isError: true };

    const area = this.config.service.getArea(args.areaId);
    if (!area) return { content: `Area not found: ${args.areaId}`, isError: true };

    // Capture snapshot before deletion
    const snapshot = this.formatAreaDetail(area);
    this.config.service.deleteArea(args.areaId);

    const actionLine = `Deleted area ${args.areaId}: ${area.title}`;

    return {
      content: `${actionLine}\n\n${snapshot}`,
      isError: false,
    };
  }

  private handleListAreas(args: TaskManagerParams): TronToolResult {
    const filter: Record<string, unknown> = {};
    if (args.areaStatus) filter.status = args.areaStatus;

    const result = this.config.service.listAreas(filter as any);

    if (result.areas.length === 0) {
      return { content: 'No areas found.', isError: false };
    }

    const lines: string[] = [`Areas (${result.areas.length}):`];
    for (const area of result.areas) {
      const counts = `${area.projectCount}p/${area.taskCount}t (${area.activeTaskCount} active)`;
      lines.push(`  ${area.id}: ${area.title} [${area.status}] ${counts}`);
    }

    return { content: lines.join('\n'), isError: false };
  }
}
