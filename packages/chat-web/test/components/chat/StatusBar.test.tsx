/**
 * @fileoverview Tests for StatusBar component
 */
import { describe, it, expect } from 'vitest';
import { render, screen } from '@testing-library/react';
import { StatusBar } from '../../../src/components/chat/StatusBar.js';

describe('StatusBar', () => {
  it('should render model name', () => {
    render(<StatusBar model="claude-opus-4" />);
    expect(screen.getByText('claude-opus-4')).toBeInTheDocument();
  });

  it('should use default model when not specified', () => {
    render(<StatusBar />);
    expect(screen.getByText('claude-sonnet-4-20250514')).toBeInTheDocument();
  });

  it('should display token counts', () => {
    render(<StatusBar inputTokens={1500} outputTokens={2500} />);
    expect(screen.getByText('1.5K')).toBeInTheDocument();
    expect(screen.getByText('2.5K')).toBeInTheDocument();
  });

  it('should format large token counts with M suffix', () => {
    render(<StatusBar inputTokens={1500000} outputTokens={2500000} />);
    expect(screen.getByText('1.5M')).toBeInTheDocument();
    expect(screen.getByText('2.5M')).toBeInTheDocument();
  });

  it('should display small token counts without suffix', () => {
    render(<StatusBar inputTokens={500} outputTokens={800} />);
    expect(screen.getByText('500')).toBeInTheDocument();
    expect(screen.getByText('800')).toBeInTheDocument();
  });

  it('should display cost when provided', () => {
    render(<StatusBar cost={0.0123} />);
    expect(screen.getByText('$0.0123')).toBeInTheDocument();
  });

  it('should not display cost when zero', () => {
    render(<StatusBar cost={0} />);
    expect(screen.queryByText(/\$/)).not.toBeInTheDocument();
  });

  it('should display context percentage', () => {
    render(<StatusBar contextPercent={45} />);
    expect(screen.getByText('45%')).toBeInTheDocument();
  });

  it('should show progress bar', () => {
    const { container } = render(<StatusBar contextPercent={60} />);
    const progressBar = container.querySelector('div[style*="width: 60%"]');
    expect(progressBar).toBeInTheDocument();
  });
});
