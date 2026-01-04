/**
 * @fileoverview Badge component for status indicators
 */
import React from 'react';

interface BadgeProps {
  variant?: 'default' | 'success' | 'warning' | 'error' | 'info';
  children: React.ReactNode;
}

export function Badge({ variant = 'default', children }: BadgeProps): React.ReactElement {
  const colors: Record<string, { bg: string; text: string }> = {
    default: { bg: 'var(--bg-overlay)', text: 'var(--text-secondary)' },
    success: { bg: 'rgba(74, 222, 128, 0.15)', text: 'var(--success)' },
    warning: { bg: 'rgba(251, 191, 36, 0.15)', text: 'var(--warning)' },
    error: { bg: 'rgba(239, 68, 68, 0.15)', text: 'var(--error)' },
    info: { bg: 'rgba(96, 165, 250, 0.15)', text: 'var(--info)' },
  };

  const defaultColors = { bg: 'var(--bg-overlay)', text: 'var(--text-secondary)' };
  const colorConfig = colors[variant] ?? defaultColors;
  const { bg, text } = colorConfig;

  return (
    <span
      style={{
        display: 'inline-flex',
        alignItems: 'center',
        padding: '2px 8px',
        background: bg,
        color: text,
        borderRadius: 'var(--radius-full)',
        fontSize: 'var(--text-xs)',
        fontWeight: 500,
        fontFamily: 'var(--font-mono)',
      }}
    >
      {children}
    </span>
  );
}
