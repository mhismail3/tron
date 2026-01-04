/**
 * @fileoverview CommandPalette Component
 *
 * Overlay for searching and executing slash commands.
 * Supports keyboard navigation and fuzzy filtering.
 */

import { useState, useEffect, useRef, useCallback, useMemo } from 'react';
import { filterCommands, type Command } from '../../commands/index.js';
import './CommandPalette.css';

// =============================================================================
// Types
// =============================================================================

export interface CommandPaletteProps {
  /** Whether palette is open */
  open: boolean;
  /** Called when palette should close */
  onClose: () => void;
  /** Called when command is selected */
  onSelect?: (command: Command) => void;
  /** Initial query */
  initialQuery?: string;
}

// =============================================================================
// Component
// =============================================================================

export function CommandPalette({
  open,
  onClose,
  onSelect,
  initialQuery = '',
}: CommandPaletteProps) {
  const [query, setQuery] = useState(initialQuery);
  const [selectedIndex, setSelectedIndex] = useState(0);
  const inputRef = useRef<HTMLInputElement>(null);
  const listRef = useRef<HTMLUListElement>(null);

  // Filter commands based on query
  const matches = useMemo(() => filterCommands(query), [query]);

  // Reset selection when matches change
  useEffect(() => {
    setSelectedIndex(0);
  }, [matches.length]);

  // Reset query when opened
  useEffect(() => {
    if (open) {
      setQuery(initialQuery);
      setSelectedIndex(0);
    }
  }, [open, initialQuery]);

  // Focus input when opened
  useEffect(() => {
    if (open && inputRef.current) {
      inputRef.current.focus();
    }
  }, [open]);

  // Scroll selected item into view
  useEffect(() => {
    if (listRef.current && matches.length > 0) {
      const activeItem = listRef.current.children[selectedIndex] as HTMLElement;
      if (activeItem && typeof activeItem.scrollIntoView === 'function') {
        activeItem.scrollIntoView({ block: 'nearest' });
      }
    }
  }, [selectedIndex, matches.length]);

  const handleKeyDown = useCallback(
    (e: React.KeyboardEvent) => {
      switch (e.key) {
        case 'ArrowDown':
          e.preventDefault();
          setSelectedIndex((prev) =>
            prev < matches.length - 1 ? prev + 1 : prev,
          );
          break;

        case 'ArrowUp':
          e.preventDefault();
          setSelectedIndex((prev) => (prev > 0 ? prev - 1 : prev));
          break;

        case 'Enter':
          e.preventDefault();
          if (matches[selectedIndex]) {
            handleSelect(matches[selectedIndex].command);
          }
          break;

        case 'Escape':
          e.preventDefault();
          onClose();
          break;
      }
    },
    [matches, selectedIndex, onClose],
  );

  const handleSelect = useCallback(
    (command: Command) => {
      onSelect?.(command);
      onClose();
    },
    [onSelect, onClose],
  );

  const handleInputChange = useCallback(
    (e: React.ChangeEvent<HTMLInputElement>) => {
      setQuery(e.target.value);
    },
    [],
  );

  if (!open) {
    return null;
  }

  const activeId =
    matches.length > 0 ? `command-item-${selectedIndex}` : undefined;

  return (
    <div className="command-palette-overlay" onClick={onClose}>
      <div
        className="command-palette"
        role="dialog"
        aria-label="Command palette"
        onClick={(e) => e.stopPropagation()}
      >
        {/* Search Input */}
        <div className="command-palette-input-wrapper">
          <span className="command-palette-prefix">/</span>
          <input
            ref={inputRef}
            type="text"
            className="command-palette-input"
            value={query}
            onChange={handleInputChange}
            onKeyDown={handleKeyDown}
            placeholder="Type a command..."
            role="combobox"
            aria-expanded={true}
            aria-controls="command-list"
            aria-activedescendant={activeId}
            aria-autocomplete="list"
          />
        </div>

        {/* Command List */}
        <ul
          id="command-list"
          ref={listRef}
          className="command-palette-list"
          role="listbox"
        >
          {matches.length === 0 ? (
            <li className="command-palette-empty">No commands found</li>
          ) : (
            matches.map((match, index) => (
              <li
                key={match.command.name}
                id={`command-item-${index}`}
                className={`command-item ${index === selectedIndex ? 'active' : ''}`}
                role="option"
                aria-selected={index === selectedIndex}
                onClick={() => handleSelect(match.command)}
              >
                <span className="command-name">/{match.command.name}</span>
                {match.command.alias && (
                  <span className="command-alias">/{match.command.alias}</span>
                )}
                <span className="command-description">
                  {match.command.description}
                </span>
              </li>
            ))
          )}
        </ul>

        {/* Footer */}
        <div className="command-palette-footer">
          <span className="footer-hint">
            <kbd>↑</kbd>
            <kbd>↓</kbd> navigate
          </span>
          <span className="footer-hint">
            <kbd>↵</kbd> select
          </span>
          <span className="footer-hint">
            <kbd>esc</kbd> close
          </span>
        </div>
      </div>
    </div>
  );
}
