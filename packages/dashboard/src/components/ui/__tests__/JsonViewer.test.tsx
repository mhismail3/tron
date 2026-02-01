/**
 * @fileoverview Tests for JsonViewer component
 */

import { describe, it, expect, vi } from 'vitest';
import { render, screen, fireEvent } from '@testing-library/react';
import { JsonViewer } from '../JsonViewer.js';

describe('JsonViewer', () => {
  it('renders primitive values inline', () => {
    const { container } = render(<JsonViewer data="hello" />);
    expect(container.textContent).toContain('"hello"');
  });

  it('renders numbers correctly', () => {
    const { container } = render(<JsonViewer data={42} />);
    expect(container.textContent).toContain('42');
  });

  it('renders booleans correctly', () => {
    const { container } = render(<JsonViewer data={true} />);
    expect(container.textContent).toContain('true');
  });

  it('renders null correctly', () => {
    const { container } = render(<JsonViewer data={null} />);
    expect(container.textContent).toContain('null');
  });

  it('renders objects collapsed by default', () => {
    const data = { name: 'test', value: 42 };
    render(<JsonViewer data={data} />);

    // Should show the collapsed indicator
    expect(screen.getByText(/\{/)).toBeInTheDocument();
  });

  it('expands objects when clicked', () => {
    const data = { name: 'test', value: 42 };
    render(<JsonViewer data={data} initialExpanded={false} />);

    // Find and click the toggle
    const toggle = screen.getByRole('button');
    fireEvent.click(toggle);

    // Should now show the content
    expect(screen.getByText(/name/)).toBeInTheDocument();
  });

  it('renders arrays with length indicator', () => {
    const data = [1, 2, 3];
    const { container } = render(<JsonViewer data={data} />);
    expect(container.textContent).toContain('[');
  });

  it('respects initialExpanded prop', () => {
    const data = { name: 'test' };
    render(<JsonViewer data={data} initialExpanded={true} />);

    // Should show content when expanded
    expect(screen.getByText(/name/)).toBeInTheDocument();
  });

  it('handles deep nested objects', () => {
    const data = {
      level1: {
        level2: {
          level3: 'deep value',
        },
      },
    };
    render(<JsonViewer data={data} initialExpanded={true} />);
    expect(screen.getByText(/level1/)).toBeInTheDocument();
  });
});
