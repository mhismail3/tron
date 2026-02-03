/**
 * @fileoverview Transcript Export Module
 *
 * Provides functionality to export conversation transcripts to various formats.
 * This module orchestrates the export process; format-specific logic is in export-formats/.
 */
import type { Message, AssistantMessage, UserMessage, ToolResultMessage } from '@core/types/index.js';
import {
  toMarkdown,
  toHTML,
  toJSON,
  toPlainText,
} from './export-formats/formatters.js';
import type { ExportOptions, ExportMetadata, TranscriptEntry } from './export-formats/types.js';

// Re-export types for consumers
export type { ExportOptions, ExportMetadata, TranscriptEntry };

// Re-export formatters for direct use
export { toMarkdown, toHTML, toJSON, toPlainText };

// =============================================================================
// Export Functions
// =============================================================================

/**
 * Convert messages to normalized transcript entries
 */
export function messagesToTranscript(
  messages: Message[],
  options: ExportOptions = {}
): TranscriptEntry[] {
  const entries: TranscriptEntry[] = [];

  for (const msg of messages) {
    if (msg.role === 'user') {
      const userMsg = msg as UserMessage;
      const content = typeof userMsg.content === 'string'
        ? userMsg.content
        : userMsg.content
            .filter(c => c.type === 'text')
            .map(c => (c as { type: 'text'; text: string }).text)
            .join('\n');

      entries.push({
        role: 'user',
        content,
        timestamp: userMsg.timestamp ? new Date(userMsg.timestamp).toISOString() : undefined,
      });
    } else if (msg.role === 'assistant') {
      const assistantMsg = msg as AssistantMessage;
      let textContent = '';
      let thinkingContent = '';

      for (const block of assistantMsg.content) {
        if (block.type === 'text') {
          textContent += block.text;
        } else if (block.type === 'thinking' && options.includeThinking) {
          thinkingContent = block.thinking;
        } else if (block.type === 'tool_use' && options.includeToolCalls) {
          entries.push({
            role: 'tool',
            content: `Calling ${block.name}`,
            toolName: block.name,
            toolArgs: block.arguments as Record<string, unknown>,
          });
        }
      }

      if (textContent.trim()) {
        entries.push({
          role: 'assistant',
          content: textContent.trim(),
          thinking: thinkingContent || undefined,
        });
      }
    } else if (msg.role === 'toolResult' && options.includeToolCalls) {
      const toolMsg = msg as ToolResultMessage;
      const content = typeof toolMsg.content === 'string'
        ? toolMsg.content
        : toolMsg.content
            .filter(c => c.type === 'text')
            .map(c => (c as { type: 'text'; text: string }).text)
            .join('\n');

      entries.push({
        role: 'tool',
        content: toolMsg.isError ? `Error: ${content}` : content,
      });
    }
  }

  return entries;
}

/**
 * Main transcript exporter class
 */
export class TranscriptExporter {
  private messages: Message[];
  private metadata: ExportMetadata;
  private options: ExportOptions;

  constructor(
    messages: Message[],
    metadata: ExportMetadata = {},
    options: ExportOptions = {}
  ) {
    this.messages = messages;
    this.metadata = metadata;
    this.options = {
      includeToolCalls: true,
      includeThinking: false,
      includeMetadata: true,
      includeStats: true,
      ...options,
    };
  }

  /**
   * Export to Markdown
   */
  toMarkdown(): string {
    const transcript = messagesToTranscript(this.messages, this.options);
    return toMarkdown(transcript, this.metadata, this.options);
  }

  /**
   * Export to HTML
   */
  toHTML(): string {
    const transcript = messagesToTranscript(this.messages, this.options);
    return toHTML(transcript, this.metadata, this.options);
  }

  /**
   * Export to JSON
   */
  toJSON(): string {
    const transcript = messagesToTranscript(this.messages, this.options);
    return toJSON(transcript, this.metadata, this.options);
  }

  /**
   * Get plain text for clipboard
   */
  toPlainText(): string {
    const transcript = messagesToTranscript(this.messages, this.options);
    return toPlainText(transcript);
  }
}
