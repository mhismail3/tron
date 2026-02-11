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
      return service.createTask(params as any);
    },

    updateTask(taskId: string, params: Record<string, unknown>) {
      return service.updateTask(taskId, params as any);
    },

    deleteTask(taskId: string) {
      service.deleteTask(taskId);
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
