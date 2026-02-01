/**
 * @fileoverview JSON export plugin
 */

import type { ExportPlugin, ExportOptions } from '../types.js';
import type { DashboardSessionSummary } from '../../types/session.js';
import type { TronSessionEvent } from '@tron/agent';

/**
 * Export session data as JSON
 */
async function exportAsJson(
  session: DashboardSessionSummary,
  events: TronSessionEvent[],
  options?: ExportOptions
): Promise<string> {
  const exportData: Record<string, unknown> = {
    exportedAt: new Date().toISOString(),
    format: 'tron-session-export',
    version: '1.0.0',
  };

  if (options?.includeMetadata !== false) {
    exportData.session = {
      id: session.id,
      title: session.title,
      workingDirectory: session.workingDirectory,
      model: session.model,
      createdAt: session.createdAt,
      lastActivityAt: session.lastActivityAt,
      endedAt: session.endedAt,
      isEnded: session.isEnded,
      eventCount: session.eventCount,
      messageCount: session.messageCount,
      turnCount: session.turnCount,
      totalInputTokens: session.totalInputTokens,
      totalOutputTokens: session.totalOutputTokens,
      totalCost: session.totalCost,
      tags: session.tags,
    };
  }

  exportData.events = events.map((event) => ({
    id: event.id,
    type: event.type,
    timestamp: event.timestamp,
    sequence: event.sequence,
    parentId: event.parentId,
    payload: event.payload,
  }));

  return JSON.stringify(exportData, null, 2);
}

/**
 * JSON export plugin
 */
export const jsonExporterPlugin: ExportPlugin = {
  id: 'json-export',
  name: 'JSON Export',
  extension: 'json',
  mimeType: 'application/json',

  async export(
    session: DashboardSessionSummary,
    events: TronSessionEvent[],
    options?: ExportOptions
  ): Promise<string> {
    return exportAsJson(session, events, options);
  },
};
