/**
 * @fileoverview TokenEstimator Unit Tests (TDD)
 *
 * Tests for the TokenEstimator utility functions.
 * Token estimation uses chars/4 approximation (consistent with Anthropic's tokenizer).
 */
import { describe, it, expect } from 'vitest';
import {
  estimateMessageTokens,
  estimateMessagesTokens,
  estimateBlockTokens,
  estimateImageTokens,
  estimateSystemTokens,
  estimateRulesTokens,
  CHARS_PER_TOKEN,
} from '../token-estimator.js';
import type { Message, Tool } from '../../types/index.js';

// =============================================================================
// Constants
// =============================================================================

describe('CHARS_PER_TOKEN', () => {
  it('is 4 (standard approximation)', () => {
    expect(CHARS_PER_TOKEN).toBe(4);
  });
});

// =============================================================================
// estimateBlockTokens
// =============================================================================

describe('estimateBlockTokens', () => {
  describe('text blocks', () => {
    it('estimates tokens for text block', () => {
      const block = { type: 'text', text: 'Hello world!' }; // 12 chars
      const tokens = estimateBlockTokens(block);
      expect(tokens).toBe(Math.ceil(12 / 4)); // 3 tokens
    });

    it('handles empty text block', () => {
      const block = { type: 'text', text: '' };
      expect(estimateBlockTokens(block)).toBe(0);
    });

    it('handles long text block', () => {
      const text = 'a'.repeat(1000);
      const block = { type: 'text', text };
      expect(estimateBlockTokens(block)).toBe(250); // 1000/4
    });
  });

  describe('thinking blocks', () => {
    it('estimates tokens for thinking block', () => {
      const block = { type: 'thinking', thinking: 'Let me think about this...' }; // 26 chars
      const tokens = estimateBlockTokens(block);
      expect(tokens).toBe(Math.ceil(26 / 4)); // 7 tokens
    });

    it('handles empty thinking block', () => {
      const block = { type: 'thinking', thinking: '' };
      expect(estimateBlockTokens(block)).toBe(0);
    });
  });

  describe('tool_use blocks', () => {
    it('estimates tokens for tool_use block', () => {
      const block = {
        type: 'tool_use',
        id: 'tool_123',
        name: 'Read',
        input: { file_path: '/test/file.ts' },
      };
      // id (8) + name (4) + JSON input length
      const inputStr = JSON.stringify(block.input);
      const expectedChars = 8 + 4 + inputStr.length;
      expect(estimateBlockTokens(block)).toBe(Math.ceil(expectedChars / 4));
    });

    it('handles tool_use with arguments instead of input', () => {
      const block = {
        type: 'tool_use',
        id: 'tool_456',
        name: 'Write',
        arguments: { file_path: '/test/output.ts', content: 'test' },
      };
      const argsStr = JSON.stringify(block.arguments);
      const expectedChars = 8 + 5 + argsStr.length;
      expect(estimateBlockTokens(block)).toBe(Math.ceil(expectedChars / 4));
    });

    it('handles tool_use with no input/arguments', () => {
      const block = {
        type: 'tool_use',
        id: 'tool_789',
        name: 'ListFiles',
      };
      // id (8) + name (9) + empty object "{}" (2)
      expect(estimateBlockTokens(block)).toBe(Math.ceil(19 / 4));
    });
  });

  describe('tool_result blocks', () => {
    it('estimates tokens for tool_result with string content', () => {
      const block = {
        type: 'tool_result',
        tool_use_id: 'tool_123',
        content: 'File contents here',
      };
      // tool_use_id (8) + content (18)
      expect(estimateBlockTokens(block)).toBe(Math.ceil(26 / 4));
    });

    it('handles tool_result with missing content', () => {
      const block = {
        type: 'tool_result',
        tool_use_id: 'tool_123',
      };
      expect(estimateBlockTokens(block)).toBe(Math.ceil(8 / 4)); // just the ID
    });
  });

  describe('image blocks', () => {
    it('estimates tokens for base64 image', () => {
      // Create a mock base64 string (small for testing)
      const base64Data = 'a'.repeat(1000); // 1000 chars of base64
      const block = {
        type: 'image',
        source: {
          type: 'base64',
          data: base64Data,
        },
      };
      const tokens = estimateBlockTokens(block);
      // base64 to bytes: 1000 * 0.75 = 750 bytes
      // estimated pixels: 750 * 5 = 3750
      // tokens: max(85, ceil(3750 / 750)) = max(85, 5) = 85
      expect(tokens).toBe(85); // minimum 85 tokens
    });

    it('estimates tokens for large base64 image', () => {
      const base64Data = 'a'.repeat(100000); // large image
      const block = {
        type: 'image',
        source: {
          type: 'base64',
          data: base64Data,
        },
      };
      const tokens = estimateBlockTokens(block);
      // base64 to bytes: 100000 * 0.75 = 75000 bytes
      // estimated pixels: 75000 * 5 = 375000
      // tokens: max(85, ceil(375000 / 750)) = 500
      expect(tokens).toBe(500);
    });

    it('estimates tokens for URL image (conservative default)', () => {
      const block = {
        type: 'image',
        source: {
          type: 'url',
          url: 'https://example.com/image.png',
        },
      };
      const tokens = estimateBlockTokens(block);
      // Default for URL: ~1500 tokens (typical 1024x1024 image)
      expect(tokens).toBe(1500);
    });

    it('handles image with missing source', () => {
      const block = { type: 'image' };
      expect(estimateBlockTokens(block)).toBe(1500); // default
    });
  });

  describe('edge cases', () => {
    it('returns 0 for null', () => {
      expect(estimateBlockTokens(null)).toBe(0);
    });

    it('returns 0 for undefined', () => {
      expect(estimateBlockTokens(undefined)).toBe(0);
    });

    it('returns 0 for non-object', () => {
      expect(estimateBlockTokens('string')).toBe(0);
      expect(estimateBlockTokens(123)).toBe(0);
    });

    it('falls back to JSON serialization for unknown type', () => {
      const block = { type: 'custom', data: 'value' };
      const jsonStr = JSON.stringify(block);
      expect(estimateBlockTokens(block)).toBe(Math.ceil(jsonStr.length / 4));
    });
  });
});

