/**
 * @fileoverview Transcript Export Module
 *
 * Provides functionality to export conversation transcripts to various formats.
 */
import type { Message, AssistantMessage, UserMessage, ToolResultMessage } from '../types/index.js';

// =============================================================================
// Types
// =============================================================================

export interface ExportOptions {
  /** Include tool calls in export */
  includeToolCalls?: boolean;
  /** Include thinking blocks in export */
  includeThinking?: boolean;
  /** Include session metadata */
  includeMetadata?: boolean;
  /** Include token/cost information */
  includeStats?: boolean;
  /** Custom title for the export */
  title?: string;
}

export interface ExportMetadata {
  sessionId?: string;
  model?: string;
  startTime?: string;
  endTime?: string;
  totalTokens?: { input: number; output: number };
  cost?: number;
}

export interface TranscriptEntry {
  role: 'user' | 'assistant' | 'system' | 'tool';
  content: string;
  timestamp?: string;
  toolName?: string;
  toolArgs?: Record<string, unknown>;
  thinking?: string;
}

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
 * Export transcript to Markdown format
 */
export function toMarkdown(
  transcript: TranscriptEntry[],
  metadata?: ExportMetadata,
  options: ExportOptions = {}
): string {
  const lines: string[] = [];

  // Header
  lines.push(`# ${options.title ?? 'Conversation Transcript'}`);
  lines.push('');

  // Metadata
  if (options.includeMetadata && metadata) {
    lines.push('## Session Info');
    lines.push('');
    if (metadata.sessionId) lines.push(`- **Session ID**: \`${metadata.sessionId}\``);
    if (metadata.model) lines.push(`- **Model**: ${metadata.model}`);
    if (metadata.startTime) lines.push(`- **Start**: ${metadata.startTime}`);
    if (metadata.endTime) lines.push(`- **End**: ${metadata.endTime}`);
    if (options.includeStats && metadata.totalTokens) {
      lines.push(`- **Tokens**: ${metadata.totalTokens.input} input / ${metadata.totalTokens.output} output`);
    }
    if (options.includeStats && metadata.cost !== undefined) {
      lines.push(`- **Cost**: $${metadata.cost.toFixed(4)}`);
    }
    lines.push('');
    lines.push('---');
    lines.push('');
  }

  // Messages
  lines.push('## Conversation');
  lines.push('');

  for (const entry of transcript) {
    if (entry.role === 'user') {
      lines.push('### 👤 User');
      lines.push('');
      lines.push(entry.content);
      lines.push('');
    } else if (entry.role === 'assistant') {
      lines.push('### 🤖 Assistant');
      lines.push('');
      if (entry.thinking && options.includeThinking) {
        lines.push('<details>');
        lines.push('<summary>Thinking</summary>');
        lines.push('');
        lines.push(entry.thinking);
        lines.push('');
        lines.push('</details>');
        lines.push('');
      }
      lines.push(entry.content);
      lines.push('');
    } else if (entry.role === 'tool') {
      lines.push(`#### Tool: ${entry.toolName ?? 'Unknown'}`);
      lines.push('');
      if (entry.toolArgs) {
        lines.push('```json');
        lines.push(JSON.stringify(entry.toolArgs, null, 2));
        lines.push('```');
        lines.push('');
      }
      if (entry.content && entry.content !== `Calling ${entry.toolName}`) {
        lines.push('**Result:**');
        lines.push('');
        lines.push('```');
        lines.push(entry.content.slice(0, 500) + (entry.content.length > 500 ? '...' : ''));
        lines.push('```');
        lines.push('');
      }
    } else if (entry.role === 'system') {
      lines.push('### System');
      lines.push('');
      lines.push(`*${entry.content}*`);
      lines.push('');
    }
  }

  // Footer
  lines.push('---');
  lines.push('');
  lines.push(`*Exported from Tron on ${new Date().toISOString()}*`);

  return lines.join('\n');
}

/**
 * Export transcript to HTML format
 */
