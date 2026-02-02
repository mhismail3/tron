/**
 * @fileoverview Tests for tool call ID remapping utilities
 */
import { describe, expect, it } from 'vitest';
import {
  buildToolCallIdMapping,
  remapToolCallId,
  isAnthropicId,
  isOpenAIId,
  type IdFormat,
} from '../id-remapping.js';
import type { ToolCall } from '../../../types/index.js';

describe('isAnthropicId', () => {
  it('returns true for toolu_ prefixed IDs', () => {
    expect(isAnthropicId('toolu_01abc123')).toBe(true);
    expect(isAnthropicId('toolu_xyz')).toBe(true);
  });

  it('returns false for non-Anthropic IDs', () => {
    expect(isAnthropicId('call_abc123')).toBe(false);
    expect(isAnthropicId('abc123')).toBe(false);
    expect(isAnthropicId('')).toBe(false);
  });
});

describe('isOpenAIId', () => {
  it('returns true for call_ prefixed IDs', () => {
    expect(isOpenAIId('call_abc123')).toBe(true);
    expect(isOpenAIId('call_xyz')).toBe(true);
  });

  it('returns false for non-OpenAI IDs', () => {
    expect(isOpenAIId('toolu_01abc123')).toBe(false);
    expect(isOpenAIId('abc123')).toBe(false);
    expect(isOpenAIId('')).toBe(false);
  });
});

describe('buildToolCallIdMapping', () => {
  const createToolCall = (id: string, name: string = 'test'): ToolCall => ({
    type: 'tool_use',
    id,
    name,
    arguments: {},
  });

  describe('for Anthropic format', () => {
    it('remaps OpenAI-style IDs', () => {
      const toolCalls = [
        createToolCall('call_abc123'),
        createToolCall('call_def456'),
      ];
      const mapping = buildToolCallIdMapping(toolCalls, 'anthropic');

      expect(mapping.get('call_abc123')).toMatch(/^toolu_remap_\d+$/);
      expect(mapping.get('call_def456')).toMatch(/^toolu_remap_\d+$/);
    });

    it('does not remap IDs already in Anthropic format', () => {
      const toolCalls = [
        createToolCall('toolu_01abc123'),
        createToolCall('call_def456'),
      ];
      const mapping = buildToolCallIdMapping(toolCalls, 'anthropic');

      expect(mapping.has('toolu_01abc123')).toBe(false);
      expect(mapping.get('call_def456')).toMatch(/^toolu_remap_\d+$/);
    });

    it('returns empty map when all IDs are already in correct format', () => {
      const toolCalls = [
        createToolCall('toolu_01abc123'),
        createToolCall('toolu_02def456'),
      ];
      const mapping = buildToolCallIdMapping(toolCalls, 'anthropic');

      expect(mapping.size).toBe(0);
    });
  });

  describe('for OpenAI format', () => {
    it('remaps Anthropic-style IDs', () => {
      const toolCalls = [
        createToolCall('toolu_01abc123'),
        createToolCall('toolu_02def456'),
      ];
      const mapping = buildToolCallIdMapping(toolCalls, 'openai');

      expect(mapping.get('toolu_01abc123')).toMatch(/^call_remap_\d+$/);
      expect(mapping.get('toolu_02def456')).toMatch(/^call_remap_\d+$/);
    });

    it('does not remap IDs already in OpenAI format', () => {
      const toolCalls = [
        createToolCall('call_abc123'),
        createToolCall('toolu_01def456'),
      ];
      const mapping = buildToolCallIdMapping(toolCalls, 'openai');

      expect(mapping.has('call_abc123')).toBe(false);
      expect(mapping.get('toolu_01def456')).toMatch(/^call_remap_\d+$/);
    });
  });

  it('generates unique IDs for different tool calls', () => {
    const toolCalls = [
      createToolCall('toolu_01abc'),
      createToolCall('toolu_02def'),
      createToolCall('toolu_03ghi'),
    ];
    const mapping = buildToolCallIdMapping(toolCalls, 'openai');

    const remappedIds = Array.from(mapping.values());
    const uniqueIds = new Set(remappedIds);
    expect(uniqueIds.size).toBe(remappedIds.length);
  });
});

describe('remapToolCallId', () => {
  it('returns mapped ID when present in mapping', () => {
    const mapping = new Map<string, string>([
      ['toolu_01abc', 'call_remap_0'],
    ]);

    expect(remapToolCallId('toolu_01abc', mapping)).toBe('call_remap_0');
  });

  it('returns original ID when not in mapping', () => {
    const mapping = new Map<string, string>([
      ['toolu_01abc', 'call_remap_0'],
    ]);

    expect(remapToolCallId('call_xyz', mapping)).toBe('call_xyz');
  });

  it('works with empty mapping', () => {
    const mapping = new Map<string, string>();

    expect(remapToolCallId('toolu_01abc', mapping)).toBe('toolu_01abc');
  });
});
