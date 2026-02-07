/**
 * @fileoverview LLM-Based Summarizer
 *
 * Spawns a Haiku subagent to generate intelligent summaries for context
 * compaction. Falls back to KeywordSummarizer on any failure.
 *
 * Follows the same subsession pattern as WebFetch (agent-factory.ts)
 * and LedgerWriter (ledger-writer.ts).
 */

import type { Message } from '@core/types/index.js';
import { KeywordSummarizer, type Summarizer, type SummaryResult, type ExtractedData } from './summarizer.js';
import { COMPACTION_SUMMARIZER_PROMPT } from './system-prompts/compaction-summarizer.js';
import { createLogger } from '@infrastructure/logging/index.js';
import {
  SUMMARIZER_MAX_SERIALIZED_CHARS,
  SUMMARIZER_ASSISTANT_TEXT_LIMIT,
  SUMMARIZER_THINKING_TEXT_LIMIT,
  SUMMARIZER_TOOL_RESULT_TEXT_LIMIT,
  SUMMARIZER_SUBAGENT_TIMEOUT_MS,
} from './constants.js';
import { SUBAGENT_MODEL } from '@llm/providers/model-ids.js';

const logger = createLogger('context:llm-summarizer');

// =============================================================================
// Types
// =============================================================================

export interface LLMSummarizerDeps {
  spawnSubsession: (params: {
    task: string;
    model: string;
    systemPrompt: string;
    toolDenials: { denyAll: true };
    maxTurns: number;
    blocking: true;
    timeout: number;
  }) => Promise<{
    success: boolean;
    output?: string;
    error?: string;
  }>;
}

// =============================================================================
// LLMSummarizer
// =============================================================================

export class LLMSummarizer implements Summarizer {
  private deps: LLMSummarizerDeps;
  private fallback: KeywordSummarizer;

  constructor(deps: LLMSummarizerDeps) {
    this.deps = deps;
    this.fallback = new KeywordSummarizer();
  }

  async summarize(messages: Message[]): Promise<SummaryResult> {
    try {
      const serialized = serializeMessages(messages);

      const result = await this.deps.spawnSubsession({
        task: serialized,
        model: SUBAGENT_MODEL,
        systemPrompt: COMPACTION_SUMMARIZER_PROMPT,
        toolDenials: { denyAll: true },
        maxTurns: 1,
        blocking: true,
        timeout: SUMMARIZER_SUBAGENT_TIMEOUT_MS,
      });

      if (!result.success || !result.output) {
        logger.warn('LLM summarizer subagent failed, using fallback', {
          error: result.error,
          hasOutput: !!result.output,
        });
        return this.fallback.summarize(messages);
      }

      const parsed = parseResponse(result.output);
      if (!parsed) {
        logger.warn('LLM summarizer returned invalid JSON, using fallback', {
          outputLength: result.output.length,
          outputPreview: result.output.slice(0, 200),
        });
        return this.fallback.summarize(messages);
      }

      logger.info('LLM summarizer produced summary', {
        narrativeLength: parsed.narrative.length,
        hasExtractedData: !!parsed.extractedData,
        filesModified: parsed.extractedData?.filesModified?.length ?? 0,
        keyDecisions: parsed.extractedData?.keyDecisions?.length ?? 0,
      });

      return parsed;
    } catch (error) {
      logger.warn('LLM summarizer threw, using fallback', {
        error: (error as Error).message,
      });
      return this.fallback.summarize(messages);
    }
  }
}

// =============================================================================
// Message Serialization
// =============================================================================

/**
 * Serialize messages to a text transcript for the summarizer subagent.
 * Caps output at SUMMARIZER_MAX_SERIALIZED_CHARS — if exceeded, keeps first 25% + last 25%
 * with a middle omission marker.
 */
