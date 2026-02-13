/**
 * @fileoverview Markdown export plugin
 */

import type { ExportPlugin, ExportOptions } from '../types.js';
import type { DashboardSessionSummary } from '../../types/session.js';
import type { TronSessionEvent } from '@tron/agent';
import { getEventTypeLabel } from '../../types/display.js';
import { formatTokenCount, formatCost } from '../../types/session.js';

/**
 * Format a date for display
 */
function formatDate(date: string): string {
  return new Date(date).toLocaleString();
}

/**
 * Export session data as Markdown
 */
async function exportAsMarkdown(
  session: DashboardSessionSummary,
  events: TronSessionEvent[],
  options?: ExportOptions
): Promise<string> {
  const lines: string[] = [];

  // Header
  lines.push(`# ${session.title || 'Untitled Session'}`);
  lines.push('');

  if (options?.includeMetadata !== false) {
    // Metadata
    lines.push('## Session Info');
    lines.push('');
    lines.push(`- **ID:** \`${session.id}\``);
    lines.push(`- **Directory:** \`${session.workingDirectory}\``);
    lines.push(`- **Model:** ${session.model}`);
    lines.push(`- **Created:** ${formatDate(session.createdAt)}`);
    lines.push(`- **Last Activity:** ${formatDate(session.lastActivityAt)}`);
    if (session.archivedAt) {
      lines.push(`- **Archived:** ${formatDate(session.archivedAt)}`);
    }
    lines.push(`- **Status:** ${session.isArchived ? 'Archived' : 'Active'}`);
    lines.push('');

    // Stats
    lines.push('## Statistics');
    lines.push('');
    lines.push(`- **Messages:** ${session.messageCount}`);
    lines.push(`- **Turns:** ${session.turnCount}`);
    lines.push(`- **Events:** ${session.eventCount}`);
    lines.push(`- **Input Tokens:** ${formatTokenCount(session.totalInputTokens)}`);
    lines.push(`- **Output Tokens:** ${formatTokenCount(session.totalOutputTokens)}`);
    lines.push(`- **Total Cost:** ${formatCost(session.totalCost)}`);
    lines.push('');
  }

  // Events
  lines.push('## Timeline');
  lines.push('');

  for (const event of events) {
    const label = getEventTypeLabel(event.type);
    const time = formatDate(event.timestamp);

    lines.push(`### ${label}`);
    lines.push('');
    lines.push(`*${time}* | \`${event.id}\``);
    lines.push('');

    // Format payload based on event type
    if (event.type === 'message.user') {
      const payload = event.payload as { content: string };
      lines.push('**User:**');
      lines.push('');
      lines.push(payload.content);
      lines.push('');
    } else if (event.type === 'message.assistant') {
      const payload = event.payload as { content: Array<{ type: string; text?: string }> };
      lines.push('**Assistant:**');
      lines.push('');
      for (const block of payload.content) {
        if (block.type === 'text' && block.text) {
          lines.push(block.text);
        }
      }
      lines.push('');
    } else if (event.type === 'tool.call') {
      const payload = event.payload as { name: string; arguments: unknown };
      lines.push(`**Tool Call:** \`${payload.name}\``);
      lines.push('');
      lines.push('```json');
      lines.push(JSON.stringify(payload.arguments, null, 2));
      lines.push('```');
      lines.push('');
    } else if (event.type === 'tool.result') {
      const payload = event.payload as { content: string; isError?: boolean };
      lines.push(`**Tool Result:** ${payload.isError ? '(Error)' : ''}`);
      lines.push('');
      lines.push('```');
      lines.push(payload.content);
      lines.push('```');
      lines.push('');
    } else {
      // Generic payload display
      lines.push('```json');
      lines.push(JSON.stringify(event.payload, null, 2));
      lines.push('```');
      lines.push('');
    }

    lines.push('---');
    lines.push('');
  }

  // Footer
  lines.push('');
  lines.push(`*Exported from Tron Dashboard at ${new Date().toISOString()}*`);

  return lines.join('\n');
}

/**
 * Markdown export plugin
 */
export const markdownExporterPlugin: ExportPlugin = {
  id: 'markdown-export',
  name: 'Markdown Export',
  extension: 'md',
  mimeType: 'text/markdown',

  async export(
    session: DashboardSessionSummary,
    events: TronSessionEvent[],
    options?: ExportOptions
  ): Promise<string> {
    return exportAsMarkdown(session, events, options);
  },
};