export function toHTML(
  transcript: TranscriptEntry[],
  metadata?: ExportMetadata,
  options: ExportOptions = {}
): string {
  const escape = (s: string) => s
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;');

  const lines: string[] = [];

  lines.push('<!DOCTYPE html>');
  lines.push('<html lang="en">');
  lines.push('<head>');
  lines.push('  <meta charset="UTF-8">');
  lines.push('  <meta name="viewport" content="width=device-width, initial-scale=1.0">');
  lines.push(`  <title>${escape(options.title ?? 'Conversation Transcript')}</title>`);
  lines.push('  <style>');
  lines.push(`
    * { box-sizing: border-box; }
    body {
      font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Oxygen, Ubuntu, sans-serif;
      max-width: 800px;
      margin: 0 auto;
      padding: 20px;
      background: #f8f9fa;
      color: #212529;
    }
    h1 { color: #495057; border-bottom: 2px solid #dee2e6; padding-bottom: 10px; }
    .meta { background: #e9ecef; padding: 15px; border-radius: 8px; margin-bottom: 20px; }
    .meta dt { font-weight: bold; color: #495057; }
    .meta dd { margin-left: 0; margin-bottom: 8px; }
    .message { margin: 20px 0; padding: 15px; border-radius: 8px; }
    .message.user { background: #e3f2fd; border-left: 4px solid #2196f3; }
    .message.assistant { background: #e8f5e9; border-left: 4px solid #4caf50; }
    .message.tool { background: #fff3e0; border-left: 4px solid #ff9800; font-size: 0.9em; }
    .message.system { background: #f5f5f5; border-left: 4px solid #9e9e9e; font-style: italic; }
    .role { font-weight: bold; margin-bottom: 8px; color: #495057; }
    .content { white-space: pre-wrap; line-height: 1.6; }
    pre { background: #263238; color: #aed581; padding: 10px; border-radius: 4px; overflow-x: auto; }
    code { background: #eceff1; padding: 2px 6px; border-radius: 3px; }
    details { margin: 10px 0; }
    summary { cursor: pointer; color: #6c757d; }
    .footer { text-align: center; color: #6c757d; margin-top: 30px; font-size: 0.85em; }
  `);
  lines.push('  </style>');
  lines.push('</head>');
  lines.push('<body>');
  lines.push(`  <h1>${escape(options.title ?? 'Conversation Transcript')}</h1>`);

  // Metadata
  if (options.includeMetadata && metadata) {
    lines.push('  <div class="meta">');
    lines.push('    <dl>');
    if (metadata.sessionId) {
      lines.push(`      <dt>Session ID</dt><dd><code>${escape(metadata.sessionId)}</code></dd>`);
    }
    if (metadata.model) {
      lines.push(`      <dt>Model</dt><dd>${escape(metadata.model)}</dd>`);
    }
    if (metadata.startTime) {
      lines.push(`      <dt>Start</dt><dd>${escape(metadata.startTime)}</dd>`);
    }
    if (options.includeStats && metadata.totalTokens) {
      lines.push(`      <dt>Tokens</dt><dd>${metadata.totalTokens.input} in / ${metadata.totalTokens.output} out</dd>`);
    }
    lines.push('    </dl>');
    lines.push('  </div>');
  }

  // Messages
  for (const entry of transcript) {
    const roleLabel = {
      user: 'User',
      assistant: 'Assistant',
      tool: `Tool${entry.toolName ? `: ${entry.toolName}` : ''}`,
      system: 'System',
    }[entry.role];

    lines.push(`  <div class="message ${entry.role}">`);
    lines.push(`    <div class="role">${roleLabel}</div>`);

    if (entry.thinking && options.includeThinking) {
      lines.push('    <details>');
      lines.push('      <summary>Thinking</summary>');
      lines.push(`      <div class="content">${escape(entry.thinking)}</div>`);
      lines.push('    </details>');
    }

    if (entry.toolArgs) {
      lines.push(`    <pre>${escape(JSON.stringify(entry.toolArgs, null, 2))}</pre>`);
    }

    lines.push(`    <div class="content">${escape(entry.content)}</div>`);
    lines.push('  </div>');
  }

  lines.push(`  <div class="footer">Exported from Tron on ${new Date().toISOString()}</div>`);
  lines.push('</body>');
  lines.push('</html>');

  return lines.join('\n');
}

/**
 * Export transcript to JSON format
 */
export function toJSON(
  transcript: TranscriptEntry[],
  metadata?: ExportMetadata,
  options: ExportOptions = {}
): string {
  return JSON.stringify({
    title: options.title ?? 'Conversation Transcript',
    exportedAt: new Date().toISOString(),
    metadata: options.includeMetadata ? metadata : undefined,
    messages: transcript,
  }, null, 2);
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
    const lines: string[] = [];

    for (const entry of transcript) {
      const prefix = {
        user: 'User: ',
        assistant: 'Assistant: ',
        tool: `[Tool: ${entry.toolName ?? 'unknown'}] `,
        system: 'System: ',
      }[entry.role];

      lines.push(prefix + entry.content);
      lines.push('');
    }

    return lines.join('\n');
  }
}
