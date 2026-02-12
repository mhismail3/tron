/**
 * @fileoverview Task Service
 *
 * Business logic layer for task management. Handles validation,
 * auto-transitions, activity logging, and constraint enforcement.
 */

import { TaskRepository } from './task-repository.js';
import type {
  Task,
  Area,
  AreaWithCounts,
  Project,
  TaskWithDetails,
  TaskListResult,
  ProjectListResult,
  ProjectWithDetails,
  AreaListResult,
  TaskCreateParams,
  TaskUpdateParams,
  ProjectCreateParams,
  ProjectUpdateParams,
  AreaCreateParams,
  AreaUpdateParams,
  TaskFilter,
  ProjectFilter,
  AreaFilter,
  DependencyRelationship,
} from './types.js';

export class TaskService {
  constructor(
    private readonly repo: TaskRepository,
    private readonly emit?: (event: string, data: Record<string, unknown>) => void,
  ) {}

  // ===========================================================================
  // Task Operations
  // ===========================================================================

  createTask(params: TaskCreateParams): Task {
    const task = this.repo.createTask({
      title: params.title,
      description: params.description,
      activeForm: params.activeForm,
      projectId: params.projectId,
      parentTaskId: params.parentTaskId,
      workspaceId: params.workspaceId,
      areaId: params.areaId,
      status: params.status ?? 'pending',
      priority: params.priority ?? 'medium',
      source: params.source ?? 'agent',
      tags: params.tags,
      dueDate: params.dueDate,
      deferredUntil: params.deferredUntil,
      estimatedMinutes: params.estimatedMinutes,
      createdBySessionId: params.sessionId,
    });

    // Enforce max 2-level hierarchy
    if (params.parentTaskId) {
      const parent = this.repo.getTask(params.parentTaskId);
      if (parent?.parentTaskId) {
        // Parent is already a subtask — reject
        this.repo.deleteTask(task.id);
        throw new Error('Subtasks cannot have children (max 2-level hierarchy: project → task → subtask)');
      }
    }

    // Auto-set startedAt if created as in_progress
    if (params.status === 'in_progress') {
      this.repo.updateTask(task.id, { startedAt: task.createdAt });
    }

    // Auto-set completedAt if created as completed/cancelled
    if (params.status === 'completed' || params.status === 'cancelled') {
      this.repo.updateTask(task.id, { completedAt: task.createdAt });
    }

    this.repo.logActivity({
      taskId: task.id,
      sessionId: params.sessionId,
      action: 'created',
      detail: `Created: ${task.title}`,
    });

    const result = this.repo.getTask(task.id)!;
    this.emit?.('task.created', {
      taskId: result.id,
      title: result.title,
      status: result.status,
      projectId: result.projectId ?? null,
    });
    return result;
  }

  updateTask(taskId: string, params: TaskUpdateParams): Task {
    const existing = this.repo.getTask(taskId);
    if (!existing) {
      throw new Error(`Task not found: ${taskId}`);
    }

    const updates: Record<string, unknown> = {};

    // Simple field updates
    if (params.title !== undefined) updates.title = params.title;
    if (params.description !== undefined) updates.description = params.description;
    if (params.activeForm !== undefined) updates.activeForm = params.activeForm;
    if (params.priority !== undefined) updates.priority = params.priority;
    if (params.dueDate !== undefined) updates.dueDate = params.dueDate;
    if (params.deferredUntil !== undefined) updates.deferredUntil = params.deferredUntil;
    if (params.estimatedMinutes !== undefined) updates.estimatedMinutes = params.estimatedMinutes;
    if (params.projectId !== undefined) updates.projectId = params.projectId;
    if (params.areaId !== undefined) updates.areaId = params.areaId;

    // Parent task change with hierarchy enforcement
    if (params.parentTaskId !== undefined) {
      if (params.parentTaskId !== null) {
        const newParent = this.repo.getTask(params.parentTaskId);
        if (newParent?.parentTaskId) {
          throw new Error('Cannot nest under a subtask (max 2-level hierarchy)');
        }
      }
      updates.parentTaskId = params.parentTaskId;
    }

    // Tag operations
    if (params.addTags || params.removeTags) {
      let tags = [...existing.tags];
      if (params.addTags) {
        for (const tag of params.addTags) {
          if (!tags.includes(tag)) tags.push(tag);
        }
      }
      if (params.removeTags) {
        tags = tags.filter(t => !params.removeTags!.includes(t));
      }
      updates.tags = tags;
    }

    // Note appending (timestamped)
    if (params.notes) {
      const timestamp = new Date().toISOString().split('T')[0];
      const newNote = `[${timestamp}] ${params.notes}`;
      const existingNotes = existing.notes ?? '';
      updates.notes = existingNotes ? `${existingNotes}\n${newNote}` : newNote;

      this.repo.logActivity({
        taskId,
        sessionId: params.sessionId,
        action: 'note_added',
        detail: params.notes,
      });
    }

    // Status transitions with auto-timestamps
    if (params.status && params.status !== existing.status) {
      const oldStatus = existing.status;
      updates.status = params.status;

      // Auto-set startedAt
      if (params.status === 'in_progress' && !existing.startedAt) {
        updates.startedAt = new Date().toISOString();
      }

      // Auto-set completedAt
      if (params.status === 'completed' || params.status === 'cancelled') {
        updates.completedAt = new Date().toISOString();
      }

      // Clear completedAt if reopening
      if ((oldStatus === 'completed' || oldStatus === 'cancelled') &&
          (params.status === 'pending' || params.status === 'in_progress')) {
        updates.completedAt = null;
      }

      this.repo.logActivity({
        taskId,
        sessionId: params.sessionId,
        action: 'status_changed',
        oldValue: oldStatus,
        newValue: params.status,
      });
    }

    // Session tracking
    if (params.sessionId) {
      updates.lastSessionId = params.sessionId;
      updates.lastSessionAt = new Date().toISOString();
    }

    // Log general update if no status change and no note
    if (!params.status && !params.notes && Object.keys(updates).length > 0) {
      const changedFields = Object.keys(updates).filter(k => k !== 'lastSessionId' && k !== 'lastSessionAt');
      if (changedFields.length > 0) {
        this.repo.logActivity({
          taskId,
          sessionId: params.sessionId,
          action: 'updated',
          detail: `Updated: ${changedFields.join(', ')}`,
        });
      }
    }

    if (Object.keys(updates).length > 0) {
      this.repo.updateTask(taskId, updates);
    }

    const result = this.repo.getTask(taskId)!;
    const changedFields = Object.keys(updates).filter(k => k !== 'lastSessionId' && k !== 'lastSessionAt');
    if (changedFields.length > 0) {
      this.emit?.('task.updated', {
        taskId: result.id,
        title: result.title,
        status: result.status,
        changedFields,
      });
    }
    return result;
  }

