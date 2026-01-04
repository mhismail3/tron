/**
 * @fileoverview Workspace Selector Component
 *
 * A modal dialog for selecting a working directory on the server machine
 * when creating a new session.
 */

import { useState, useEffect, useCallback } from 'react';
import type { FilesystemListDirResult, FilesystemGetHomeResult } from '@tron/core/browser';
import type { RpcClient } from '../../rpc/client.js';
import './WorkspaceSelector.css';

// =============================================================================
// Types
// =============================================================================

export interface WorkspaceSelectorProps {
  /** Whether the modal is open */
  isOpen: boolean;
  /** Called when a workspace is selected */
  onSelect: (path: string) => void;
  /** Called when the modal is closed without selection */
  onClose: () => void;
  /** RPC client for filesystem operations */
  client: RpcClient | null;
}

interface DirectoryEntry {
  name: string;
  path: string;
  isDirectory: boolean;
}

// =============================================================================
// Icons
// =============================================================================

function CloseIcon() {
  return (
    <svg fill="none" stroke="currentColor" viewBox="0 0 24 24">
      <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M6 18L18 6M6 6l12 12" />
    </svg>
  );
}

function UpIcon() {
  return (
    <svg fill="none" stroke="currentColor" viewBox="0 0 24 24">
      <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M5 10l7-7m0 0l7 7m-7-7v18" />
    </svg>
  );
}

function FolderIcon() {
  return (
    <svg fill="currentColor" viewBox="0 0 24 24">
      <path d="M10 4H4c-1.1 0-1.99.9-1.99 2L2 18c0 1.1.9 2 2 2h16c1.1 0 2-.9 2-2V8c0-1.1-.9-2-2-2h-8l-2-2z" />
    </svg>
  );
}

// =============================================================================
// Component
// =============================================================================

