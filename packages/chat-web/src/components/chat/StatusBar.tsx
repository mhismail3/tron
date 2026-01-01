/**
 * @fileoverview Status bar showing model, tokens, cost
 */
import React from 'react';
import { Badge } from '../ui/Badge.js';

interface StatusBarProps {
  model?: string;
  inputTokens?: number;
  outputTokens?: number;
  cost?: number;
  contextPercent?: number;
}

export function StatusBar({
  model = 'claude-sonnet-4-20250514',
  inputTokens = 0,
  outputTokens = 0,
  cost,
  contextPercent = 0,
}: StatusBarProps): React.ReactElement {
  const formatNumber = (n: number): string => {
    if (n >= 1000000) return `${(n / 1000000).toFixed(1)}M`;
    if (n >= 1000) return `${(n / 1000).toFixed(1)}K`;
    return n.toString();
  };

  const getContextColor = (): string => {
    if (contextPercent > 80) return 'var(--error)';
    if (contextPercent > 60) return 'var(--warning)';
    return 'var(--text-tertiary)';
  };

  return (
    <div
      style={{
        display: 'flex',
        alignItems: 'center',
        justifyContent: 'space-between',
        padding: 'var(--space-sm) var(--space-md)',
        background: 'var(--bg-surface)',
        borderBottom: '1px solid var(--border-subtle)',
        fontSize: 'var(--text-xs)',
        fontFamily: 'var(--font-mono)',
        color: 'var(--text-tertiary)',
      }}
    >
      {/* Model info */}
      <div style={{ display: 'flex', alignItems: 'center', gap: 'var(--space-sm)' }}>
        <Badge>{model}</Badge>
      </div>

      {/* Stats */}
      <div style={{ display: 'flex', alignItems: 'center', gap: 'var(--space-md)' }}>
        {/* Tokens */}
        <div style={{ display: 'flex', gap: 'var(--space-xs)' }}>
          <span style={{ color: 'var(--text-muted)' }}>in:</span>
          <span>{formatNumber(inputTokens)}</span>
          <span style={{ color: 'var(--text-muted)' }}>out:</span>
          <span>{formatNumber(outputTokens)}</span>
        </div>

        {/* Cost */}
        {cost !== undefined && cost > 0 && (
          <span style={{ color: 'var(--success)' }}>
            ${cost.toFixed(4)}
          </span>
        )}

        {/* Context usage */}
        <div style={{ display: 'flex', alignItems: 'center', gap: 'var(--space-xs)' }}>
          <div
            style={{
              width: 40,
              height: 4,
              background: 'var(--bg-overlay)',
              borderRadius: 'var(--radius-full)',
              overflow: 'hidden',
            }}
          >
            <div
              style={{
                width: `${contextPercent}%`,
                height: '100%',
                background: getContextColor(),
                transition: 'width var(--transition-normal)',
              }}
            />
          </div>
          <span style={{ color: getContextColor() }}>{contextPercent}%</span>
        </div>
      </div>
    </div>
  );
}
