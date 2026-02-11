/**
 * @fileoverview Tests for Context Composition Utility
 *
 * Verifies that composeContextParts produces the correct ordered parts
 * with correct wrapping for each context field.
 */
import { describe, it, expect } from 'vitest';
import { composeContextParts } from '../context-composition.js';
import type { Context } from '@core/types/index.js';

function createContext(overrides: Partial<Context> = {}): Context {
  return {
    messages: [],
    ...overrides,
  };
}

describe('composeContextParts', () => {
  it('returns empty array for empty context', () => {
    const result = composeContextParts(createContext());
    expect(result).toEqual([]);
  });

  it('returns empty array when all fields are undefined', () => {
    const result = composeContextParts(createContext({
      systemPrompt: undefined,
      rulesContent: undefined,
      memoryContent: undefined,
      dynamicRulesContext: undefined,
      skillContext: undefined,
      subagentResultsContext: undefined,
      taskContext: undefined,
    }));
    expect(result).toEqual([]);
  });

  it('returns empty array when all fields are empty strings', () => {
    const result = composeContextParts(createContext({
      systemPrompt: '',
      rulesContent: '',
      memoryContent: '',
      dynamicRulesContext: '',
      skillContext: '',
      subagentResultsContext: '',
      taskContext: '',
    }));
    expect(result).toEqual([]);
  });

  // Individual field tests

  it('includes systemPrompt without wrapping', () => {
    const result = composeContextParts(createContext({
      systemPrompt: 'You are Tron.',
    }));
    expect(result).toEqual(['You are Tron.']);
  });

  it('wraps rulesContent with heading', () => {
    const result = composeContextParts(createContext({
      rulesContent: 'Always use TypeScript.',
    }));
    expect(result).toEqual(['# Project Rules\n\nAlways use TypeScript.']);
  });

  it('includes memoryContent without wrapping', () => {
    const result = composeContextParts(createContext({
      memoryContent: '# Workspace Memory\n\nLesson 1',
    }));
    expect(result).toEqual(['# Workspace Memory\n\nLesson 1']);
  });

  it('wraps dynamicRulesContext with heading', () => {
    const result = composeContextParts(createContext({
      dynamicRulesContext: 'Use snake_case for variables.',
    }));
    expect(result).toEqual(['# Active Rules\n\nUse snake_case for variables.']);
  });

  it('includes skillContext without wrapping', () => {
    const result = composeContextParts(createContext({
      skillContext: '<skill>sandbox</skill>',
    }));
    expect(result).toEqual(['<skill>sandbox</skill>']);
  });

  it('includes subagentResultsContext without wrapping', () => {
    const result = composeContextParts(createContext({
      subagentResultsContext: 'Sub-agent completed: test results all passing',
    }));
    expect(result).toEqual(['Sub-agent completed: test results all passing']);
  });

  it('wraps taskContext with XML tags', () => {
    const result = composeContextParts(createContext({
      taskContext: 'Active: 1 in progress, 2 pending',
    }));
    expect(result).toEqual(['<task-context>\nActive: 1 in progress, 2 pending\n</task-context>']);
  });

  // Ordering tests

  it('produces parts in canonical order when all fields present', () => {
    const result = composeContextParts(createContext({
      systemPrompt: 'system',
      rulesContent: 'rules',
      memoryContent: 'memory',
      dynamicRulesContext: 'dynamic',
      skillContext: 'skill',
      subagentResultsContext: 'subagent',
      taskContext: 'tasks',
    }));

    expect(result).toEqual([
      'system',
      '# Project Rules\n\nrules',
      'memory',
      '# Active Rules\n\ndynamic',
      'skill',
      'subagent',
      '<task-context>\ntasks\n</task-context>',
    ]);
  });

  it('maintains order when only some fields are present', () => {
    const result = composeContextParts(createContext({
      rulesContent: 'rules',
      taskContext: 'tasks',
    }));

    expect(result).toEqual([
      '# Project Rules\n\nrules',
      '<task-context>\ntasks\n</task-context>',
    ]);
  });

  it('skips undefined fields while preserving order', () => {
    const result = composeContextParts(createContext({
      systemPrompt: 'system',
      memoryContent: 'memory',
      skillContext: 'skill',
    }));

    expect(result).toEqual([
      'system',
      'memory',
      'skill',
    ]);
  });
});
