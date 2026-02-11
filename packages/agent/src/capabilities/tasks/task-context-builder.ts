/**
 * @fileoverview Task Context Builder
 *
 * Generates the Tier 1 auto-injected summary for the LLM system prompt.
 * Reads directly from SQLite each turn. Returns undefined when no open tasks exist.
 */

import { TaskRepository } from './task-repository.js';

export class TaskContextBuilder {
  constructor(private readonly repo: TaskRepository) {}

  buildSummary(workspaceId?: string): string | undefined {
    const summary = this.repo.getActiveTaskSummary(workspaceId);
    const blockedCount = this.repo.getBlockedTaskCount(workspaceId);
    const projects = this.repo.getActiveProjectProgress(workspaceId);

    const { inProgress, pendingCount, overdueCount, deferredCount } = summary;

    // Nothing to show
    if (inProgress.length === 0 && pendingCount === 0 && blockedCount === 0 && projects.length === 0) {
      return undefined;
    }

    const lines: string[] = [];

    // Header line with counts
    const parts: string[] = [];
    if (inProgress.length > 0) parts.push(`${inProgress.length} in progress`);
    if (pendingCount > 0) parts.push(`${pendingCount} pending`);
    if (blockedCount > 0) parts.push(`${blockedCount} blocked`);
    if (parts.length > 0) {
      lines.push(`Active: ${parts.join(', ')}`);
    }

    // In-progress tasks with detail
    if (inProgress.length > 0) {
      lines.push('In Progress:');
      for (const task of inProgress) {
        const meta: string[] = [];
        if (task.priority !== 'medium') meta.push(`P:${task.priority}`);
        if (task.estimatedMinutes) {
          meta.push(`${task.actualMinutes}/${task.estimatedMinutes}min`);
        }
        if (task.dueDate) meta.push(`due:${task.dueDate}`);
        const suffix = meta.length > 0 ? ` (${meta.join(', ')})` : '';
        lines.push(`  - [${task.id}] ${task.title}${suffix}`);
      }
    }

    // Project progress
    if (projects.length > 0) {
      const projectParts = projects.map(p => `${p.title} (${p.done}/${p.total})`);
      lines.push(`Projects: ${projectParts.join(', ')}`);
    }

    // Overdue / deferred warnings
    const warnings: string[] = [];
    if (overdueCount > 0) warnings.push(`${overdueCount} task${overdueCount > 1 ? 's' : ''} overdue`);
    if (deferredCount > 0) warnings.push(`${deferredCount} task${deferredCount > 1 ? 's' : ''} deferred`);
    if (warnings.length > 0) {
      lines.push(warnings.join(' | '));
    }

    return lines.join('\n');
  }
}
