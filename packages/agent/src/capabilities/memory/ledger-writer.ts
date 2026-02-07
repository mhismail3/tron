/**
 * @fileoverview Memory Ledger Writer
 *
 * Spawns a Haiku subagent to create structured ledger entries
 * summarizing response cycles. Follows the same subsession pattern
 * as WebFetch (agent-factory.ts:265-304).
 */

import { createLogger } from '@infrastructure/logging/index.js';
import { MEMORY_LEDGER_PROMPT } from '@context/system-prompts/memory-ledger.js';
import { SUBAGENT_MODEL } from '@llm/providers/model-ids.js';
import type { MemoryLedgerPayload } from '@infrastructure/events/types/memory.js';
import type { SessionEvent, EventType } from '@infrastructure/events/types/index.js';

const logger = createLogger('memory:ledger-writer');

// =============================================================================
// Types
// =============================================================================

export interface SpawnSubsessionParams {
  task: string;
  model: string;
  systemPrompt: string;
  toolDenials: { denyAll: true };
  maxTurns: number;
  blocking: true;
  timeout: number;
}

export interface SpawnSubsessionResult {
  sessionId: string;
  success: boolean;
  output?: string;
  error?: string;
  tokenUsage?: { inputTokens: number; outputTokens: number };
}

export interface AppendEventParams {
  type: EventType;
  payload: Record<string, unknown>;
}

export interface LedgerWriterDeps {
  spawnSubsession: (params: SpawnSubsessionParams) => Promise<SpawnSubsessionResult>;
  appendEvent: (params: AppendEventParams) => Promise<{ id: string }>;
  getEventsBySession: () => Promise<SessionEvent[]>;
  sessionId: string;
  workspaceId: string;
}

export interface LedgerWriteOpts {
  firstEventId: string;
  lastEventId: string;
  firstTurn: number;
  lastTurn: number;
  model: string;
  workingDirectory: string;
}

export interface LedgerWriteResult {
  written: boolean;
  reason?: string;
  title?: string;
  entryType?: string;
}

// =============================================================================
// LedgerWriter
// =============================================================================

export class LedgerWriter {
  private deps: LedgerWriterDeps;

  constructor(deps: LedgerWriterDeps) {
    this.deps = deps;
  }

  async writeLedgerEntry(opts: LedgerWriteOpts): Promise<LedgerWriteResult> {
    try {
      // 1. Get session events to build context for Haiku
      const events = await this.deps.getEventsBySession();
      const context = this.buildEventContext(events);

      // 2. Spawn Haiku subagent
      const result = await this.deps.spawnSubsession({
        task: context,
        model: SUBAGENT_MODEL,
        systemPrompt: MEMORY_LEDGER_PROMPT,
        toolDenials: { denyAll: true },
        maxTurns: 1,
        blocking: true,
        timeout: 30_000,
      });

      // 3. Handle failure
      if (!result.success) {
        logger.warn('Ledger subagent failed', { error: result.error });
        return { written: false, reason: result.error ?? 'subagent failed' };
      }

      // 4. Handle empty output
      if (!result.output) {
        return { written: false, reason: 'empty output from subagent' };
      }

      // 5. Parse response
      let parsed: Record<string, unknown>;
      try {
        // Strip markdown code fences if present
        const cleaned = result.output.replace(/^```(?:json)?\n?/m, '').replace(/\n?```$/m, '').trim();
        parsed = JSON.parse(cleaned);
      } catch {
        logger.warn('Failed to parse ledger subagent output', {
          output: result.output.slice(0, 200),
        });
        return { written: false, reason: 'Failed to parse subagent response as JSON' };
      }

      // 6. Check if Haiku decided to skip
      if (parsed.skip === true) {
        logger.debug('Ledger subagent decided to skip', { sessionId: this.deps.sessionId });
        return { written: false, reason: 'skipped' };
      }

      // 7. Build payload and persist
      const payload: MemoryLedgerPayload = {
        eventRange: { firstEventId: opts.firstEventId, lastEventId: opts.lastEventId },
        turnRange: { firstTurn: opts.firstTurn, lastTurn: opts.lastTurn },
        title: String(parsed.title ?? 'Untitled'),
        entryType: this.validateEntryType(parsed.entryType),
        status: this.validateStatus(parsed.status),
        tags: Array.isArray(parsed.tags) ? parsed.tags.map(String) : [],
        input: String(parsed.input ?? ''),
        actions: Array.isArray(parsed.actions) ? parsed.actions.map(String) : [],
        files: this.parseFiles(parsed.files),
        decisions: this.parseDecisions(parsed.decisions),
        lessons: Array.isArray(parsed.lessons) ? parsed.lessons.map(String) : [],
        thinkingInsights: Array.isArray(parsed.thinkingInsights) ? parsed.thinkingInsights.map(String) : [],
        tokenCost: {
          input: result.tokenUsage?.inputTokens ?? 0,
          output: result.tokenUsage?.outputTokens ?? 0,
        },
        model: opts.model,
        workingDirectory: opts.workingDirectory,
      };

      await this.deps.appendEvent({
        type: 'memory.ledger',
        payload: payload as unknown as Record<string, unknown>,
      });

      logger.info('Ledger entry written', {
        sessionId: this.deps.sessionId,
        title: payload.title,
        entryType: payload.entryType,
      });

      return { written: true, title: payload.title, entryType: payload.entryType };
    } catch (error) {
      const err = error as Error;
      logger.error('Ledger write failed', { error: err.message });
      return { written: false, reason: err.message };
    }
  }