// =============================================================================
// estimateImageTokens
// =============================================================================

describe('estimateImageTokens', () => {
  it('estimates tokens for base64 source', () => {
    const source = { type: 'base64' as const, data: 'a'.repeat(10000) };
    const tokens = estimateImageTokens(source);
    // 10000 * 0.75 = 7500 bytes, * 5 = 37500 pixels, / 750 = 50 tokens
    // But minimum is 85
    expect(tokens).toBe(85);
  });

  it('returns default for URL source', () => {
    const source = { type: 'url' as const, url: 'https://example.com/img.png' };
    expect(estimateImageTokens(source)).toBe(1500);
  });

  it('returns default for unknown source type', () => {
    const source = { type: 'unknown' as const } as any;
    expect(estimateImageTokens(source)).toBe(1500);
  });
});

// =============================================================================
// estimateMessageTokens
// =============================================================================

describe('estimateMessageTokens', () => {
  describe('user messages', () => {
    it('estimates tokens for string content', () => {
      const message: Message = {
        role: 'user',
        content: 'Hello, how are you?', // 19 chars
      };
      // role (4) + overhead (10) + content (19) = 33 chars
      const tokens = estimateMessageTokens(message);
      expect(tokens).toBe(Math.ceil(33 / 4)); // 9 tokens
    });

    it('estimates tokens for array content with text', () => {
      const message: Message = {
        role: 'user',
        content: [
          { type: 'text', text: 'Look at this image:' },
        ],
      };
      // role (4) + overhead (10) + text (19)
      expect(estimateMessageTokens(message)).toBe(Math.ceil(33 / 4));
    });

    it('estimates tokens for array content with image', () => {
      const message: Message = {
        role: 'user',
        content: [
          { type: 'text', text: 'What is this?' },
          { type: 'image', data: 'a'.repeat(10000), mimeType: 'image/png' },
        ],
      };
      // role (4) + overhead (10) + text (13) + image (1500 * 4 = 6000 chars)
      const tokens = estimateMessageTokens(message);
      expect(tokens).toBeGreaterThan(1500); // at least image tokens
    });
  });

  describe('assistant messages', () => {
    it('estimates tokens for text response', () => {
      const message: Message = {
        role: 'assistant',
        content: [{ type: 'text', text: 'I can help you with that.' }],
      };
      // role (9) + overhead (10) + text (26)
      expect(estimateMessageTokens(message)).toBe(Math.ceil(45 / 4));
    });

    it('estimates tokens for response with tool_use', () => {
      const message: Message = {
        role: 'assistant',
        content: [
          { type: 'text', text: 'Let me read that file.' },
          {
            type: 'tool_use',
            id: 'tool_abc',
            name: 'Read',
            arguments: { file_path: '/test.ts' },
          },
        ],
      };
      const tokens = estimateMessageTokens(message);
      expect(tokens).toBeGreaterThan(10); // reasonable estimate
    });
  });

  describe('toolResult messages', () => {
    it('estimates tokens for tool result', () => {
      const message: Message = {
        role: 'toolResult',
        toolCallId: 'tool_abc',
        content: 'File contents: const x = 1;',
      };
      // role (10) + overhead (10) + toolCallId (8) + content (27)
      expect(estimateMessageTokens(message)).toBe(Math.ceil(55 / 4));
    });

    it('estimates tokens for tool result with array content', () => {
      const message: Message = {
        role: 'toolResult',
        toolCallId: 'tool_def',
        content: [{ type: 'text', text: 'Result text' }],
      };
      // role (10) + overhead (10) + toolCallId (8) + text (11)
      expect(estimateMessageTokens(message)).toBe(Math.ceil(39 / 4));
    });

    it('handles tool result with isError flag', () => {
      const message: Message = {
        role: 'toolResult',
        toolCallId: 'tool_err',
        content: 'Error: file not found',
        isError: true,
      };
      const tokens = estimateMessageTokens(message);
      expect(tokens).toBeGreaterThan(0);
    });
  });

  describe('edge cases', () => {
    it('handles message with missing role', () => {
      const message = { content: 'test' } as Message;
      expect(estimateMessageTokens(message)).toBeGreaterThan(0);
    });

    it('handles message with empty content', () => {
      const message: Message = { role: 'user', content: '' };
      // role (4) + overhead (10) = 14 chars
      expect(estimateMessageTokens(message)).toBe(Math.ceil(14 / 4));
    });
  });
});

