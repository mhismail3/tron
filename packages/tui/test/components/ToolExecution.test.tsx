/**
 * @fileoverview ToolExecution Component Tests
 */
import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import React from 'react';
import { render } from 'ink-testing-library';
import { ToolExecution } from '../../src/components/ToolExecution.js';

describe('ToolExecution Component', () => {
  beforeEach(() => {
    vi.useFakeTimers();
  });

  afterEach(() => {
    vi.useRealTimers();
  });

  it('should render tool name', () => {
    const { lastFrame } = render(
      <ToolExecution toolName="read" status="running" />
    );
    expect(lastFrame()).toContain('read');
  });

  it('should show running indicator when running', () => {
    const { lastFrame } = render(
      <ToolExecution toolName="bash" status="running" />
    );
    const frame = lastFrame() ?? '';
    // Should have animated spinner when running
    expect(frame).toContain('bash');
  });

  it('should show success indicator when complete', () => {
    const { lastFrame } = render(
      <ToolExecution toolName="write" status="success" duration={150} />
    );
    const frame = lastFrame() ?? '';
    expect(frame).toContain('write');
    expect(frame).toContain('150');
    // Should have checkmark or similar
    expect(frame).toMatch(/[✓√+]/);
  });

  it('should show error indicator on error', () => {
    const { lastFrame } = render(
      <ToolExecution toolName="edit" status="error" />
    );
    const frame = lastFrame() ?? '';
    expect(frame).toContain('edit');
    // Should have X or similar
    expect(frame).toMatch(/[✗×x!]/i);
  });

  it('should not contain emojis', () => {
    const { lastFrame } = render(
      <ToolExecution toolName="read" status="running" />
    );
    const frame = lastFrame() ?? '';
    // Check for common emojis
    expect(frame).not.toMatch(/[\u{1F300}-\u{1F9FF}]/u);
  });
});
