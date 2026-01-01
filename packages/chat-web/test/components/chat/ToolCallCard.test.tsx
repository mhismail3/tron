/**
 * @fileoverview Tests for ToolCallCard component
 */
import { describe, it, expect } from 'vitest';
import { render, screen, fireEvent } from '@testing-library/react';
import { ToolCallCard, type ToolCall } from '../../../src/components/chat/ToolCallCard.js';

describe('ToolCallCard', () => {
  const baseTool: ToolCall = {
    id: 'tool_1',
    name: 'bash',
    status: 'success',
    input: 'ls -la',
    output: 'file1.txt\nfile2.txt',
    duration: 150,
  };

  it('should render tool name', () => {
    render(<ToolCallCard tool={baseTool} />);
    expect(screen.getByText('bash')).toBeInTheDocument();
  });

  it('should show truncated input preview', () => {
    render(<ToolCallCard tool={baseTool} />);
    expect(screen.getByText('ls -la')).toBeInTheDocument();
  });

  it('should truncate long input', () => {
    const longInputTool: ToolCall = {
      ...baseTool,
      input: 'a'.repeat(100),
    };
    render(<ToolCallCard tool={longInputTool} />);
    // Should show truncated version with ellipsis
    expect(screen.getByText(/\.\.\.$/)).toBeInTheDocument();
  });

  it('should show duration badge for completed tools', () => {
    render(<ToolCallCard tool={baseTool} />);
    expect(screen.getByText('150ms')).toBeInTheDocument();
  });

  it('should show spinner for running tools', () => {
    const runningTool: ToolCall = {
      ...baseTool,
      status: 'running',
      duration: undefined,
    };
    const { container } = render(<ToolCallCard tool={runningTool} />);
    const spinner = container.querySelector('svg');
    expect(spinner).toBeInTheDocument();
  });

  it('should show error indicator for failed tools', () => {
    const errorTool: ToolCall = {
      ...baseTool,
      status: 'error',
    };
    render(<ToolCallCard tool={errorTool} />);
    expect(screen.getByText('!')).toBeInTheDocument();
  });

  it('should expand to show full input/output on click', () => {
    render(<ToolCallCard tool={baseTool} />);

    // Initially collapsed - output not visible
    expect(screen.queryByText('INPUT:')).not.toBeInTheDocument();

    // Click to expand
    const button = screen.getByRole('button');
    fireEvent.click(button);

    // Now should show input and output sections
    expect(screen.getByText('INPUT:')).toBeInTheDocument();
    expect(screen.getByText('OUTPUT:')).toBeInTheDocument();
    // Use regex to match multiline content
    expect(screen.getByText(/file1\.txt/)).toBeInTheDocument();
    expect(screen.getByText(/file2\.txt/)).toBeInTheDocument();
  });

  it('should collapse when clicked again', () => {
    render(<ToolCallCard tool={baseTool} />);

    const button = screen.getByRole('button');

    // Expand
    fireEvent.click(button);
    expect(screen.getByText('INPUT:')).toBeInTheDocument();

    // Collapse
    fireEvent.click(button);
    expect(screen.queryByText('INPUT:')).not.toBeInTheDocument();
  });

  describe('tool-specific colors', () => {
    it('should use green color for bash', () => {
      const { container } = render(<ToolCallCard tool={baseTool} />);
      const card = container.firstChild as HTMLElement;
      expect(card).toHaveStyle({ borderLeft: '3px solid #4ade80' });
    });

    it('should use blue color for read', () => {
      const readTool: ToolCall = { ...baseTool, name: 'read' };
      const { container } = render(<ToolCallCard tool={readTool} />);
      const card = container.firstChild as HTMLElement;
      expect(card).toHaveStyle({ borderLeft: '3px solid #60a5fa' });
    });

    it('should use yellow color for write', () => {
      const writeTool: ToolCall = { ...baseTool, name: 'write' };
      const { container } = render(<ToolCallCard tool={writeTool} />);
      const card = container.firstChild as HTMLElement;
      expect(card).toHaveStyle({ borderLeft: '3px solid #fbbf24' });
    });

    it('should use purple color for edit', () => {
      const editTool: ToolCall = { ...baseTool, name: 'edit' };
      const { container } = render(<ToolCallCard tool={editTool} />);
      const card = container.firstChild as HTMLElement;
      expect(card).toHaveStyle({ borderLeft: '3px solid #c084fc' });
    });
  });
});
