/**
 * @fileoverview Status bar showing model, tokens, context, directory, theme toggle
 */
import React, { useState, useCallback } from 'react';
import { useTheme, type Theme } from '../../hooks/index.js';

interface TokenUsage {
  input: number;
  output: number;
  cost?: number;
}

interface StatusBarProps {
  /** Connection/processing status */
  status?: 'idle' | 'processing' | 'error' | 'connected';
  /** Current model ID */
  model?: string;
  /** Working directory path */
  workingDirectory?: string;
  /** Token usage stats */
  tokenUsage?: TokenUsage;
  /** Context window usage percentage */
  contextPercent?: number;
  /** Callback when model is changed */
  onModelChange?: (model: string) => void;
  /** Event count for history display */
  eventCount?: number;
  /** Branch count for history display */
  branchCount?: number;
  /** Callback when history button is clicked */
  onHistoryClick?: () => void;
  /** Callback when browse sessions button is clicked */
  onBrowseSessionsClick?: () => void;
}

const THEME_ICONS: Record<Theme, string> = {
  dark: '◐',
  light: '○',
  system: '◑',
};

const THEME_LABELS: Record<Theme, string> = {
  dark: 'Dark',
  light: 'Light',
  system: 'Auto',
};

// Model ID to display name mapping
const MODEL_DISPLAY_NAMES: Record<string, string> = {
  'claude-opus-4-5-20251101': 'Claude Opus 4.5',
  'claude-sonnet-4-20250514': 'Claude Sonnet 4',
  'claude-3-5-sonnet-20241022': 'Claude 3.5 Sonnet',
  'claude-3-5-haiku-20241022': 'Claude 3.5 Haiku',
  'claude-3-opus-20240229': 'Claude 3 Opus',
  'claude-3-sonnet-20240229': 'Claude 3 Sonnet',
  'claude-3-haiku-20240307': 'Claude 3 Haiku',
};

// Available models for switcher
const AVAILABLE_MODELS = [
  { id: 'claude-opus-4-5-20251101', name: 'Claude Opus 4.5', description: 'Most capable' },
  { id: 'claude-sonnet-4-20250514', name: 'Claude Sonnet 4', description: 'Balanced' },
  { id: 'claude-3-5-sonnet-20241022', name: 'Claude 3.5 Sonnet', description: 'Fast & capable' },
  { id: 'claude-3-5-haiku-20241022', name: 'Claude 3.5 Haiku', description: 'Fastest' },
];

function formatModelName(modelId: string): string {
  // Check exact match first
  if (MODEL_DISPLAY_NAMES[modelId]) {
    return MODEL_DISPLAY_NAMES[modelId];
  }

  // Try to parse model name from ID
  const parts = modelId.toLowerCase();

  if (parts.includes('opus-4-5') || parts.includes('opus-4.5')) {
    return 'Claude Opus 4.5';
  }
  if (parts.includes('sonnet-4') && !parts.includes('3')) {
    return 'Claude Sonnet 4';
  }
  if (parts.includes('3-5-sonnet') || parts.includes('3.5-sonnet')) {
    return 'Claude 3.5 Sonnet';
  }
  if (parts.includes('3-5-haiku') || parts.includes('3.5-haiku')) {
    return 'Claude 3.5 Haiku';
  }
  if (parts.includes('opus')) {
    return 'Claude Opus';
  }
  if (parts.includes('sonnet')) {
    return 'Claude Sonnet';
  }
  if (parts.includes('haiku')) {
    return 'Claude Haiku';
  }

  // Fallback: clean up the model ID
  return modelId
    .replace(/-\d{8}$/, '') // Remove date suffix
    .replace(/-/g, ' ')
    .replace(/\b\w/g, c => c.toUpperCase());
}

function formatNumber(n: number): string {
  if (n >= 1000000) return `${(n / 1000000).toFixed(1)}M`;
  if (n >= 1000) return `${(n / 1000).toFixed(1)}K`;
  return n.toString();
}

