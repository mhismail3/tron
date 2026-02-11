/**
 * @fileoverview Task Adapter
 *
 * Adapts task operations from the orchestrator to the TaskRpcManager interface.
 * Delegates all operations to the persistent TaskService via orchestrator.taskService.
 */

import type { TaskRpcManager } from '../../../rpc/context-types.js';
import type { AdapterDependencies } from '../types.js';

// =============================================================================
// Task Adapter Factory
// =============================================================================

export function createTaskAdapter(deps: AdapterDependencies): TaskRpcManager {
  const { orchestrator } = deps;
  const service = orchestrator.taskService;

  return {
    listTasks(filter?: Record<string, unknown>) {
      return service.listTasks(filter as any);
    },

    getTask(taskId: string) {
      return service.getTask(taskId);
    },

    createTask(params: Record<string, unknown>) {
      const task = service.createTask(params as any);
      orchestrator.emit('task_created', {
        taskId: task.id,
        title: task.title,
        status: task.status,
        projectId: task.projectId ?? null,
      });
      return task;
    },

    updateTask(taskId: string, params: Record<string, unknown>) {
      const task = service.updateTask(taskId, params as any);
      const changedFields = Object.keys(params).filter(k => k !== 'sessionId');
      orchestrator.emit('task_updated', {
        taskId: task.id,
        title: task.title,
        status: task.status,
        changedFields,
      });
      return task;
    },

    deleteTask(taskId: string) {
      const task = service.getTask(taskId);
      const title = task?.title ?? '';
      service.deleteTask(taskId);
      orchestrator.emit('task_deleted', { taskId, title });
      return { success: true };
    },

    searchTasks(query: string, limit?: number) {
      return service.searchTasks(query, limit);
    },

    getActivity(taskId: string, limit?: number) {
      return service.getActivity(taskId, limit);
    },

    listProjects(filter?: Record<string, unknown>) {
      return service.listProjects(filter as any);
    },

    getProject(projectId: string) {
      return service.getProject(projectId);
    },

    createProject(params: Record<string, unknown>) {
      return service.createProject(params as any);
    },

    updateProject(projectId: string, params: Record<string, unknown>) {
      return service.updateProject(projectId, params as any);
    },
  };
}
