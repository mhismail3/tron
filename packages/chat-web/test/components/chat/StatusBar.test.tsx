/**
 * @fileoverview Tests for StatusBar component
 */
import { describe, it, expect } from 'vitest';
import { render, screen } from '@testing-library/react';
import { StatusBar } from '../../../src/components/chat/StatusBar.js';

describe('StatusBar', () => {
  it('should render model name', () => {
    render(<StatusBar model="claude-opus-4-5-20251101" />);
    // StatusBar formats model IDs to display names
    expect(screen.getByText('Claude Opus 4.5')).toBeInTheDocument();
  });

  it('should use default model when not specified', () => {
    render(<StatusBar />);
    // Default model is claude-sonnet-4-20250514, displayed as "Claude Sonnet 4"
    expect(screen.getByText('Claude Sonnet 4')).toBeInTheDocument();
  });

  it('should display token counts', () => {
    render(<StatusBar tokenUsage={{ input: 1500, output: 2500 }} />);
    expect(screen.getByText('1.5K')).toBeInTheDocument();
    expect(screen.getByText('2.5K')).toBeInTheDocument();
  });

  it('should format large token counts with M suffix', () => {
    render(<StatusBar tokenUsage={{ input: 1500000, output: 2500000 }} />);
    expect(screen.getByText('1.5M')).toBeInTheDocument();
    expect(screen.getByText('2.5M')).toBeInTheDocument();
  });

  it('should display small token counts without suffix', () => {
    render(<StatusBar tokenUsage={{ input: 500, output: 800 }} />);
    expect(screen.getByText('500')).toBeInTheDocument();
    expect(screen.getByText('800')).toBeInTheDocument();
  });

  it('should display context percentage', () => {
    render(<StatusBar contextPercent={45} />);
    expect(screen.getByText('45%')).toBeInTheDocument();
  });

  it('should show progress bar', () => {
    const { container } = render(<StatusBar contextPercent={60} />);
    const progressBar = container.querySelector('[style*="width: 60%"]');
    expect(progressBar).toBeInTheDocument();
  });
});