export function serializeMessages(messages: Message[]): string {
  const lines: string[] = [];

  for (const msg of messages) {
    if (msg.role === 'user') {
      const text = typeof msg.content === 'string'
        ? msg.content
        : msg.content
            .filter((b): b is { type: 'text'; text: string } => b.type === 'text' && 'text' in b)
            .map(b => b.text)
            .join('\n');
      lines.push(`[USER] ${text}`);
    } else if (msg.role === 'assistant') {
      for (const block of msg.content) {
        if (block.type === 'text') {
          const text = (block as { text: string }).text;
          lines.push(`[ASSISTANT] ${text.slice(0, SUMMARIZER_ASSISTANT_TEXT_LIMIT)}`);
        } else if (block.type === 'thinking') {
          const thinking = (block as { thinking?: string }).thinking ?? '';
          if (thinking) {
            lines.push(`[THINKING] ${thinking.slice(0, SUMMARIZER_THINKING_TEXT_LIMIT)}`);
          }
        } else if (block.type === 'tool_use') {
          const tc = block as { name: string; arguments: Record<string, unknown> };
          const keyArgs = extractKeyArgs(tc.arguments);
          lines.push(`[TOOL_CALL] ${tc.name}(${keyArgs})`);
        }
      }
    } else if (msg.role === 'toolResult') {
      const text = typeof msg.content === 'string'
        ? msg.content
        : msg.content
            .filter((b): b is { type: 'text'; text: string } => b.type === 'text' && 'text' in b)
            .map(b => b.text)
            .join('\n');
      const prefix = msg.isError ? '[TOOL_ERROR]' : '[TOOL_RESULT]';
      lines.push(`${prefix} ${text.slice(0, SUMMARIZER_TOOL_RESULT_TEXT_LIMIT)}`);
    }
  }

  const full = lines.join('\n');

  if (full.length <= SUMMARIZER_MAX_SERIALIZED_CHARS) {
    return full;
  }

  const quarter = Math.floor(SUMMARIZER_MAX_SERIALIZED_CHARS / 4);
  const head = full.slice(0, quarter);
  const tail = full.slice(-quarter);
  return `${head}\n\n[... ${full.length - quarter * 2} characters omitted ...]\n\n${tail}`;
}

/**
 * Extract key arguments from tool call arguments for compact display.
 */
function extractKeyArgs(args: Record<string, unknown>): string {
  const keys = ['file_path', 'path', 'command', 'pattern', 'url', 'query'];
  const parts: string[] = [];
  for (const key of keys) {
    if (key in args && typeof args[key] === 'string') {
      const val = args[key] as string;
      parts.push(`${key}: ${val.slice(0, 100)}`);
    }
  }
  return parts.join(', ');
}

// =============================================================================
// Response Parsing
// =============================================================================

/**
 * Parse the subagent's JSON response. Strips markdown fences if present.
 * Returns null on any parse failure.
 */
function parseResponse(raw: string): SummaryResult | null {
  let text = raw.trim();

  // Strip markdown code fences
  const fenceMatch = text.match(/^```(?:json)?\s*\n?([\s\S]*?)\n?\s*```$/);
  if (fenceMatch) {
    text = fenceMatch[1]!.trim();
  }

  let parsed: Record<string, unknown>;
  try {
    parsed = JSON.parse(text);
  } catch {
    return null;
  }

  if (typeof parsed.narrative !== 'string' || !parsed.narrative) {
    return null;
  }

  const extractedData = normalizeExtractedData(
    (parsed.extractedData as Record<string, unknown>) ?? {}
  );

  return {
    narrative: parsed.narrative,
    extractedData,
  };
}

/**
 * Normalize extracted data, defaulting missing fields to empty values.
 */
function normalizeExtractedData(raw: Record<string, unknown>): ExtractedData {
  return {
    currentGoal: typeof raw.currentGoal === 'string' ? raw.currentGoal : '',
    completedSteps: asStringArray(raw.completedSteps),
    pendingTasks: asStringArray(raw.pendingTasks),
    keyDecisions: asDecisionArray(raw.keyDecisions),
    filesModified: asStringArray(raw.filesModified),
    topicsDiscussed: asStringArray(raw.topicsDiscussed),
    userPreferences: asStringArray(raw.userPreferences),
    importantContext: asStringArray(raw.importantContext),
    thinkingInsights: asStringArray(raw.thinkingInsights),
  };
}

function asStringArray(val: unknown): string[] {
  if (!Array.isArray(val)) return [];
  return val.filter((v): v is string => typeof v === 'string');
}

function asDecisionArray(val: unknown): Array<{ decision: string; reason: string }> {
  if (!Array.isArray(val)) return [];
  return val.filter(
    (v): v is { decision: string; reason: string } =>
      typeof v === 'object' &&
      v !== null &&
      typeof (v as Record<string, unknown>).decision === 'string' &&
      typeof (v as Record<string, unknown>).reason === 'string'
  );
}
