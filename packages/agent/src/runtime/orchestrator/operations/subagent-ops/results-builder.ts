/**
 * @fileoverview Sub-Agent Results Builder
 *
 * Formats completed sub-agent results into context strings for injection
 * into parent agent conversations.
 */
import type { ActiveSession } from '../../types.js';

/**
 * Build context string for pending sub-agent results.
 * Consumes the pending results after formatting them.
 *
 * @param active - The active session to check for pending results
 * @returns Formatted context string or undefined if no pending results
 */
export function buildSubagentResultsContext(
  active: ActiveSession
): string | undefined {
  if (!active.subagentTracker.hasPendingResults()) {
    return undefined;
  }

  // Consume pending results
  const results = active.subagentTracker.consumePendingResults();

  if (results.length === 0) {
    return undefined;
  }

  // Format results into context
  let context = '# Completed Sub-Agent Results\n\n';
  context +=
    'The following sub-agent(s) have completed since your last turn. ';
  context +=
    'Review their results and incorporate them into your response as appropriate. ';
  context +=
    'To investigate further, use Remember with the session ID to query events and logs.\n\n';

  for (const result of results) {
    const statusIcon = result.success ? '✅' : '❌';
    context += `## ${statusIcon} Sub-Agent: \`${result.sessionId}\`\n\n`;
    context += `**Task**: ${result.task}\n`;
    context += `**Status**: ${result.success ? 'Completed successfully' : 'Failed'}\n`;
    context += `**Turns**: ${result.totalTurns}\n`;
    context += `**Duration**: ${(result.duration / 1000).toFixed(1)}s\n`;

    if (result.error) {
      context += `**Error**: ${result.error}\n`;
    }

    if (result.output) {
      // Truncate very long outputs
      const maxOutputLength = 2000;
      const truncatedOutput =
        result.output.length > maxOutputLength
          ? result.output.slice(0, maxOutputLength) +
            '\n\n... [Output truncated. Use QueryAgent for full output]'
          : result.output;
      context += `\n**Output**:\n\`\`\`\n${truncatedOutput}\n\`\`\`\n`;
    }

    context += '\n---\n\n';
  }

  return context;
}
