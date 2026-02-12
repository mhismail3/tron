/**
 * @fileoverview Task Events
 *
 * Broadcast event types for real-time UI updates.
 * These are NOT for event sourcing — the tasks table is the source of truth.
 */

import type { BaseEvent } from './base.js';

export interface TaskCreatedEvent extends BaseEvent {
  type: 'task.created';
  payload: {
    taskId: string;
    title: string;
    status: string;
    projectId: string | null;
  };
}

export interface TaskUpdatedEvent extends BaseEvent {
  type: 'task.updated';
  payload: {
    taskId: string;
    title: string;
    status: string;
    changedFields: string[];
  };
}

export interface TaskDeletedEvent extends BaseEvent {
  type: 'task.deleted';
  payload: {
    taskId: string;
    title: string;
  };
}

export interface ProjectUpdatedEvent extends BaseEvent {
  type: 'project.updated';
  payload: {
    projectId: string;
    title: string;
    status: string;
  };
}

export interface ProjectCreatedEvent extends BaseEvent {
  type: 'project.created';
  payload: {
    projectId: string;
    title: string;
    status: string;
    areaId: string | null;
  };
}

export interface ProjectDeletedEvent extends BaseEvent {
  type: 'project.deleted';
  payload: {
    projectId: string;
    title: string;
  };
}

export interface AreaCreatedEvent extends BaseEvent {
  type: 'area.created';
  payload: {
    areaId: string;
    title: string;
    status: string;
  };
}

export interface AreaUpdatedEvent extends BaseEvent {
  type: 'area.updated';
  payload: {
    areaId: string;
    title: string;
    status: string;
    changedFields: string[];
  };
}

export interface AreaDeletedEvent extends BaseEvent {
  type: 'area.deleted';
  payload: {
    areaId: string;
    title: string;
  };
}
