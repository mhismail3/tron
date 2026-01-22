/**
 * @fileoverview Workspace Selector Component
 *
 * A modal dialog for selecting a working directory on the server machine
 * when creating a new session.
 */

import { useState, useEffect, useCallback } from 'react';
import type { FilesystemListDirResult, FilesystemGetHomeResult } from '@tron/agent/browser';
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
  /** Connection status from useRpc */
  connectionStatus?: 'connected' | 'connecting' | 'disconnected' | 'reconnecting' | 'error';
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
  connectionStatus: _connectionStatus = 'disconnected',
}: WorkspaceSelectorProps): React.ReactElement | null {
  // Note: connectionStatus prop kept for API compatibility but we now use
  // waitForConnection internally to handle race conditions properly
  void _connectionStatus;
  const [currentPath, setCurrentPath] = useState<string>('');
  const [entries, setEntries] = useState<DirectoryEntry[]>([]);
  const [suggestedPaths, setSuggestedPaths] = useState<FilesystemGetHomeResult['suggestedPaths']>([]);
  const [parentPath, setParentPath] = useState<string | null>(null);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [inputPath, setInputPath] = useState('');
  const [showHidden, setShowHidden] = useState(false);
  // Track actual connection readiness (not just React state)
  const [isReady, setIsReady] = useState(false);

  // Define loadDirectory first (used by loadHome)
  const loadDirectory = useCallback(async (path: string) => {
    if (!client) return;

    // Ensure we're actually connected before making request
    if (!client.isConnected()) {
      setError('Connection lost. Please try again.');
      setIsReady(false);
      return;
    }

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
      const message = err instanceof Error ? err.message : 'Failed to list directory';
      setError(message);
      // If connection was lost during request, mark as not ready
      if (message === 'Not connected' || message === 'Connection closed') {
        setIsReady(false);
      }
    } finally {
      setLoading(false);
    }
  }, [client, showHidden]);

  // Wait for the client to be actually connected (WebSocket OPEN state)
  const waitForConnection = useCallback(async (timeoutMs = 5000): Promise<boolean> => {
    if (!client) {
      console.log('[WorkspaceSelector] waitForConnection: no client');
      return false;
    }

    const startTime = Date.now();
    const pollInterval = 100;
    let pollCount = 0;

    console.log('[WorkspaceSelector] waitForConnection: starting poll, timeout=%dms', timeoutMs);

    while (Date.now() - startTime < timeoutMs) {
      const connected = client.isConnected();
      if (pollCount % 10 === 0) { // Log every 1 second
        console.log('[WorkspaceSelector] waitForConnection: poll #%d, connected=%s, elapsed=%dms',
          pollCount, connected, Date.now() - startTime);
      }
      if (connected) {
        console.log('[WorkspaceSelector] waitForConnection: connected after %dms', Date.now() - startTime);
        return true;
      }
      await new Promise(resolve => setTimeout(resolve, pollInterval));
      pollCount++;
    }

    console.log('[WorkspaceSelector] waitForConnection: TIMEOUT after %dms', Date.now() - startTime);
    return false;
  }, [client]);

  // Load home directory with proper connection waiting
  const loadHome = useCallback(async () => {
    if (!client) {
      setError('No client available');
      return;
    }

    setLoading(true);
    setError(null);
    setIsReady(false);

    // First, wait for actual WebSocket connection to be ready
    const connected = await waitForConnection(5000);
    if (!connected) {
      setError('Unable to connect to server');
      setLoading(false);
      return;
    }

    setIsReady(true);

    try {
      const result = await client.filesystemGetHome({});
      setSuggestedPaths(result.suggestedPaths);
      await loadDirectory(result.homePath);
    } catch (err) {
      const message = err instanceof Error ? err.message : 'Failed to load home directory';
      setError(message);
      setLoading(false);
    }
  }, [client, loadDirectory, waitForConnection]);

  // Load home directory when modal opens (loadHome handles connection waiting)
  useEffect(() => {
    if (isOpen && client) {
      // Reset state when modal opens
      setError(null);
      setIsReady(false);
      loadHome();
    }
  }, [isOpen, client, loadHome]);

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

          {/* Connecting/Loading state - show spinner while waiting for connection or loading */}
          {loading && (
            <div className="workspace-loading">
              <div className="workspace-spinner" />
              {!isReady && <span>Connecting to server...</span>}
            </div>
          )}

          {/* Error state */}
          {error && !loading && (
            <div className="workspace-error">
              <span>{error}</span>
              <button
                onClick={loadHome}
                className="workspace-retry-button"
              >
                Retry
              </button>
            </div>
          )}

          {/* Directory entries */}
          {isReady && !loading && !error && (
            <div className="workspace-entries">
              {entries.length === 0 && currentPath ? (
                <div className="workspace-empty">No subdirectories</div>
              ) : entries.length === 0 ? (
                <div className="workspace-empty">Loading...</div>
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