export function WorkspaceSelector({
  isOpen,
  onSelect,
  onClose,
  client,
}: WorkspaceSelectorProps): React.ReactElement | null {
  const [currentPath, setCurrentPath] = useState<string>('');
  const [entries, setEntries] = useState<DirectoryEntry[]>([]);
  const [suggestedPaths, setSuggestedPaths] = useState<FilesystemGetHomeResult['suggestedPaths']>([]);
  const [parentPath, setParentPath] = useState<string | null>(null);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [inputPath, setInputPath] = useState('');
  const [showHidden, setShowHidden] = useState(false);

  // Load home directory and suggestions on mount
  useEffect(() => {
    if (isOpen && client) {
      loadHome();
    }
  }, [isOpen, client]);

  const loadHome = useCallback(async () => {
    if (!client) return;

    setLoading(true);
    setError(null);

    try {
      const result = await client.filesystemGetHome({});
      setSuggestedPaths(result.suggestedPaths);
      // Navigate to home directory
      await loadDirectory(result.homePath);
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to load home directory');
      setLoading(false);
    }
  }, [client]);

  const loadDirectory = useCallback(async (path: string) => {
    if (!client) return;

    setLoading(true);
    setError(null);

    try {
      const result: FilesystemListDirResult = await client.filesystemListDir({
        path,
        showHidden,
      });

      setCurrentPath(result.path);
      setParentPath(result.parent);
      setInputPath(result.path);
      // Filter to only directories (for workspace selection)
      setEntries(
        result.entries.filter(e => e.isDirectory).map(e => ({
          name: e.name,
          path: e.path,
          isDirectory: e.isDirectory,
        }))
      );
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to list directory');
    } finally {
      setLoading(false);
    }
  }, [client, showHidden]);

  const handleNavigate = useCallback((path: string) => {
    loadDirectory(path);
  }, [loadDirectory]);

  const handleGoUp = useCallback(() => {
    if (parentPath) {
      loadDirectory(parentPath);
    }
  }, [parentPath, loadDirectory]);

  const handlePathSubmit = useCallback((e: React.FormEvent) => {
    e.preventDefault();
    if (inputPath.trim()) {
      loadDirectory(inputPath.trim());
    }
  }, [inputPath, loadDirectory]);

  const handleSelect = useCallback(() => {
    if (currentPath) {
      onSelect(currentPath);
    }
  }, [currentPath, onSelect]);

  const handleSelectSuggested = useCallback((path: string) => {
    onSelect(path);
  }, [onSelect]);

  const handleKeyDown = useCallback((e: React.KeyboardEvent) => {
    if (e.key === 'Escape') {
      onClose();
    }
  }, [onClose]);

  // Toggle hidden files and reload
  const handleToggleHidden = useCallback(() => {
    setShowHidden(prev => !prev);
  }, []);

  // Reload when showHidden changes
  useEffect(() => {
    if (currentPath && client && isOpen) {
      loadDirectory(currentPath);
    }
  }, [showHidden]);

  if (!isOpen) return null;

  return (
    <div
      className="workspace-selector-overlay"
      onClick={onClose}
      onKeyDown={handleKeyDown}
      tabIndex={-1}
      ref={(el) => el?.focus()}
    >
      <div
        className="workspace-selector"
        role="dialog"
        aria-label="Workspace selector"
        onClick={(e) => e.stopPropagation()}
      >
        {/* Header */}
        <div className="workspace-selector-header">
          <span className="workspace-selector-title">Select Workspace</span>
          <button className="workspace-selector-close" onClick={onClose}>
            <CloseIcon />
          </button>
        </div>

        {/* Path input */}
        <form className="workspace-path-form" onSubmit={handlePathSubmit}>
          <input
            type="text"
            value={inputPath}
            onChange={(e) => setInputPath(e.target.value)}
            className="workspace-path-input"
            placeholder="Enter path..."
          />
          <button type="submit" className="workspace-path-button">
            Go
          </button>
        </form>

        {/* Quick access */}
        {suggestedPaths.length > 0 && (
          <div className="workspace-quick-access">
            <div className="workspace-quick-label">Quick Access</div>
            <div className="workspace-quick-buttons">
              {suggestedPaths.map((item) => (
                <button
                  key={item.path}
                  onClick={() => handleSelectSuggested(item.path)}
                  className="workspace-quick-button"
                >
                  {item.name}
                </button>
              ))}
            </div>
          </div>
        )}

        {/* Directory browser */}
        <div className="workspace-browser">
          {/* Navigation bar */}
          <div className="workspace-nav-bar">
            <button
              onClick={handleGoUp}
              disabled={!parentPath}
              className="workspace-nav-up"
            >
              <UpIcon />
            </button>
            <span className="workspace-current-path">{currentPath}</span>
            <label className="workspace-hidden-toggle">
              <input
                type="checkbox"
                checked={showHidden}
                onChange={handleToggleHidden}
              />
              Show hidden
            </label>
          </div>

          {/* Loading state */}
          {loading && (
            <div className="workspace-loading">
              <div className="workspace-spinner" />
            </div>
          )}

          {/* Error state */}
          {error && !loading && (
            <div className="workspace-error">{error}</div>
          )}

          {/* Directory entries */}
          {!loading && !error && (
            <div className="workspace-entries">
              {entries.length === 0 ? (
                <div className="workspace-empty">No subdirectories</div>
              ) : (
                entries.map((entry) => (
                  <button
                    key={entry.path}
                    onClick={() => handleNavigate(entry.path)}
                    className="workspace-entry"
                  >
                    <span className="workspace-entry-icon">
                      <FolderIcon />
                    </span>
                    <span className="workspace-entry-name">{entry.name}</span>
                  </button>
                ))
              )}
            </div>
          )}
        </div>

        {/* Footer */}
        <div className="workspace-selector-footer">
          <div className="workspace-selected">
            Selected: <span className="workspace-selected-path">{currentPath || 'None'}</span>
          </div>
          <div className="workspace-footer-buttons">
            <button onClick={onClose} className="workspace-button-cancel">
              Cancel
            </button>
            <button
              onClick={handleSelect}
              disabled={!currentPath}
              className="workspace-button-select"
            >
              Select Workspace
            </button>
          </div>
        </div>
      </div>
    </div>
  );
}
