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
  model: string;
  workingDirectory: string;
}

export interface LedgerWriteResult {
  written: boolean;
  reason?: string;
  title?: string;
  entryType?: string;
  /** The event ID of the persisted ledger entry (only set when written=true) */
  eventId?: string;
  /** The full payload (only set when written=true) */
  payload?: Record<string, unknown>;
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

      // 2. Check if there's any meaningful content since the last ledger entry
      if (!this.hasMeaningfulContent(events)) {
        return { written: false, reason: 'no_new_content' };
      }

      const context = this.buildEventContext(events);

      // 3. Derive cycle range from persisted events (ground truth)
      const cycleRange = this.computeCycleRange(events);

      // 4. Spawn Haiku subagent
      const result = await this.deps.spawnSubsession({
        task: context,
        model: SUBAGENT_MODEL,
        systemPrompt: MEMORY_LEDGER_PROMPT,
        toolDenials: { denyAll: true },
        maxTurns: 1,
        blocking: true,
        timeout: 30_000,
      });

      // 5. Handle failure
      if (!result.success) {
        logger.warn('Ledger subagent failed', { error: result.error });
        return { written: false, reason: result.error ?? 'subagent failed' };
      }

      // 6. Handle empty output
      if (!result.output) {
        return { written: false, reason: 'empty output from subagent' };
      }

      // 7. Parse response
      let parsed: Record<string, unknown>;
      try {
        // Extract JSON from markdown code fences (ignoring any trailing content like emoji)
        const fenceMatch = result.output.match(/```(?:json)?\n([\s\S]*?)\n```/);
        const jsonStr = fenceMatch ? fenceMatch[1]! : result.output.trim();
        parsed = JSON.parse(jsonStr);
      } catch {
        logger.warn('Failed to parse ledger subagent output', {
          output: result.output.slice(0, 200),
        });
        return { written: false, reason: 'Failed to parse subagent response as JSON' };
      }

      // 8. Check if Haiku decided to skip
      if (parsed.skip === true) {
        logger.debug('Ledger subagent decided to skip', { sessionId: this.deps.sessionId });
        return { written: false, reason: 'skipped' };
      }

      // 9. Build payload and persist
      const payload: MemoryLedgerPayload = {
        eventRange: { firstEventId: cycleRange.firstEventId, lastEventId: cycleRange.lastEventId },
        turnRange: { firstTurn: cycleRange.firstTurn, lastTurn: cycleRange.lastTurn },
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

      const event = await this.deps.appendEvent({
        type: 'memory.ledger',
        payload: payload as unknown as Record<string, unknown>,
      });

      logger.info('Ledger entry written', {
        sessionId: this.deps.sessionId,
        title: payload.title,
        entryType: payload.entryType,
        eventId: event.id,
      });

      return {
        written: true,
        title: payload.title,
        entryType: payload.entryType,
        eventId: event.id,
        payload: payload as unknown as Record<string, unknown>,
      };
    } catch (error) {
      const err = error as Error;
      logger.error('Ledger write failed', { error: err.message });
      return { written: false, reason: err.message };
    }
  }

  // ===========================================================================
  // Private Helpers
  // ===========================================================================

  /**
   * Compute event and turn ranges for the current cycle from persisted events.
   *
   * The cycle boundary is the last `memory.ledger` event — it marks where the
   * previous cycle's summary was written. Everything after it belongs to the
   * current cycle. We don't use `compact.boundary` because compaction runs in
   * the same Stop hook as ledger writing, so its events appear interleaved
   * with the current cycle's events.
   *
   * By the time this runs (background Stop hook), all cycle events are already
   * persisted to SQLite.
   */
  private static readonly MEANINGFUL_EVENT_TYPES = new Set([
    'message.user', 'message.assistant', 'tool.call', 'tool.result',
    'file.write', 'file.edit', 'worktree.commit',
  ]);

  private hasMeaningfulContent(events: SessionEvent[]): boolean {
    // Find the most recent memory.ledger event
    let boundaryIndex = -1;
    for (let i = events.length - 1; i >= 0; i--) {
      if (events[i]!.type === 'memory.ledger') {
        boundaryIndex = i;
        break;
      }
    }

    // Check events after the boundary for anything meaningful
    for (let i = boundaryIndex + 1; i < events.length; i++) {
      if (LedgerWriter.MEANINGFUL_EVENT_TYPES.has(events[i]!.type)) {
        return true;
      }
    }
    return false;
  }

  private computeCycleRange(events: SessionEvent[]): {
    firstEventId: string; lastEventId: string;
    firstTurn: number; lastTurn: number;
  } {
    // Find the most recent memory.ledger event (previous cycle's summary)
    let boundaryIndex = -1;
    for (let i = events.length - 1; i >= 0; i--) {
      const evt = events[i]!;
      if (evt.type === 'memory.ledger') {
        boundaryIndex = i;
        break;
      }
    }

    // Current cycle = events after the boundary
    const cycleEvents = events.slice(boundaryIndex + 1);
    const first = cycleEvents[0];
    const last = cycleEvents[cycleEvents.length - 1];

    if (!first || !last) {
      return { firstEventId: 'unknown', lastEventId: 'unknown', firstTurn: 0, lastTurn: 0 };
    }

    // Extract turn numbers from stream.turn_start events
    let firstTurn = 0;
    let lastTurn = 0;
    for (const event of cycleEvents) {
      if (event.type === 'stream.turn_start') {
        const turn = event.payload.turn ?? 0;
        if (firstTurn === 0) firstTurn = turn;
        lastTurn = turn;
      }
    }

    return {
      firstEventId: first.id,
      lastEventId: last.id,
      firstTurn,
      lastTurn,
    };
  }

  private buildEventContext(events: SessionEvent[]): string {
    const parts: string[] = ['Analyze these session events and create a ledger entry:\n'];

    // Only include events after the last memory.ledger boundary (current cycle)
    let boundaryIndex = -1;
    for (let i = events.length - 1; i >= 0; i--) {
      if (events[i]!.type === 'memory.ledger') {
        boundaryIndex = i;
        break;
      }
    }
    const cycleEvents = events.slice(boundaryIndex + 1);

    for (const event of cycleEvents) {
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
