/**
 * @fileoverview Tool Parsing Utility Tests
 */

import { describe, it, expect } from 'vitest';
import { parseToolCallArguments, isValidToolCallArguments } from '../tool-parsing.js';

describe('parseToolCallArguments', () => {
  it('parses valid JSON object', () => {
    const result = parseToolCallArguments('{"file": "test.ts", "line": 42}');
    expect(result).toEqual({ file: 'test.ts', line: 42 });
  });

  it('returns empty object for empty string', () => {
    const result = parseToolCallArguments('');
    expect(result).toEqual({});
  });

  it('returns empty object for null', () => {
    const result = parseToolCallArguments(null);
    expect(result).toEqual({});
  });

  it('returns empty object for undefined', () => {
    const result = parseToolCallArguments(undefined);
    expect(result).toEqual({});
  });

  it('returns empty object for whitespace-only string', () => {
    const result = parseToolCallArguments('   ');
    expect(result).toEqual({});
  });

  it('returns empty object for invalid JSON', () => {
    const result = parseToolCallArguments('not json at all');
    expect(result).toEqual({});
  });

  it('handles nested objects', () => {
    const result = parseToolCallArguments('{"outer": {"inner": "value"}}');
    expect(result).toEqual({ outer: { inner: 'value' } });
  });

  it('handles arrays in objects', () => {
    const result = parseToolCallArguments('{"items": [1, 2, 3]}');
    expect(result).toEqual({ items: [1, 2, 3] });
  });

  it('wraps non-object parsed values', () => {
    // Array parses to non-object
    const result = parseToolCallArguments('[1, 2, 3]');
    expect(result).toEqual({ value: [1, 2, 3] });
  });

  it('wraps primitive parsed values', () => {
    // String parses to primitive
    const result = parseToolCallArguments('"just a string"');
    expect(result).toEqual({ value: 'just a string' });
  });

  it('accepts optional context without affecting result', () => {
    const result = parseToolCallArguments('{"test": true}', {
      toolCallId: 'call_123',
      toolName: 'test_tool',
      provider: 'openai',
    });
    expect(result).toEqual({ test: true });
  });
});

describe('isValidToolCallArguments', () => {
  it('returns true for valid JSON object', () => {
    expect(isValidToolCallArguments('{"file": "test.ts"}')).toBe(true);
  });

  it('returns true for empty object', () => {
    expect(isValidToolCallArguments('{}')).toBe(true);
  });

  it('returns true for empty string (no args)', () => {
    expect(isValidToolCallArguments('')).toBe(true);
  });

  it('returns true for null (no args)', () => {
    expect(isValidToolCallArguments(null)).toBe(true);
  });

  it('returns true for undefined (no args)', () => {
    expect(isValidToolCallArguments(undefined)).toBe(true);
  });

  it('returns false for invalid JSON', () => {
    expect(isValidToolCallArguments('not json')).toBe(false);
  });

  it('returns false for JSON array', () => {
    expect(isValidToolCallArguments('[1, 2, 3]')).toBe(false);
  });

  it('returns false for JSON primitive', () => {
    expect(isValidToolCallArguments('"string"')).toBe(false);
    expect(isValidToolCallArguments('42')).toBe(false);
    expect(isValidToolCallArguments('true')).toBe(false);
    expect(isValidToolCallArguments('null')).toBe(false);
  });
});
