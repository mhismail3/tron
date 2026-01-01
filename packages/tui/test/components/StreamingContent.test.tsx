/**
 * @fileoverview StreamingContent Component Tests
 */
import { describe, it, expect } from 'vitest';
import React from 'react';
import { render } from 'ink-testing-library';
import { StreamingContent } from '../../src/components/StreamingContent.js';

describe('StreamingContent Component', () => {
  it('should render empty when no content', () => {
    const { lastFrame } = render(<StreamingContent content="" isStreaming={false} />);
    expect(lastFrame()).toBe('');
  });

  it('should render content text', () => {
    const { lastFrame } = render(
      <StreamingContent content="Hello world" isStreaming={false} />
    );
    expect(lastFrame()).toContain('Hello world');
  });

  it('should show cursor when streaming', () => {
    const { lastFrame } = render(
      <StreamingContent content="Hello" isStreaming={true} />
    );
    const frame = lastFrame() ?? '';
    // Should show cursor indicator (block character)
    expect(frame).toContain('Hello');
    expect(frame).toMatch(/[█▌▐|]/); // Some cursor character
  });

  it('should not show cursor when not streaming', () => {
    const { lastFrame } = render(
      <StreamingContent content="Complete" isStreaming={false} />
    );
    const frame = lastFrame() ?? '';
    expect(frame).not.toMatch(/[█▌]/);
  });

  it('should handle multiline content', () => {
    const { lastFrame } = render(
      <StreamingContent content="Line 1\nLine 2\nLine 3" isStreaming={false} />
    );
    const frame = lastFrame() ?? '';
    expect(frame).toContain('Line 1');
    expect(frame).toContain('Line 2');
    expect(frame).toContain('Line 3');
  });
});