  // ===========================================================================
  // Private Helpers
  // ===========================================================================

  private buildEventContext(events: SessionEvent[]): string {
    const parts: string[] = ['Analyze these session events and create a ledger entry:\n'];

    for (const event of events) {
      const payload = (event as any).payload;
      switch (event.type) {
        case 'message.user':
          parts.push(`[USER] ${this.extractText(payload?.content)}`);
          break;
        case 'message.assistant': {
          const blocks = payload?.content;
          if (Array.isArray(blocks)) {
            for (const block of blocks) {
              if (block.type === 'thinking' && block.thinking) {
                parts.push(`[THINKING] ${String(block.thinking).slice(0, 500)}`);
              } else if (block.type === 'text' && block.text) {
                parts.push(`[ASSISTANT] ${String(block.text).slice(0, 300)}`);
              }
            }
          } else if (typeof blocks === 'string') {
            parts.push(`[ASSISTANT] ${blocks.slice(0, 300)}`);
          }
          break;
        }
        case 'tool.call':
          parts.push(`[TOOL_CALL] ${payload?.name ?? '?'}(${this.summarizeArgs(payload?.arguments)})`);
          break;
        case 'tool.result':
          parts.push(`[TOOL_RESULT] ${String(payload?.content ?? '').slice(0, 100)}`);
          break;
        case 'file.write':
        case 'file.edit':
          parts.push(`[FILE_OP] ${event.type}: ${payload?.path ?? '?'}`);
          break;
        case 'worktree.commit':
          parts.push(`[COMMIT] ${payload?.message ?? '?'}`);
          break;
      }
    }

    return parts.join('\n');
  }

  private extractText(content: unknown): string {
    if (typeof content === 'string') return content.slice(0, 300);
    if (Array.isArray(content)) {
      return content
        .filter((b: any) => b.type === 'text')
        .map((b: any) => String(b.text))
        .join(' ')
        .slice(0, 300);
    }
    return '';
  }

  private summarizeArgs(args: unknown): string {
    if (!args || typeof args !== 'object') return '';
    const obj = args as Record<string, unknown>;
    const keys = Object.keys(obj);
    if (keys.length === 0) return '';
    // Show file paths or first arg
    if (obj.file_path) return `file_path=${obj.file_path}`;
    if (obj.path) return `path=${obj.path}`;
    if (obj.command) return `command=${String(obj.command).slice(0, 80)}`;
    return keys.slice(0, 2).join(', ');
  }

  private validateEntryType(value: unknown): MemoryLedgerPayload['entryType'] {
    const valid = ['feature', 'bugfix', 'refactor', 'docs', 'config', 'research', 'conversation'];
    return valid.includes(String(value)) ? String(value) as MemoryLedgerPayload['entryType'] : 'conversation';
  }

  private validateStatus(value: unknown): MemoryLedgerPayload['status'] {
    const valid = ['completed', 'partial', 'in_progress'];
    return valid.includes(String(value)) ? String(value) as MemoryLedgerPayload['status'] : 'completed';
  }

  private parseFiles(files: unknown): MemoryLedgerPayload['files'] {
    if (!Array.isArray(files)) return [];
    return files
      .filter((f): f is Record<string, unknown> => typeof f === 'object' && f !== null)
      .map((f) => ({
        path: String(f.path ?? ''),
        op: (['C', 'M', 'D'].includes(String(f.op)) ? String(f.op) : 'M') as 'C' | 'M' | 'D',
        why: String(f.why ?? ''),
      }));
  }

  private parseDecisions(decisions: unknown): MemoryLedgerPayload['decisions'] {
    if (!Array.isArray(decisions)) return [];
    return decisions
      .filter((d): d is Record<string, unknown> => typeof d === 'object' && d !== null)
      .map((d) => ({
        choice: String(d.choice ?? ''),
        reason: String(d.reason ?? ''),
      }));
  }
}

// =============================================================================
// Factory
// =============================================================================

export function createLedgerWriter(deps: LedgerWriterDeps): LedgerWriter {
  return new LedgerWriter(deps);
}
