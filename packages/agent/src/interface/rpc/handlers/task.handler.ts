/**
 * @fileoverview Task RPC Handlers
 *
 * Handlers for tasks.* and projects.* RPC methods.
 * Delegates to TaskRpcManager for all operations.
 */

import type { MethodRegistration, MethodHandler } from '../registry.js';

// =============================================================================
// Handler Factory
// =============================================================================

export function createTaskHandlers(): MethodRegistration[] {
  const listHandler: MethodHandler<{ status?: string; projectId?: string; limit?: number; offset?: number }> = async (request, context) => {
    const params = request.params ?? {};
    return context.taskManager!.listTasks(params);
  };

  const getHandler: MethodHandler<{ taskId: string }> = async (request, context) => {
    const params = request.params!;
    return context.taskManager!.getTask(params.taskId);
  };

  const createHandler: MethodHandler<Record<string, unknown>> = async (request, context) => {
    const params = request.params!;
    return context.taskManager!.createTask(params);
  };

  const updateHandler: MethodHandler<{ taskId: string } & Record<string, unknown>> = async (request, context) => {
    const params = request.params!;
    const { taskId, ...rest } = params;
    return context.taskManager!.updateTask(taskId, rest);
  };

  const deleteHandler: MethodHandler<{ taskId: string }> = async (request, context) => {
    const params = request.params!;
    return context.taskManager!.deleteTask(params.taskId);
  };

  const searchHandler: MethodHandler<{ query: string; limit?: number }> = async (request, context) => {
    const params = request.params!;
    return context.taskManager!.searchTasks(params.query, params.limit);
  };

  const getActivityHandler: MethodHandler<{ taskId: string; limit?: number }> = async (request, context) => {
    const params = request.params!;
    return context.taskManager!.getActivity(params.taskId, params.limit);
  };

  const listProjectsHandler: MethodHandler<{ status?: string; limit?: number }> = async (request, context) => {
    const params = request.params ?? {};
    return context.taskManager!.listProjects(params);
  };

  const getProjectHandler: MethodHandler<{ projectId: string }> = async (request, context) => {
    const params = request.params!;
    return context.taskManager!.getProject(params.projectId);
  };

  const createProjectHandler: MethodHandler<Record<string, unknown>> = async (request, context) => {
    const params = request.params!;
    return context.taskManager!.createProject(params);
  };

  const updateProjectHandler: MethodHandler<{ projectId: string } & Record<string, unknown>> = async (request, context) => {
    const params = request.params!;
    const { projectId, ...rest } = params;
    return context.taskManager!.updateProject(projectId, rest);
  };

  const getProjectWithDetailsHandler: MethodHandler<{ projectId: string }> = async (request, context) => {
    const params = request.params!;
    return context.taskManager!.getProjectWithDetails(params.projectId);
  };

  const deleteProjectHandler: MethodHandler<{ projectId: string }> = async (request, context) => {
    const params = request.params!;
    return context.taskManager!.deleteProject(params.projectId);
  };

  const listAreasHandler: MethodHandler<{ status?: string; limit?: number; offset?: number }> = async (request, context) => {
    const params = request.params ?? {};
    return context.taskManager!.listAreas(params);
  };

  const getAreaHandler: MethodHandler<{ areaId: string }> = async (request, context) => {
    const params = request.params!;
    return context.taskManager!.getArea(params.areaId);
  };

  const createAreaHandler: MethodHandler<Record<string, unknown>> = async (request, context) => {
    const params = request.params!;
    return context.taskManager!.createArea(params);
  };

  const updateAreaHandler: MethodHandler<{ areaId: string } & Record<string, unknown>> = async (request, context) => {
    const params = request.params!;
    const { areaId, ...rest } = params;
    return context.taskManager!.updateArea(areaId, rest);
  };

  const deleteAreaHandler: MethodHandler<{ areaId: string }> = async (request, context) => {
    const params = request.params!;
    return context.taskManager!.deleteArea(params.areaId);
  };

  return [
    {
      method: 'tasks.list',
      handler: listHandler,
      options: {
        requiredManagers: ['taskManager'],
        description: 'List tasks with optional filters',
      },
    },
    {
      method: 'tasks.get',
      handler: getHandler,
      options: {
        requiredParams: ['taskId'],
        requiredManagers: ['taskManager'],
        description: 'Get a task by ID',
      },
    },
    {
      method: 'tasks.create',
      handler: createHandler,
      options: {
        requiredParams: ['title'],
        requiredManagers: ['taskManager'],
        description: 'Create a task',
      },
    },
    {
      method: 'tasks.update',
      handler: updateHandler,
      options: {
        requiredParams: ['taskId'],
        requiredManagers: ['taskManager'],
        description: 'Update a task',
      },
    },
    {
      method: 'tasks.delete',
      handler: deleteHandler,
      options: {
        requiredParams: ['taskId'],
        requiredManagers: ['taskManager'],
        description: 'Delete a task',
      },
    },
    {
      method: 'tasks.search',
      handler: searchHandler,
      options: {
        requiredParams: ['query'],
        requiredManagers: ['taskManager'],
        description: 'Search tasks by text',
      },
    },
    {
      method: 'tasks.getActivity',
      handler: getActivityHandler,
      options: {
        requiredParams: ['taskId'],
        requiredManagers: ['taskManager'],
        description: 'Get activity log for a task',
      },
    },
    {
      method: 'projects.list',
      handler: listProjectsHandler,
      options: {
        requiredManagers: ['taskManager'],
        description: 'List projects',
      },
    },
    {
      method: 'projects.get',
      handler: getProjectHandler,
      options: {
        requiredParams: ['projectId'],
        requiredManagers: ['taskManager'],
        description: 'Get a project by ID',
      },
    },
    {
      method: 'projects.create',
      handler: createProjectHandler,
      options: {
        requiredParams: ['projectTitle'],
        requiredManagers: ['taskManager'],
        description: 'Create a project',
      },
    },
    {
      method: 'projects.update',
      handler: updateProjectHandler,
      options: {
        requiredParams: ['projectId'],
        requiredManagers: ['taskManager'],
        description: 'Update a project',
      },
    },
    {
      method: 'projects.getDetails',
      handler: getProjectWithDetailsHandler,
      options: {
        requiredParams: ['projectId'],
        requiredManagers: ['taskManager'],
        description: 'Get project with tasks and area details',
      },
    },
    {
      method: 'projects.delete',
      handler: deleteProjectHandler,
      options: {
        requiredParams: ['projectId'],
        requiredManagers: ['taskManager'],
        description: 'Delete a project',
      },
    },
    {
      method: 'areas.list',
      handler: listAreasHandler,
      options: {
        requiredManagers: ['taskManager'],
        description: 'List areas with optional filters',
      },
    },
    {
      method: 'areas.get',
      handler: getAreaHandler,
      options: {
        requiredParams: ['areaId'],
        requiredManagers: ['taskManager'],
        description: 'Get an area by ID',
      },
    },
    {
      method: 'areas.create',
      handler: createAreaHandler,
      options: {
        requiredParams: ['title'],
        requiredManagers: ['taskManager'],
        description: 'Create an area',
      },
    },
    {
      method: 'areas.update',
      handler: updateAreaHandler,
      options: {
        requiredParams: ['areaId'],
        requiredManagers: ['taskManager'],
        description: 'Update an area',
      },
    },
    {
      method: 'areas.delete',
      handler: deleteAreaHandler,
      options: {
        requiredParams: ['areaId'],
        requiredManagers: ['taskManager'],
        description: 'Delete an area',
      },
    },
  ];
}
