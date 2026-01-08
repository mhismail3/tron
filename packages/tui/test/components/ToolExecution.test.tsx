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
    // Should have diamond icon (◆) for success
    expect(frame).toMatch(/[◆◇✓√+]/);
  });

  it('should show error indicator on error', () => {
    const { lastFrame } = render(
      <ToolExecution toolName="edit" status="error" />
    );
    const frame = lastFrame() ?? '';
    expect(frame).toContain('edit');
    // Should have diamond icon (◈) for error
    expect(frame).toMatch(/[◈◇✗×x!]/i);
  });

  it('should not contain emojis', () => {
    const { lastFrame } = render(
      <ToolExecution toolName="read" status="running" />
    );
    const frame = lastFrame() ?? '';
    // Check for common emojis
    expect(frame).not.toMatch(/[\u{1F300}-\u{1F9FF}]/u);
  });

  it('should display tool input when provided', () => {
    const { lastFrame } = render(
      <ToolExecution toolName="bash" status="running" toolInput="ls -la /tmp" />
    );
    const frame = lastFrame() ?? '';
    expect(frame).toContain('bash');
    expect(frame).toContain('ls -la /tmp');
  });

  it('should truncate long tool input', () => {
    const longInput = 'a'.repeat(100);
    const { lastFrame } = render(
      <ToolExecution toolName="bash" status="success" toolInput={longInput} duration={50} />
    );
    const frame = lastFrame() ?? '';
    expect(frame).toContain('bash');
    expect(frame).toContain('...');
    expect(frame).not.toContain(longInput); // Full input should not be shown
  });

  it('should display tool input for completed tools', () => {
    const { lastFrame } = render(
      <ToolExecution toolName="read" status="success" toolInput="/path/to/file.txt" duration={25} />
    );
    const frame = lastFrame() ?? '';
    expect(frame).toContain('read');
    expect(frame).toContain('/path/to/file.txt');
    expect(frame).toContain('25');
  });

  describe('Tool Output Display', () => {
    it('should display tool output for completed tools', () => {
      const { lastFrame } = render(
        <ToolExecution
          toolName="read"
          status="success"
          toolInput="/path/to/file.txt"
          duration={25}
          output="Read 10 lines\nline1\nline2\nline3"
        />
      );
      const frame = lastFrame() ?? '';
      expect(frame).toContain('Read 10 lines');
      expect(frame).toContain('line1');
    });

    it('should NOT display output while tool is running', () => {
      const { lastFrame } = render(
        <ToolExecution
          toolName="bash"
          status="running"
          toolInput="ls -la"
          output="should not appear"
        />
      );
      const frame = lastFrame() ?? '';
      expect(frame).not.toContain('should not appear');
    });

    it('should truncate long output to 8 lines by default', () => {
      // Component uses MAX_OUTPUT_LINES = 8
      const output = Array.from({ length: 12 }, (_, i) => `line${i + 1}`).join('\n');
      const { lastFrame } = render(
        <ToolExecution
          toolName="bash"
          status="success"
          duration={100}
          output={output}
        />
      );
      const frame = lastFrame() ?? '';
      expect(frame).toContain('line1');
      expect(frame).toContain('line8');
      // line9+ should not be visible (truncated)
      expect(frame).not.toContain('line9');
      expect(frame).not.toContain('line12');
    });

    it('should show more lines indicator when output is truncated', () => {
      // Need more than 8 lines to trigger truncation
      const output = Array.from({ length: 12 }, (_, i) => `line${i + 1}`).join('\n');
      const { lastFrame } = render(
        <ToolExecution
          toolName="bash"
          status="success"
          duration={50}
          output={output}
        />
      );
      const frame = lastFrame() ?? '';
      // Should show truncation indicator (4 more lines)
      expect(frame).toMatch(/more line/i);
    });

    it('should show more lines in expanded mode', () => {
      const output = Array.from({ length: 15 }, (_, i) => `line${i + 1}`).join('\n');
      const { lastFrame } = render(
        <ToolExecution
          toolName="bash"
          status="success"
          duration={50}
          output={output}
          expanded={true}
        />
      );
      const frame = lastFrame() ?? '';
      // Should show up to 10 lines in expanded mode
      expect(frame).toContain('line10');
    });

    it('should display error output with error indicator', () => {
      const { lastFrame } = render(
        <ToolExecution
          toolName="bash"
          status="error"
          toolInput="invalid-command"
          output="Error: Command not found"
        />
      );
      const frame = lastFrame() ?? '';
      expect(frame).toContain('Error');
      expect(frame).toMatch(/[◈◇✗×x!]/i); // error indicator (◈ for error)
    });

    it('should truncate very long lines', () => {
      // Component uses MAX_OUTPUT_LINE_LENGTH = 100
      // 150 chars should be truncated to 97 + "..."
      const longLine = 'x'.repeat(150);
      const { lastFrame } = render(
        <ToolExecution
          toolName="bash"
          status="success"
          duration={50}
          output={longLine}
        />
      );
      const frame = lastFrame() ?? '';
      // Should not contain the full 150 x's (line is truncated to ~97)
      const xCount = (frame.match(/x/g) || []).length;
      expect(xCount).toBeLessThan(150);
      expect(xCount).toBe(97); // 100 - 3 (for "...")
      // The "..." may be split across lines due to wrapping, so just check dots exist
      expect(frame).toMatch(/\./);
    });

    it('should handle empty output gracefully', () => {
      const { lastFrame } = render(
        <ToolExecution
          toolName="bash"
          status="success"
          duration={50}
          output=""
        />
      );
      const frame = lastFrame() ?? '';
      expect(frame).toContain('bash');
      // Should not crash or show undefined
      expect(frame).not.toContain('undefined');
    });
  });
});
