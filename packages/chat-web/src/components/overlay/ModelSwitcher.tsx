/**
 * @fileoverview Model Switcher Overlay
 *
 * Interactive overlay for selecting and switching between AI models.
 * Port of TUI's ModelSwitcher to web with terminal aesthetic.
 */

import { useState, useEffect, useRef, useCallback, useMemo } from 'react';
import {
  ANTHROPIC_MODELS,
  getTierIcon,
  formatContextWindow,
  type ModelInfo,
} from '@tron/agent/browser';
import './ModelSwitcher.css';

// =============================================================================
// Types
// =============================================================================

export interface ModelSwitcherProps {
  /** Whether switcher is open */
  open: boolean;
  /** Currently selected model ID */
  currentModel: string;
  /** Called when switcher should close */
  onClose: () => void;
  /** Called when a model is selected */
  onSelect: (model: ModelInfo) => void;
  /** Whether currently loading */
  loading?: boolean;
}

// =============================================================================
// Helper Functions
// =============================================================================

function getTierColor(tier: 'opus' | 'sonnet' | 'haiku'): string {
  switch (tier) {
    case 'opus':
      return 'var(--accent)';
    case 'sonnet':
      return 'var(--text-secondary)';
    case 'haiku':
      return 'var(--mint)';
  }
}

function getTierLabel(tier: 'opus' | 'sonnet' | 'haiku'): string {
  switch (tier) {
    case 'opus':
      return 'Most Capable';
    case 'sonnet':
      return 'Balanced';
    case 'haiku':
      return 'Fast & Light';
  }
}

// =============================================================================
// Component
// =============================================================================

