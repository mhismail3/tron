/**
 * @fileoverview Tests for InputBar component
 */
import { describe, it, expect, vi } from 'vitest';
import { render, screen, fireEvent } from '@testing-library/react';
import { InputBar } from '../../../src/components/chat/InputBar.js';

describe('InputBar', () => {
  it('should render textarea with placeholder', () => {
    render(<InputBar onSubmit={() => {}} />);
    expect(screen.getByPlaceholderText('Type a message...')).toBeInTheDocument();
  });

  it('should accept custom placeholder', () => {
    render(<InputBar onSubmit={() => {}} placeholder="Custom placeholder" />);
    expect(screen.getByPlaceholderText('Custom placeholder')).toBeInTheDocument();
  });

  it('should call onSubmit with message when Enter is pressed', () => {
    const handleSubmit = vi.fn();
    render(<InputBar onSubmit={handleSubmit} />);

    const textarea = screen.getByRole('textbox');
    fireEvent.change(textarea, { target: { value: 'Hello world' } });
    fireEvent.keyDown(textarea, { key: 'Enter', shiftKey: false });

    expect(handleSubmit).toHaveBeenCalledWith('Hello world');
  });

  it('should not submit when Shift+Enter is pressed (for new lines)', () => {
    const handleSubmit = vi.fn();
    render(<InputBar onSubmit={handleSubmit} />);

    const textarea = screen.getByRole('textbox');
    fireEvent.change(textarea, { target: { value: 'Hello' } });
    fireEvent.keyDown(textarea, { key: 'Enter', shiftKey: true });

    expect(handleSubmit).not.toHaveBeenCalled();
  });

  it('should clear textarea after submit', () => {
    render(<InputBar onSubmit={() => {}} />);

    const textarea = screen.getByRole('textbox') as HTMLTextAreaElement;
    fireEvent.change(textarea, { target: { value: 'Hello' } });
    fireEvent.keyDown(textarea, { key: 'Enter' });

    expect(textarea.value).toBe('');
  });

  it('should not submit empty message', () => {
    const handleSubmit = vi.fn();
    render(<InputBar onSubmit={handleSubmit} />);

    const textarea = screen.getByRole('textbox');
    fireEvent.keyDown(textarea, { key: 'Enter' });

    expect(handleSubmit).not.toHaveBeenCalled();
  });

  it('should not submit whitespace-only message', () => {
    const handleSubmit = vi.fn();
    render(<InputBar onSubmit={handleSubmit} />);

    const textarea = screen.getByRole('textbox');
    fireEvent.change(textarea, { target: { value: '   \n   ' } });
    fireEvent.keyDown(textarea, { key: 'Enter' });

    expect(handleSubmit).not.toHaveBeenCalled();
  });

  it('should disable textarea when disabled prop is true', () => {
    render(<InputBar onSubmit={() => {}} disabled />);
    expect(screen.getByRole('textbox')).toBeDisabled();
  });

  it('should show stop button when processing and no text entered', () => {
    const handleStop = vi.fn();
    render(<InputBar onSubmit={() => {}} onStop={handleStop} isProcessing />);

    // Find the button and check for stop icon (square)
    const buttons = screen.getAllByRole('button');
    const stopButton = buttons[0];

    fireEvent.click(stopButton);
    expect(handleStop).toHaveBeenCalled();
  });

  it('should disable send button when textarea is empty', () => {
    render(<InputBar onSubmit={() => {}} />);
    const button = screen.getByRole('button');
    expect(button).toBeDisabled();
  });

  it('should enable send button when textarea has content', () => {
    render(<InputBar onSubmit={() => {}} />);

    const textarea = screen.getByRole('textbox');
    fireEvent.change(textarea, { target: { value: 'Hello' } });

    const button = screen.getByRole('button');
    expect(button).not.toBeDisabled();
  });
});