export function StatusBar({
  status: _status = 'idle',
  model = 'claude-sonnet-4-20250514',
  workingDirectory,
  tokenUsage,
  contextPercent = 0,
  onModelChange,
  eventCount = 0,
  branchCount = 0,
  onHistoryClick,
  onBrowseSessionsClick,
}: StatusBarProps): React.ReactElement {
  const [showModelPicker, setShowModelPicker] = useState(false);
  const { theme, cycleTheme } = useTheme();

  const inTokens = tokenUsage?.input ?? 0;
  const outTokens = tokenUsage?.output ?? 0;

  const handleModelClick = useCallback(() => {
    if (onModelChange) {
      setShowModelPicker(prev => !prev);
    }
  }, [onModelChange]);

  const handleModelSelect = useCallback((modelId: string) => {
    onModelChange?.(modelId);
    setShowModelPicker(false);
  }, [onModelChange]);

  const getContextColor = (): string => {
    if (contextPercent > 80) return 'var(--error)';
    if (contextPercent > 60) return 'var(--warning)';
    return 'var(--text-muted)';
  };

  const projectName = workingDirectory?.split('/').pop() || '';

  return (
    <div
      style={{
        display: 'flex',
        alignItems: 'center',
        justifyContent: 'space-between',
        padding: 'var(--space-xs) 0',
        background: 'var(--bg-surface)',
        fontSize: 'var(--text-xs)',
        fontFamily: 'var(--font-mono)',
        color: 'var(--text-muted)',
        position: 'relative',
      }}
    >
      {/* Left side: Model + Stats */}
      <div style={{ display: 'flex', alignItems: 'center', gap: 'var(--space-lg)' }}>
        {/* Model Selector */}
        <div style={{ position: 'relative' }}>
          <button
            onClick={handleModelClick}
            style={{
              display: 'flex',
              alignItems: 'center',
              gap: 'var(--space-xs)',
              padding: 'var(--space-xs) var(--space-sm)',
              background: 'var(--bg-elevated)',
              border: '1px solid var(--border-default)',
              borderRadius: 'var(--radius-sm)',
              color: 'var(--text-secondary)',
              fontSize: 'var(--text-xs)',
              fontFamily: 'var(--font-mono)',
              cursor: onModelChange ? 'pointer' : 'default',
              transition: 'all var(--transition-fast)',
            }}
            onMouseEnter={(e) => {
              if (onModelChange) {
                e.currentTarget.style.borderColor = 'var(--border-strong)';
                e.currentTarget.style.color = 'var(--text-primary)';
              }
            }}
            onMouseLeave={(e) => {
              e.currentTarget.style.borderColor = 'var(--border-default)';
              e.currentTarget.style.color = 'var(--text-secondary)';
            }}
          >
            <span>{formatModelName(model)}</span>
            {onModelChange && (
              <span style={{ opacity: 0.5 }}>▾</span>
            )}
          </button>

          {/* Model Picker Dropdown */}
          {showModelPicker && (
            <div
              style={{
                position: 'absolute',
                bottom: '100%',
                left: 0,
                marginBottom: 'var(--space-xs)',
                background: 'var(--bg-elevated)',
                border: '1px solid var(--border-default)',
                borderRadius: 'var(--radius-md)',
                boxShadow: 'var(--shadow-lg)',
                minWidth: 200,
                zIndex: 100,
                overflow: 'hidden',
              }}
            >
              {AVAILABLE_MODELS.map((m) => (
                <button
                  key={m.id}
                  onClick={() => handleModelSelect(m.id)}
                  style={{
                    display: 'flex',
                    flexDirection: 'column',
                    alignItems: 'flex-start',
                    width: '100%',
                    padding: 'var(--space-sm) var(--space-md)',
                    background: m.id === model ? 'var(--bg-active)' : 'transparent',
                    border: 'none',
                    color: 'var(--text-primary)',
                    fontSize: 'var(--text-sm)',
                    fontFamily: 'var(--font-mono)',
                    cursor: 'pointer',
                    textAlign: 'left',
                  }}
                  onMouseEnter={(e) => {
                    if (m.id !== model) {
                      e.currentTarget.style.background = 'var(--bg-hover)';
                    }
                  }}
                  onMouseLeave={(e) => {
                    e.currentTarget.style.background = m.id === model ? 'var(--bg-active)' : 'transparent';
                  }}
                >
                  <span style={{ fontWeight: 500 }}>{m.name}</span>
                  <span style={{ fontSize: 'var(--text-xs)', color: 'var(--text-muted)' }}>
                    {m.description}
                  </span>
                </button>
              ))}
            </div>
          )}
        </div>

        {/* Token Stats */}
        <div style={{ display: 'flex', alignItems: 'center', gap: 'var(--space-md)' }}>
          <div style={{ display: 'flex', gap: 'var(--space-sm)' }}>
            <span style={{ color: 'var(--text-dim)' }}>↓</span>
            <span>{formatNumber(inTokens)}</span>
            <span style={{ color: 'var(--text-dim)' }}>↑</span>
            <span>{formatNumber(outTokens)}</span>
          </div>

          {/* Context usage */}
          <div style={{ display: 'flex', alignItems: 'center', gap: 'var(--space-xs)' }}>
            <div
              style={{
                width: 48,
                height: 4,
                background: 'var(--bg-overlay)',
                borderRadius: 'var(--radius-full)',
                overflow: 'hidden',
              }}
            >
              <div
                style={{
                  width: `${Math.min(contextPercent, 100)}%`,
                  height: '100%',
                  background: getContextColor(),
                  transition: 'width var(--transition-normal)',
                }}
              />
            </div>
            <span style={{ color: getContextColor(), minWidth: 32 }}>{contextPercent}%</span>
          </div>
        </div>
      </div>

      {/* Right side: History + Theme toggle + Directory */}
      <div style={{ display: 'flex', alignItems: 'center', gap: 'var(--space-md)' }}>
        {/* Browse Past Sessions Button */}
        {onBrowseSessionsClick && (
          <button
            onClick={onBrowseSessionsClick}
            style={{
              display: 'flex',
              alignItems: 'center',
              gap: 'var(--space-xs)',
              padding: 'var(--space-xs) var(--space-sm)',
              background: 'transparent',
              border: '1px solid var(--border-subtle)',
              borderRadius: 'var(--radius-sm)',
              color: 'var(--text-muted)',
              fontSize: 'var(--text-xs)',
              fontFamily: 'var(--font-mono)',
              cursor: 'pointer',
              transition: 'all var(--transition-fast)',
            }}
            onMouseEnter={(e) => {
              e.currentTarget.style.borderColor = 'var(--border-default)';
              e.currentTarget.style.color = 'var(--text-secondary)';
            }}
            onMouseLeave={(e) => {
              e.currentTarget.style.borderColor = 'var(--border-subtle)';
              e.currentTarget.style.color = 'var(--text-muted)';
            }}
            title="Browse past sessions"
            type="button"
          >
            <span>⎇</span>
            <span>Sessions</span>
          </button>
        )}

        {/* History Button */}
        {onHistoryClick && (
          <button
            onClick={onHistoryClick}
            style={{
              display: 'flex',
              alignItems: 'center',
              gap: 'var(--space-xs)',
              padding: 'var(--space-xs) var(--space-sm)',
              background: 'transparent',
              border: '1px solid var(--border-subtle)',
              borderRadius: 'var(--radius-sm)',
              color: 'var(--text-muted)',
              fontSize: 'var(--text-xs)',
              fontFamily: 'var(--font-mono)',
              cursor: 'pointer',
              transition: 'all var(--transition-fast)',
            }}
            onMouseEnter={(e) => {
              e.currentTarget.style.borderColor = 'var(--border-default)';
              e.currentTarget.style.color = 'var(--text-secondary)';
            }}
            onMouseLeave={(e) => {
              e.currentTarget.style.borderColor = 'var(--border-subtle)';
              e.currentTarget.style.color = 'var(--text-muted)';
            }}
            title="View session history"
            type="button"
          >
            <span>◇</span>
            <span>
              {eventCount} events
              {branchCount > 0 && ` • ${branchCount} branches`}
            </span>
          </button>
        )}

        {/* Theme Toggle */}
        <button
          onClick={cycleTheme}
          style={{
            display: 'flex',
            alignItems: 'center',
            gap: 'var(--space-xs)',
            padding: 'var(--space-xs) var(--space-sm)',
            background: 'transparent',
            border: '1px solid var(--border-subtle)',
            borderRadius: 'var(--radius-sm)',
            color: 'var(--text-muted)',
            fontSize: 'var(--text-xs)',
            fontFamily: 'var(--font-mono)',
            cursor: 'pointer',
            transition: 'all var(--transition-fast)',
          }}
          onMouseEnter={(e) => {
            e.currentTarget.style.borderColor = 'var(--border-default)';
            e.currentTarget.style.color = 'var(--text-secondary)';
          }}
          onMouseLeave={(e) => {
            e.currentTarget.style.borderColor = 'var(--border-subtle)';
            e.currentTarget.style.color = 'var(--text-muted)';
          }}
          title={`Theme: ${THEME_LABELS[theme]} (click to cycle)`}
        >
          <span>{THEME_ICONS[theme]}</span>
          <span>{THEME_LABELS[theme]}</span>
        </button>

        {/* Directory */}
        {workingDirectory && (
          <div
            style={{
              color: 'var(--text-tertiary)',
              display: 'flex',
              alignItems: 'center',
              gap: 'var(--space-xs)',
            }}
            title={workingDirectory}
          >
            <span style={{ opacity: 0.5 }}>📁</span>
            <span>{projectName}</span>
          </div>
        )}
      </div>
    </div>
  );
}