export function ModelSwitcher({
  open,
  currentModel,
  onClose,
  onSelect,
  loading = false,
}: ModelSwitcherProps) {
  const [selectedIndex, setSelectedIndex] = useState(0);
  const listRef = useRef<HTMLUListElement>(null);

  // Get all models sorted by tier, then legacy status, then date
  const models = useMemo(() => {
    const tierOrder = { opus: 0, sonnet: 1, haiku: 2 };
    return [...ANTHROPIC_MODELS].sort((a, b) => {
      // First: non-legacy before legacy
      const legacyDiff = (a.legacy ? 1 : 0) - (b.legacy ? 1 : 0);
      if (legacyDiff !== 0) return legacyDiff;
      // Then: by tier (opus, sonnet, haiku)
      const tierDiff = tierOrder[a.tier] - tierOrder[b.tier];
      if (tierDiff !== 0) return tierDiff;
      // Within same tier and legacy status, sort by release date (newest first)
      return b.releaseDate.localeCompare(a.releaseDate);
    });
  }, []);

  // Find current model index
  const currentIndex = useMemo(
    () => models.findIndex((m) => m.id === currentModel),
    [models, currentModel]
  );

  // Reset selection to current model when opened
  useEffect(() => {
    if (open) {
      const idx = currentIndex >= 0 ? currentIndex : 0;
      setSelectedIndex(idx);
    }
  }, [open, currentIndex]);

  // Scroll selected item into view
  useEffect(() => {
    if (listRef.current && models.length > 0) {
      const activeItem = listRef.current.children[selectedIndex] as HTMLElement;
      if (activeItem && typeof activeItem.scrollIntoView === 'function') {
        activeItem.scrollIntoView({ block: 'nearest' });
      }
    }
  }, [selectedIndex, models.length]);

  const handleKeyDown = useCallback(
    (e: React.KeyboardEvent) => {
      switch (e.key) {
        case 'ArrowDown':
        case 'j':
          e.preventDefault();
          setSelectedIndex((prev) => (prev < models.length - 1 ? prev + 1 : prev));
          break;

        case 'ArrowUp':
        case 'k':
          e.preventDefault();
          setSelectedIndex((prev) => (prev > 0 ? prev - 1 : prev));
          break;

        case 'Enter':
          e.preventDefault();
          if (models[selectedIndex] && !loading) {
            onSelect(models[selectedIndex]);
          }
          break;

        case 'Escape':
          e.preventDefault();
          onClose();
          break;
      }
    },
    [models, selectedIndex, onSelect, onClose, loading]
  );

  const handleSelect = useCallback(
    (model: ModelInfo) => {
      if (!loading) {
        onSelect(model);
      }
    },
    [onSelect, loading]
  );

  if (!open) {
    return null;
  }

  const selectedModel = models[selectedIndex];

  return (
    <div
      className="model-switcher-overlay"
      onClick={onClose}
      onKeyDown={handleKeyDown}
      tabIndex={-1}
      ref={(el) => el?.focus()}
    >
      <div
        className="model-switcher"
        role="dialog"
        aria-label="Model switcher"
        onClick={(e) => e.stopPropagation()}
      >
        {/* Header */}
        <div className="model-switcher-header">
          <span className="model-switcher-title">Switch Model</span>
          <span className="model-switcher-count">
            {selectedIndex + 1}/{models.length}
          </span>
        </div>

        {/* Current model indicator */}
        <div className="model-switcher-current">
          <span className="current-label">Current:</span>
          <span className="current-value">{currentModel}</span>
        </div>

        {/* Model list */}
        <ul ref={listRef} className="model-switcher-list" role="listbox">
          {models.map((model, index) => {
            const isSelected = index === selectedIndex;
            const isCurrent = model.id === currentModel;

            return (
              <li
                key={model.id}
                className={`model-item ${isSelected ? 'selected' : ''} ${isCurrent ? 'current' : ''}`}
                role="option"
                aria-selected={isSelected}
                onClick={() => handleSelect(model)}
              >
                <div className="model-item-main">
                  {/* Selection indicator */}
                  <span className="model-indicator">
                    {isSelected ? '\u25B6' : ' '}
                  </span>

                  {/* Tier icon */}
                  <span
                    className="model-tier-icon"
                    style={{ color: isSelected ? undefined : getTierColor(model.tier) }}
                  >
                    {getTierIcon(model.tier)}
                  </span>

                  {/* Model name */}
                  <span className="model-name">{model.shortName}</span>

                  {/* Current badge */}
                  {isCurrent && <span className="model-badge current-badge">(current)</span>}

                  {/* Legacy badge */}
                  {model.legacy && !isSelected && (
                    <span className="model-badge legacy-badge">(legacy)</span>
                  )}
                </div>

                {/* Details (only for selected) */}
                {isSelected && (
                  <div className="model-item-details">
                    <span className="detail-item">
                      {formatContextWindow(model.contextWindow)} ctx
                    </span>
                    <span className="detail-separator">&bull;</span>
                    <span className="detail-item">
                      {model.maxOutput.toLocaleString()} max out
                    </span>
                    {model.supportsThinking && (
                      <>
                        <span className="detail-separator">&bull;</span>
                        <span className="detail-item thinking">thinking</span>
                      </>
                    )}
                    {model.legacy && (
                      <>
                        <span className="detail-separator">&bull;</span>
                        <span className="detail-item legacy">legacy</span>
                      </>
                    )}
                  </div>
                )}

                {/* Description (only for selected) */}
                {isSelected && (
                  <div className="model-item-description">{model.description}</div>
                )}
              </li>
            );
          })}
        </ul>

        {/* Selected model preview */}
        {selectedModel && (
          <div className="model-switcher-preview">
            <div className="preview-tier">
              <span
                className="preview-tier-icon"
                style={{ color: getTierColor(selectedModel.tier) }}
              >
                {getTierIcon(selectedModel.tier)}
              </span>
              <span className="preview-tier-label">
                {getTierLabel(selectedModel.tier)}
              </span>
            </div>
            <div className="preview-cost">
              ${selectedModel.inputCostPerMillion}/M in &bull; $
              {selectedModel.outputCostPerMillion}/M out
            </div>
          </div>
        )}

        {/* Footer */}
        <div className="model-switcher-footer">
          <span className="footer-hint">
            <kbd>&uarr;</kbd>
            <kbd>&darr;</kbd> navigate
          </span>
          <span className="footer-hint">
            <kbd>&crarr;</kbd> select
          </span>
          <span className="footer-hint">
            <kbd>esc</kbd> close
          </span>
        </div>

        {/* Loading overlay */}
        {loading && (
          <div className="model-switcher-loading">
            <span>Switching model...</span>
          </div>
        )}
      </div>
    </div>
  );
}