// =============================================================================
// estimateMessagesTokens
// =============================================================================

describe('estimateMessagesTokens', () => {
  it('returns 0 for empty array', () => {
    expect(estimateMessagesTokens([])).toBe(0);
  });

  it('sums tokens for multiple messages', () => {
    const messages: Message[] = [
      { role: 'user', content: 'Hello' },
      { role: 'assistant', content: [{ type: 'text', text: 'Hi there!' }] },
    ];
    const total = estimateMessagesTokens(messages);
    const individual = messages.reduce((sum, m) => sum + estimateMessageTokens(m), 0);
    expect(total).toBe(individual);
  });

  it('handles large message arrays', () => {
    const messages: Message[] = Array(100).fill(null).map((_, i) => ({
      role: i % 2 === 0 ? 'user' : 'assistant',
      content: `Message ${i}`,
    })) as Message[];
    const tokens = estimateMessagesTokens(messages);
    expect(tokens).toBeGreaterThan(0);
  });
});

// =============================================================================
// estimateSystemTokens
// =============================================================================

describe('estimateSystemTokens', () => {
  it('estimates tokens for system prompt only', () => {
    const prompt = 'You are a helpful assistant.'; // 28 chars
    const tools: Tool[] = [];
    expect(estimateSystemTokens(prompt, tools)).toBe(Math.ceil(28 / 4)); // 7 tokens
  });

  it('estimates tokens for system prompt with tools', () => {
    const prompt = 'You are helpful.';
    const tools: Tool[] = [
      {
        name: 'Read',
        description: 'Read a file',
        parameters: { type: 'object', properties: { path: { type: 'string' } } },
      },
    ];
    const tokens = estimateSystemTokens(prompt, tools);
    expect(tokens).toBeGreaterThan(Math.ceil(prompt.length / 4));
  });

  it('handles empty prompt', () => {
    expect(estimateSystemTokens('', [])).toBe(0);
  });

  it('handles multiple tools', () => {
    const prompt = 'System prompt';
    const tools: Tool[] = [
      { name: 'Read', description: 'Read file', parameters: { type: 'object' } },
      { name: 'Write', description: 'Write file', parameters: { type: 'object' } },
      { name: 'Edit', description: 'Edit file', parameters: { type: 'object' } },
    ];
    const tokens = estimateSystemTokens(prompt, tools);
    expect(tokens).toBeGreaterThan(Math.ceil(prompt.length / 4));
  });
});

// =============================================================================
// estimateRulesTokens
// =============================================================================

describe('estimateRulesTokens', () => {
  it('returns 0 for undefined', () => {
    expect(estimateRulesTokens(undefined)).toBe(0);
  });

  it('returns 0 for empty string', () => {
    expect(estimateRulesTokens('')).toBe(0);
  });

  it('estimates tokens including header overhead', () => {
    const rules = 'Follow these rules carefully.'; // 30 chars
    // Header "# Project Rules\n\n" = 18 chars
    // Total: 30 + 18 = 48 chars
    expect(estimateRulesTokens(rules)).toBe(Math.ceil(48 / 4)); // 12 tokens
  });

  it('handles long rules content', () => {
    const rules = 'Rule content '.repeat(100); // 1300 chars
    const tokens = estimateRulesTokens(rules);
    // 1300 + 18 header = 1318 chars / 4 = 330 tokens
    expect(tokens).toBe(Math.ceil(1318 / 4));
  });
});
