/**
 * @fileoverview Tests for Spinner component
 */
import { describe, it, expect } from 'vitest';
import { render } from '@testing-library/react';
import { Spinner } from '../../../src/components/ui/Spinner.js';

describe('Spinner', () => {
  it('should render an SVG element', () => {
    const { container } = render(<Spinner />);
    const svg = container.querySelector('svg');
    expect(svg).toBeInTheDocument();
  });

  it('should use default size of 16', () => {
    const { container } = render(<Spinner />);
    const svg = container.querySelector('svg');
    expect(svg).toHaveAttribute('width', '16');
    expect(svg).toHaveAttribute('height', '16');
  });

  it('should accept custom size', () => {
    const { container } = render(<Spinner size={24} />);
    const svg = container.querySelector('svg');
    expect(svg).toHaveAttribute('width', '24');
    expect(svg).toHaveAttribute('height', '24');
  });

  it('should have animation style', () => {
    const { container } = render(<Spinner />);
    const svg = container.querySelector('svg');
    expect(svg).toHaveStyle({ animation: 'spin 1s linear infinite' });
  });

  it('should render two circles', () => {
    const { container } = render(<Spinner />);
    const circles = container.querySelectorAll('circle');
    expect(circles).toHaveLength(2);
  });
});
