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
