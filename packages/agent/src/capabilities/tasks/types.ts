/**
 * @fileoverview Task Management Types
 *
 * Domain types for the persistent task and project management system.
 * Tasks persist across sessions in SQLite, support hierarchy (project → task → subtask),
 * dependencies, time tracking, and full-text search.
 */

// =============================================================================
// Status & Classification Enums
// =============================================================================

export type TaskStatus = 'backlog' | 'pending' | 'in_progress' | 'completed' | 'cancelled';
export type TaskPriority = 'low' | 'medium' | 'high' | 'critical';
export type TaskSource = 'agent' | 'user' | 'skill' | 'system';

export type ProjectStatus = 'active' | 'paused' | 'completed' | 'archived';

export type AreaStatus = 'active' | 'archived';

export type DependencyRelationship = 'blocks' | 'related';

export type ActivityAction =
  | 'created'
  | 'status_changed'
  | 'updated'
  | 'note_added'
  | 'time_logged'
  | 'dependency_added'
  | 'dependency_removed'
  | 'moved'
  | 'deleted';

// =============================================================================
// Domain Types
// =============================================================================

export interface Task {
  id: string;
  projectId: string | null;
  parentTaskId: string | null;
  workspaceId: string | null;
  areaId: string | null;

  title: string;
  description: string | null;
  activeForm: string | null;
  notes: string | null;

  status: TaskStatus;
  priority: TaskPriority;
  source: TaskSource;
  tags: string[];

  dueDate: string | null;
  deferredUntil: string | null;
  startedAt: string | null;
  completedAt: string | null;
  createdAt: string;
  updatedAt: string;

  estimatedMinutes: number | null;
  actualMinutes: number;

  createdBySessionId: string | null;
  lastSessionId: string | null;
  lastSessionAt: string | null;

  sortOrder: number;
  metadata: Record<string, unknown> | null;
}

export interface Project {
  id: string;
  workspaceId: string | null;
  areaId: string | null;
  title: string;
  description: string | null;
  status: ProjectStatus;
  tags: string[];
  createdAt: string;
  updatedAt: string;
  completedAt: string | null;
  metadata: Record<string, unknown> | null;
}

export interface Area {
  id: string;
  workspaceId: string;
  title: string;
  description: string | null;
  status: AreaStatus;
  tags: string[];
  sortOrder: number;
  createdAt: string;
  updatedAt: string;
  metadata: Record<string, unknown>;
}

export interface AreaWithCounts extends Area {
  projectCount: number;
  taskCount: number;
  activeTaskCount: number;
}

export interface TaskDependency {
  blockerTaskId: string;
  blockedTaskId: string;
  relationship: DependencyRelationship;
  createdAt: string;
}

export interface TaskActivity {
  id: number;
  taskId: string;
  sessionId: string | null;
  eventId: string | null;
  action: ActivityAction;
  oldValue: string | null;
  newValue: string | null;
  detail: string | null;
  minutesLogged: number | null;
  timestamp: string;
}

// =============================================================================
// Mutation Params
// =============================================================================

export interface TaskCreateParams {
  title: string;
  description?: string;
  activeForm?: string;
  projectId?: string;
  parentTaskId?: string;
  workspaceId?: string;
  areaId?: string;
  status?: TaskStatus;
  priority?: TaskPriority;
  source?: TaskSource;
  tags?: string[];
  dueDate?: string;
  deferredUntil?: string;
  estimatedMinutes?: number;
  sessionId?: string;
}

export interface TaskUpdateParams {
  status?: TaskStatus;
  title?: string;
  description?: string;
  activeForm?: string;
  priority?: TaskPriority;
  dueDate?: string | null;
  deferredUntil?: string | null;
  estimatedMinutes?: number | null;
  notes?: string;
  addTags?: string[];
  removeTags?: string[];
  projectId?: string | null;
  parentTaskId?: string | null;
  areaId?: string | null;
  sessionId?: string;
}

export interface ProjectCreateParams {
  title: string;
  description?: string;
  tags?: string[];
  workspaceId?: string;
  areaId?: string;
}

export interface ProjectUpdateParams {
  title?: string;
  description?: string;
  status?: ProjectStatus;
  tags?: string[];
  areaId?: string | null;
}

export interface AreaCreateParams {
  title: string;
  description?: string;
  tags?: string[];
  workspaceId?: string;
  metadata?: Record<string, unknown>;
}

export interface AreaUpdateParams {
  title?: string;
  description?: string;
  status?: AreaStatus;
  tags?: string[];
  sortOrder?: number;
  metadata?: Record<string, unknown>;
}

// =============================================================================
// Query Types
// =============================================================================

export interface TaskFilter {
  status?: TaskStatus | TaskStatus[];
  priority?: TaskPriority | TaskPriority[];
  tags?: string[];
  projectId?: string;
  workspaceId?: string;
  areaId?: string;
  parentTaskId?: string | null;
  dueBefore?: string;
  includeCompleted?: boolean;
  includeDeferred?: boolean;
  includeBacklog?: boolean;
}

export interface ProjectFilter {
  status?: ProjectStatus | ProjectStatus[];
  workspaceId?: string;
  areaId?: string;
}

export interface AreaFilter {
  status?: AreaStatus;
  workspaceId?: string;
}

// =============================================================================
// Composite Result Types
// =============================================================================

export interface TaskWithDetails extends Task {
  subtasks: Task[];
  blockedBy: TaskDependency[];
  blocks: TaskDependency[];
  recentActivity: TaskActivity[];
}

export interface TaskListResult {
  tasks: Task[];
  total: number;
}

export interface ProjectWithProgress extends Project {
  taskCount: number;
  completedTaskCount: number;
}

export interface ProjectListResult {
  projects: ProjectWithProgress[];
  total: number;
}

export interface ProjectWithDetails extends ProjectWithProgress {
  area?: Area;
  tasks: Task[];
}

export interface AreaListResult {
  areas: AreaWithCounts[];
  total: number;
}