  getTask(taskId: string): TaskWithDetails | undefined {
    const task = this.repo.getTask(taskId);
    if (!task) return undefined;

    return {
      ...task,
      subtasks: this.repo.getSubtasks(taskId),
      blockedBy: this.repo.getBlockedBy(taskId),
      blocks: this.repo.getBlocks(taskId),
      recentActivity: this.repo.getActivity(taskId, 10),
    };
  }

  listTasks(filter?: TaskFilter, limit?: number, offset?: number): TaskListResult {
    return this.repo.listTasks(filter, limit, offset);
  }

  searchTasks(query: string, limit?: number): Task[] {
    return this.repo.searchTasks(query, limit);
  }

  getActivity(taskId: string, limit?: number) {
    return this.repo.getActivity(taskId, limit);
  }

  deleteTask(taskId: string): boolean {
    const task = this.repo.getTask(taskId);
    if (!task) return false;

    this.repo.logActivity({
      taskId,
      action: 'deleted',
      detail: `Deleted: ${task.title}`,
    });

    const deleted = this.repo.deleteTask(taskId);
    if (deleted) {
      this.emit?.('task.deleted', { taskId, title: task.title });
    }
    return deleted;
  }

  // ===========================================================================
  // Time Tracking
  // ===========================================================================

  logTime(taskId: string, minutes: number, sessionId?: string, note?: string): Task {
    const task = this.repo.getTask(taskId);
    if (!task) throw new Error(`Task not found: ${taskId}`);

    this.repo.incrementActualMinutes(taskId, minutes);

    this.repo.logActivity({
      taskId,
      sessionId,
      action: 'time_logged',
      minutesLogged: minutes,
      detail: note ?? `Logged ${minutes}min`,
    });

    return this.repo.getTask(taskId)!;
  }

  // ===========================================================================
  // Dependencies
  // ===========================================================================

  addDependency(blockerTaskId: string, blockedTaskId: string, relationship: DependencyRelationship = 'blocks'): void {
    if (relationship === 'blocks' && this.repo.hasCircularDependency(blockerTaskId, blockedTaskId)) {
      throw new Error('Circular dependency detected');
    }

    this.repo.addDependency(blockerTaskId, blockedTaskId, relationship);

    this.repo.logActivity({
      taskId: blockedTaskId,
      action: 'dependency_added',
      detail: `Blocked by ${blockerTaskId} (${relationship})`,
    });

    this.repo.logActivity({
      taskId: blockerTaskId,
      action: 'dependency_added',
      detail: `Blocks ${blockedTaskId} (${relationship})`,
    });
  }

  removeDependency(blockerTaskId: string, blockedTaskId: string): void {
    const removed = this.repo.removeDependency(blockerTaskId, blockedTaskId);
    if (removed) {
      this.repo.logActivity({
        taskId: blockedTaskId,
        action: 'dependency_removed',
        detail: `No longer blocked by ${blockerTaskId}`,
      });
    }
  }

