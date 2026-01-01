/**
 * @fileoverview Tests for Badge component
 */
import { describe, it, expect } from 'vitest';
import { render, screen } from '@testing-library/react';
import { Badge } from '../../../src/components/ui/Badge.js';

describe('Badge', () => {
  it('should render children', () => {
    render(<Badge>Test Badge</Badge>);
    expect(screen.getByText('Test Badge')).toBeInTheDocument();
  });

  it('should apply default variant styles', () => {
    render(<Badge>Default</Badge>);
    const badge = screen.getByText('Default');
    expect(badge).toHaveStyle({ background: 'var(--bg-overlay)' });
  });

  it('should apply success variant styles', () => {
    render(<Badge variant="success">Success</Badge>);
    const badge = screen.getByText('Success');
    expect(badge).toHaveStyle({ color: 'var(--success)' });
  });

  it('should apply warning variant styles', () => {
    render(<Badge variant="warning">Warning</Badge>);
    const badge = screen.getByText('Warning');
    expect(badge).toHaveStyle({ color: 'var(--warning)' });
  });

  it('should apply error variant styles', () => {
    render(<Badge variant="error">Error</Badge>);
    const badge = screen.getByText('Error');
    expect(badge).toHaveStyle({ color: 'var(--error)' });
  });

  it('should apply info variant styles', () => {
    render(<Badge variant="info">Info</Badge>);
    const badge = screen.getByText('Info');
    expect(badge).toHaveStyle({ color: 'var(--info)' });
  });

  it('should use monospace font', () => {
    render(<Badge>Mono</Badge>);
    expect(screen.getByText('Mono')).toHaveStyle({ fontFamily: 'var(--font-mono)' });
  });
});
