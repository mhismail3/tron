/**
 * @fileoverview Status bar showing model, tokens, cost
 */
import React from 'react';
import { Badge } from '../ui/Badge.js';

interface TokenUsage {
  input: number;
  output: number;
  cost?: number;
}

interface StatusBarProps {
  /** Connection/processing status */
  status?: 'idle' | 'processing' | 'error' | 'connected';
  /** Current model name */
  model?: string;
  /** Token usage stats (new format) */
  tokenUsage?: TokenUsage;
  /** Legacy: input tokens */
  inputTokens?: number;
  /** Legacy: output tokens */
  outputTokens?: number;
  /** Cost in dollars */
  cost?: number;
  /** Context window usage percentage */
  contextPercent?: number;
}

export function StatusBar({
  status: _status = 'idle',
  model = 'claude-sonnet-4-20250514',
  tokenUsage,
  inputTokens = 0,
  outputTokens = 0,
  cost,
  contextPercent = 0,
}: StatusBarProps): React.ReactElement {
  // Support both new and legacy token format
  const inTokens = tokenUsage?.input ?? inputTokens;
  const outTokens = tokenUsage?.output ?? outputTokens;
  const totalCost = tokenUsage?.cost ?? cost;
  // TODO: Use _status to show connection/processing indicator
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
          <span>{formatNumber(inTokens)}</span>
          <span style={{ color: 'var(--text-muted)' }}>out:</span>
          <span>{formatNumber(outTokens)}</span>
        </div>

        {/* Cost */}
        {totalCost !== undefined && totalCost > 0 && (
          <span style={{ color: 'var(--success)' }}>
            ${totalCost.toFixed(4)}
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
