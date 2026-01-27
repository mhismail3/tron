/**
 * @fileoverview Tests for stop reason mapping utilities
 */
import { describe, expect, it } from 'vitest';
import {
  mapOpenAIStopReason,
  mapGoogleStopReason,
  type StopReason,
} from '../stop-reason.js';

describe('mapOpenAIStopReason', () => {
  it('maps "stop" to "end_turn"', () => {
    expect(mapOpenAIStopReason('stop')).toBe('end_turn');
  });

  it('maps "length" to "max_tokens"', () => {
    expect(mapOpenAIStopReason('length')).toBe('max_tokens');
  });

  it('maps "tool_calls" to "tool_use"', () => {
    expect(mapOpenAIStopReason('tool_calls')).toBe('tool_use');
  });

  it('maps "content_filter" to "end_turn"', () => {
    expect(mapOpenAIStopReason('content_filter')).toBe('end_turn');
  });

  it('maps null to "end_turn"', () => {
    expect(mapOpenAIStopReason(null)).toBe('end_turn');
  });

  it('maps unknown values to "end_turn"', () => {
    expect(mapOpenAIStopReason('unknown_reason')).toBe('end_turn');
    expect(mapOpenAIStopReason('')).toBe('end_turn');
  });
});

describe('mapGoogleStopReason', () => {
  it('maps "STOP" to "end_turn"', () => {
    expect(mapGoogleStopReason('STOP')).toBe('end_turn');
  });

  it('maps "MAX_TOKENS" to "max_tokens"', () => {
    expect(mapGoogleStopReason('MAX_TOKENS')).toBe('max_tokens');
  });

  it('maps "SAFETY" to "end_turn"', () => {
    expect(mapGoogleStopReason('SAFETY')).toBe('end_turn');
  });

  it('maps "RECITATION" to "end_turn"', () => {
    expect(mapGoogleStopReason('RECITATION')).toBe('end_turn');
  });

  it('maps "OTHER" to "end_turn"', () => {
    expect(mapGoogleStopReason('OTHER')).toBe('end_turn');
  });

  it('maps unknown values to "end_turn"', () => {
    expect(mapGoogleStopReason('UNKNOWN')).toBe('end_turn');
    expect(mapGoogleStopReason('')).toBe('end_turn');
  });
});