  // ===========================================================================
  // Project Operations
  // ===========================================================================

  createProject(params: ProjectCreateParams): Project {
    const project = this.repo.createProject({
      title: params.title,
      description: params.description,
      tags: params.tags,
      workspaceId: params.workspaceId,
      areaId: params.areaId,
    });
    this.emit?.('project.created', {
      projectId: project.id,
      title: project.title,
      status: project.status,
      areaId: project.areaId ?? null,
    });
    return project;
  }

  updateProject(projectId: string, params: ProjectUpdateParams): Project {
    const existing = this.repo.getProject(projectId);
    if (!existing) throw new Error(`Project not found: ${projectId}`);

    const updates: Record<string, unknown> = {};
    if (params.title !== undefined) updates.title = params.title;
    if (params.description !== undefined) updates.description = params.description;
    if (params.status !== undefined) {
      updates.status = params.status;
      if (params.status === 'completed') {
        updates.completedAt = new Date().toISOString();
      }
    }
    if (params.tags !== undefined) updates.tags = params.tags;
    if (params.areaId !== undefined) updates.areaId = params.areaId;

    const result = this.repo.updateProject(projectId, updates)!;
    const changedFields = Object.keys(updates);
    if (changedFields.length > 0) {
      this.emit?.('project.updated', {
        projectId: result.id,
        title: result.title,
        status: result.status,
        changedFields,
      });
    }
    return result;
  }

  getProject(projectId: string): Project | undefined {
    return this.repo.getProject(projectId);
  }

  getProjectWithDetails(projectId: string): ProjectWithDetails | undefined {
    const allProjects = this.repo.listProjects({}, 1000, 0);
    const projectWithProgress = allProjects.projects.find(p => p.id === projectId);
    if (!projectWithProgress) return undefined;

    const tasks = this.repo.listTasks({ projectId, includeCompleted: true, includeBacklog: true }, 1000, 0).tasks;
    const area = projectWithProgress.areaId
      ? this.repo.getArea(projectWithProgress.areaId)
      : undefined;

    return {
      ...projectWithProgress,
      tasks,
      area,
    };
  }

  deleteProject(projectId: string): boolean {
    const project = this.repo.getProject(projectId);
    if (!project) return false;

    const deleted = this.repo.deleteProject(projectId);
    if (deleted) {
      this.emit?.('project.deleted', { projectId, title: project.title });
    }
    return deleted;
  }

  listProjects(filter?: ProjectFilter, limit?: number, offset?: number): ProjectListResult {
    return this.repo.listProjects(filter, limit, offset);
  }

  // ===========================================================================
  // Area Operations
  // ===========================================================================

  createArea(params: AreaCreateParams): Area {
    if (!params.title?.trim()) {
      throw new Error('Area title is required');
    }

    const area = this.repo.createArea({
      title: params.title,
      description: params.description,
      tags: params.tags,
      workspaceId: params.workspaceId,
      metadata: params.metadata,
    });

    this.emit?.('area.created', {
      areaId: area.id,
      title: area.title,
      status: area.status,
    });

    return area;
  }

  getArea(areaId: string): AreaWithCounts | undefined {
    const result = this.repo.listAreas({}, 1000, 0);
    return result.areas.find(a => a.id === areaId);
  }

  updateArea(areaId: string, params: AreaUpdateParams): Area {
    const existing = this.repo.getArea(areaId);
    if (!existing) throw new Error(`Area not found: ${areaId}`);

    const updates: Record<string, unknown> = {};
    if (params.title !== undefined) updates.title = params.title;
    if (params.description !== undefined) updates.description = params.description;
    if (params.status !== undefined) updates.status = params.status;
    if (params.tags !== undefined) updates.tags = params.tags;
    if (params.sortOrder !== undefined) updates.sortOrder = params.sortOrder;
    if (params.metadata !== undefined) updates.metadata = params.metadata;

    const result = this.repo.updateArea(areaId, updates)!;
    const changedFields = Object.keys(updates);
    if (changedFields.length > 0) {
      this.emit?.('area.updated', {
        areaId: result.id,
        title: result.title,
        status: result.status,
        changedFields,
      });
    }
    return result;
  }

  deleteArea(areaId: string): boolean {
    const area = this.repo.getArea(areaId);
    if (!area) return false;

    const deleted = this.repo.deleteArea(areaId);
    if (deleted) {
      this.emit?.('area.deleted', { areaId, title: area.title });
    }
    return deleted;
  }

  listAreas(filter?: AreaFilter, limit?: number, offset?: number): AreaListResult {
    return this.repo.listAreas(filter, limit, offset);
  }

  searchAreas(query: string, limit?: number): Area[] {
    return this.repo.searchAreas(query, limit);
  }
}
