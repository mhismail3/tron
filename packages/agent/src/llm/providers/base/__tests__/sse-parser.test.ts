/**
 * @fileoverview SSE Parser Tests
 */

import { describe, it, expect } from 'vitest';
import { parseSSELines, parseSSEData } from '../sse-parser.js';

/**
 * Helper to create a mock ReadableStreamDefaultReader from chunks
 */
function createMockReader(chunks: string[]): ReadableStreamDefaultReader<Uint8Array> {
  const encoder = new TextEncoder();
  let index = 0;

  return {
    read: async () => {
      if (index >= chunks.length) {
        return { done: true, value: undefined };
      }
      const value = encoder.encode(chunks[index++]);
      return { done: false, value };
    },
    releaseLock: () => {},
    closed: Promise.resolve(undefined),
    cancel: async () => {},
  };
}

describe('parseSSELines', () => {
  it('parses single complete data line', async () => {
    const reader = createMockReader(['data: {"test": true}\n']);
    const results: string[] = [];

    for await (const data of parseSSELines(reader)) {
      results.push(data);
    }

    expect(results).toEqual(['{"test": true}']);
  });

  it('parses multiple data lines', async () => {
    const reader = createMockReader([
      'data: {"event": 1}\n',
      'data: {"event": 2}\n',
      'data: {"event": 3}\n',
    ]);
    const results: string[] = [];

    for await (const data of parseSSELines(reader)) {
      results.push(data);
    }

    expect(results).toEqual(['{"event": 1}', '{"event": 2}', '{"event": 3}']);
  });

  it('handles chunked data across multiple reads', async () => {
    // Data split across chunks
    const reader = createMockReader([
      'data: {"par',
      'tial": true}\ndata: {"complete": true}\n',
    ]);
    const results: string[] = [];

    for await (const data of parseSSELines(reader)) {
      results.push(data);
    }

    expect(results).toEqual(['{"partial": true}', '{"complete": true}']);
  });

  it('filters out [DONE] markers', async () => {
    const reader = createMockReader([
      'data: {"event": 1}\n',
      'data: [DONE]\n',
    ]);
    const results: string[] = [];

    for await (const data of parseSSELines(reader)) {
      results.push(data);
    }

    expect(results).toEqual(['{"event": 1}']);
  });

  it('filters out empty data lines', async () => {
    const reader = createMockReader([
      'data: {"event": 1}\n',
      'data: \n',
      'data:   \n',
      'data: {"event": 2}\n',
    ]);
    const results: string[] = [];

    for await (const data of parseSSELines(reader)) {
      results.push(data);
    }

    expect(results).toEqual(['{"event": 1}', '{"event": 2}']);
  });

  it('ignores non-data lines', async () => {
    const reader = createMockReader([
      'event: message\n',
      'data: {"event": 1}\n',
      'id: 123\n',
      'retry: 5000\n',
      'data: {"event": 2}\n',
    ]);
    const results: string[] = [];

    for await (const data of parseSSELines(reader)) {
      results.push(data);
    }

    expect(results).toEqual(['{"event": 1}', '{"event": 2}']);
  });

  it('processes remaining buffer when processRemainingBuffer is true (default)', async () => {
    // Line without trailing newline in final chunk
    const reader = createMockReader(['data: {"complete": true}\ndata: {"no_newline": true}']);
    const results: string[] = [];

    for await (const data of parseSSELines(reader, { processRemainingBuffer: true })) {
      results.push(data);
    }

    expect(results).toEqual(['{"complete": true}', '{"no_newline": true}']);
  });

  it('does not process remaining buffer when processRemainingBuffer is false', async () => {
    // Line without trailing newline in final chunk
    const reader = createMockReader(['data: {"complete": true}\ndata: {"no_newline": true}']);
    const results: string[] = [];

    for await (const data of parseSSELines(reader, { processRemainingBuffer: false })) {
      results.push(data);
    }

    expect(results).toEqual(['{"complete": true}']);
  });

  it('handles empty stream', async () => {
    const reader = createMockReader([]);
    const results: string[] = [];

    for await (const data of parseSSELines(reader)) {
      results.push(data);
    }

    expect(results).toEqual([]);
  });
});

describe('parseSSEData', () => {
  it('parses valid JSON', () => {
    const result = parseSSEData<{ test: boolean }>('{"test": true}', 'test');
    expect(result).toEqual({ test: true });
  });

  it('returns null for invalid JSON', () => {
    const result = parseSSEData('not json', 'test');
    expect(result).toBeNull();
  });

  it('returns null for empty string', () => {
    const result = parseSSEData('', 'test');
    expect(result).toBeNull();
  });
});
