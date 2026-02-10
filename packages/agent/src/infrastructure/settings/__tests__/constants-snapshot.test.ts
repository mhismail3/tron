/**
 * @fileoverview Constants Snapshot Tests
 *
 * Validates that all extracted constants maintain their original values.
 * Catches accidental changes during refactoring.
 */
import { describe, it, expect } from 'vitest';

// Context constants
import {
  SUMMARIZER_MAX_SERIALIZED_CHARS,
  SUMMARIZER_ASSISTANT_TEXT_LIMIT,
  SUMMARIZER_THINKING_TEXT_LIMIT,
  SUMMARIZER_TOOL_RESULT_TEXT_LIMIT,
  SUMMARIZER_SUBAGENT_TIMEOUT_MS,
  TOOL_RESULT_MIN_TOKENS,
  TOOL_RESULT_MAX_CHARS,
  MAX_SYSTEM_PROMPT_FILE_SIZE,
  CHARS_PER_TOKEN,
  MIN_IMAGE_TOKENS,
  DEFAULT_URL_IMAGE_TOKENS,
} from '@context/constants.js';

// Web tool constants
import {
  WEB_FETCH_DEFAULT_TIMEOUT_MS,
  WEB_FETCH_USER_AGENT,
  WEB_FETCH_MAX_RESPONSE_SIZE,
  WEB_FETCH_HAIKU_MODEL,
  WEB_FETCH_MAX_SUMMARIZER_TURNS,
  TRUNCATOR_MAX_TOKENS,
  TRUNCATOR_PRESERVE_START_LINES,
  HTML_MAX_CONTENT_LENGTH,
  URL_MAX_LENGTH,
  SUMMARIZER_MAX_TOKENS,
  SUMMARIZER_HAIKU_MODEL,
  SEARCH_MAX_QUERY_LENGTH,
  BRAVE_DEFAULT_TIMEOUT_MS,
} from '@capabilities/tools/web/constants.js';

// Extension constants
import {
  MAX_SKILL_FILE_SIZE,
  SKILL_MD_FILENAME,
  COMMAND_VERSION,
} from '@capabilities/extensions/constants.js';

// Runtime constants
import {
  SUBAGENT_MAX_TOKENS_MULTIPLIER,
  DEFAULT_GUARDRAIL_TIMEOUT_MS,
  TMUX_STARTUP_TIMEOUT_MS,
  MAX_TURNS_DEFAULT,
  COMPACTION_BUFFER_TOKENS,
  INACTIVE_SESSION_TIMEOUT_MS,
  EVENT_ID_LENGTH,
  DEFAULT_MAX_OUTPUT_TOKENS,
  SUBAGENT_EXCLUDED_TOOLS,
} from '@runtime/constants.js';

// Context compaction constants
import {
  COMPACTION_SUMMARY_PREFIX,
  COMPACTION_ACK_TEXT,
} from '@context/constants.js';

// Turn constants
import {
  BLOB_STORAGE_THRESHOLD,
  MAX_TOOL_RESULT_SIZE,
} from '@runtime/orchestrator/turn/constants.js';

// Model ID constants
import {
  CLAUDE_OPUS_4_6,
  CLAUDE_OPUS_4_5,
  CLAUDE_SONNET_4_5,
  CLAUDE_HAIKU_4_5,
  CLAUDE_OPUS_4_1,
  CLAUDE_OPUS_4,
  CLAUDE_SONNET_4,
  CLAUDE_3_7_SONNET,
  CLAUDE_3_HAIKU,
  GPT_5_3_CODEX,
  GPT_5_2_CODEX,
  GEMINI_3_PRO_PREVIEW,
  GEMINI_3_FLASH_PREVIEW,
  GEMINI_2_5_PRO,
  GEMINI_2_5_FLASH,
  GEMINI_2_5_FLASH_LITE,
  SUBAGENT_MODEL,
  DEFAULT_API_MODEL,
  DEFAULT_SERVER_MODEL,
  DEFAULT_GOOGLE_MODEL,
} from '@llm/providers/model-ids.js';

describe('constants snapshot', () => {
  describe('context constants', () => {
    it('LLM summarizer values', () => {
      expect(SUMMARIZER_MAX_SERIALIZED_CHARS).toBe(150_000);
      expect(SUMMARIZER_ASSISTANT_TEXT_LIMIT).toBe(300);
      expect(SUMMARIZER_THINKING_TEXT_LIMIT).toBe(500);
      expect(SUMMARIZER_TOOL_RESULT_TEXT_LIMIT).toBe(100);
      expect(SUMMARIZER_SUBAGENT_TIMEOUT_MS).toBe(30_000);
    });

    it('context manager values', () => {
      expect(TOOL_RESULT_MIN_TOKENS).toBe(2_500);
      expect(TOOL_RESULT_MAX_CHARS).toBe(100_000);
    });

    it('system prompt values', () => {
      expect(MAX_SYSTEM_PROMPT_FILE_SIZE).toBe(100 * 1024);
    });

    it('token estimator values', () => {
      expect(CHARS_PER_TOKEN).toBe(4);
      expect(MIN_IMAGE_TOKENS).toBe(85);
      expect(DEFAULT_URL_IMAGE_TOKENS).toBe(1500);
    });
  });

  describe('web tool constants', () => {
    it('web fetch values', () => {
      expect(WEB_FETCH_DEFAULT_TIMEOUT_MS).toBe(30_000);
      expect(WEB_FETCH_USER_AGENT).toBe('TronAgent/1.0 (+https://github.com/tron-agent)');
      expect(WEB_FETCH_MAX_RESPONSE_SIZE).toBe(10 * 1024 * 1024);
      expect(WEB_FETCH_HAIKU_MODEL).toBe(CLAUDE_HAIKU_4_5);
      expect(WEB_FETCH_MAX_SUMMARIZER_TURNS).toBe(3);
    });

    it('content truncator values', () => {
      expect(TRUNCATOR_MAX_TOKENS).toBe(50_000);
      expect(TRUNCATOR_PRESERVE_START_LINES).toBe(100);
    });

    it('HTML parser values', () => {
      expect(HTML_MAX_CONTENT_LENGTH).toBe(500_000);
    });

    it('URL validator values', () => {
      expect(URL_MAX_LENGTH).toBe(2_000);
    });

    it('summarizer values', () => {
      expect(SUMMARIZER_MAX_TOKENS).toBe(1024);
      expect(SUMMARIZER_HAIKU_MODEL).toBe(CLAUDE_HAIKU_4_5);
    });

    it('search values', () => {
      expect(SEARCH_MAX_QUERY_LENGTH).toBe(400);
      expect(BRAVE_DEFAULT_TIMEOUT_MS).toBe(15_000);
    });
  });

  describe('extension constants', () => {
    it('skill loader values', () => {
      expect(MAX_SKILL_FILE_SIZE).toBe(100 * 1024);
      expect(SKILL_MD_FILENAME).toBe('SKILL.md');
    });

    it('command router values', () => {
      expect(COMMAND_VERSION).toBe('0.1.0');
    });
  });

  describe('runtime constants', () => {
    it('agent factory values', () => {
      expect(SUBAGENT_MAX_TOKENS_MULTIPLIER).toBe(0.9);
    });

    it('spawn handler values', () => {
      expect(DEFAULT_GUARDRAIL_TIMEOUT_MS).toBe(60 * 60 * 1000);
      expect(TMUX_STARTUP_TIMEOUT_MS).toBe(10_000);
    });

    it('agent runtime values', () => {
      expect(MAX_TURNS_DEFAULT).toBe(100);
      expect(COMPACTION_BUFFER_TOKENS).toBe(4_000);
      expect(INACTIVE_SESSION_TIMEOUT_MS).toBe(30 * 60 * 1000);
      expect(EVENT_ID_LENGTH).toBe(12);
      expect(DEFAULT_MAX_OUTPUT_TOKENS).toBe(16_384);
    });

    it('subagent excluded tools', () => {
      expect(SUBAGENT_EXCLUDED_TOOLS).toEqual([
        'SpawnSubagent',
        'QueryAgent',
        'WaitForAgents',
      ]);
    });
  });

  describe('compaction constants', () => {
    it('compaction engine values', () => {
      expect(COMPACTION_SUMMARY_PREFIX).toBe('[Context from earlier in this conversation]');
      expect(COMPACTION_ACK_TEXT).toBe('I understand the previous context. Let me continue helping you.');
    });
  });

  describe('turn handler constants', () => {
    it('tool event handler values', () => {
      expect(BLOB_STORAGE_THRESHOLD).toBe(2 * 1024);
      expect(MAX_TOOL_RESULT_SIZE).toBe(10 * 1024);
    });
  });

  describe('model ID constants', () => {
    it('Anthropic model IDs match registry keys', () => {
      expect(CLAUDE_OPUS_4_6).toBe('claude-opus-4-6');
      expect(CLAUDE_OPUS_4_5).toBe('claude-opus-4-5-20251101');
      expect(CLAUDE_SONNET_4_5).toBe('claude-sonnet-4-5-20250929');
      expect(CLAUDE_HAIKU_4_5).toBe('claude-haiku-4-5-20251001');
      expect(CLAUDE_OPUS_4_1).toBe('claude-opus-4-1-20250805');
      expect(CLAUDE_OPUS_4).toBe('claude-opus-4-20250514');
      expect(CLAUDE_SONNET_4).toBe('claude-sonnet-4-20250514');
      expect(CLAUDE_3_7_SONNET).toBe('claude-3-7-sonnet-20250219');
      expect(CLAUDE_3_HAIKU).toBe('claude-3-haiku-20240307');
    });

    it('OpenAI model IDs match registry keys', () => {
      expect(GPT_5_3_CODEX).toBe('gpt-5.3-codex');
      expect(GPT_5_2_CODEX).toBe('gpt-5.2-codex');
    });

    it('Google model IDs match registry keys', () => {
      expect(GEMINI_3_PRO_PREVIEW).toBe('gemini-3-pro-preview');
      expect(GEMINI_3_FLASH_PREVIEW).toBe('gemini-3-flash-preview');
      expect(GEMINI_2_5_PRO).toBe('gemini-2.5-pro');
      expect(GEMINI_2_5_FLASH).toBe('gemini-2.5-flash');
      expect(GEMINI_2_5_FLASH_LITE).toBe('gemini-2.5-flash-lite');
    });

    it('role aliases point to expected models', () => {
      expect(SUBAGENT_MODEL).toBe(CLAUDE_HAIKU_4_5);
      expect(DEFAULT_API_MODEL).toBe(CLAUDE_OPUS_4_6);
      expect(DEFAULT_SERVER_MODEL).toBe(CLAUDE_SONNET_4);
      expect(DEFAULT_GOOGLE_MODEL).toBe(GEMINI_2_5_FLASH);
    });
  });
});
