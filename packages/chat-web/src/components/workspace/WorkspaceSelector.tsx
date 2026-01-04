/**
 * @fileoverview Workspace Selector Component
 *
 * A modal dialog for selecting a working directory on the server machine
 * when creating a new session.
 */

import React, { useState, useEffect, useCallback } from 'react';
import type { FilesystemListDirResult, FilesystemGetHomeResult } from '@tron/core/browser';
import type { RpcClient } from '../../rpc/client.js';

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
    } finally {
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
    if (currentPath && client) {
      loadDirectory(currentPath);
    }
  }, [showHidden]);

  if (!isOpen) return null;

  return (
    <div
      className="fixed inset-0 z-50 flex items-center justify-center bg-black/50"
      onKeyDown={handleKeyDown}
    >
      <div className="w-full max-w-2xl max-h-[80vh] bg-[#1a1a1a] border border-neutral-700 rounded-lg shadow-2xl flex flex-col">
        {/* Header */}
        <div className="flex items-center justify-between p-4 border-b border-neutral-700">
          <h2 className="text-lg font-semibold text-white">Select Workspace</h2>
          <button
            onClick={onClose}
            className="p-1 text-neutral-400 hover:text-white transition-colors"
          >
            <svg className="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
              <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M6 18L18 6M6 6l12 12" />
            </svg>
          </button>
        </div>

        {/* Path input */}
        <form onSubmit={handlePathSubmit} className="p-4 border-b border-neutral-700">
          <div className="flex gap-2">
            <input
              type="text"
              value={inputPath}
              onChange={(e) => setInputPath(e.target.value)}
              className="flex-1 px-3 py-2 bg-neutral-800 border border-neutral-600 rounded text-sm text-white placeholder-neutral-400 focus:outline-none focus:border-blue-500"
              placeholder="Enter path..."
            />
            <button
              type="submit"
              className="px-4 py-2 bg-neutral-700 text-white rounded hover:bg-neutral-600 transition-colors text-sm"
            >
              Go
            </button>
          </div>
        </form>

        {/* Quick access */}
        {suggestedPaths.length > 0 && (
          <div className="p-4 border-b border-neutral-700">
            <div className="text-xs text-neutral-400 mb-2">Quick Access</div>
            <div className="flex flex-wrap gap-2">
              {suggestedPaths.map((item) => (
                <button
                  key={item.path}
                  onClick={() => handleSelectSuggested(item.path)}
                  className="px-3 py-1.5 bg-neutral-800 text-neutral-300 rounded hover:bg-neutral-700 hover:text-white transition-colors text-sm"
                >
                  {item.name}
                </button>
              ))}
            </div>
          </div>
        )}

        {/* Directory browser */}
        <div className="flex-1 overflow-y-auto p-4">
          {/* Navigation bar */}
          <div className="flex items-center gap-2 mb-3">
            <button
              onClick={handleGoUp}
              disabled={!parentPath}
              className="p-1.5 bg-neutral-800 rounded hover:bg-neutral-700 disabled:opacity-50 disabled:cursor-not-allowed transition-colors"
            >
              <svg className="w-4 h-4 text-neutral-300" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M5 10l7-7m0 0l7 7m-7-7v18" />
              </svg>
            </button>
            <span className="text-sm text-neutral-300 truncate flex-1">{currentPath}</span>
            <label className="flex items-center gap-1.5 text-xs text-neutral-400 cursor-pointer">
              <input
                type="checkbox"
                checked={showHidden}
                onChange={handleToggleHidden}
                className="rounded border-neutral-600"
              />
              Show hidden
            </label>
          </div>

          {/* Loading state */}
          {loading && (
            <div className="flex items-center justify-center py-8">
              <div className="w-6 h-6 border-2 border-neutral-600 border-t-blue-500 rounded-full animate-spin" />
            </div>
          )}

          {/* Error state */}
          {error && (
            <div className="text-red-400 text-sm py-4 text-center">{error}</div>
          )}

          {/* Directory entries */}
          {!loading && !error && (
            <div className="space-y-1">
              {entries.length === 0 ? (
                <div className="text-neutral-400 text-sm py-4 text-center">
                  No subdirectories
                </div>
              ) : (
                entries.map((entry) => (
                  <button
                    key={entry.path}
                    onClick={() => handleNavigate(entry.path)}
                    className="w-full flex items-center gap-2 px-3 py-2 hover:bg-neutral-800 rounded transition-colors text-left"
                  >
                    <svg className="w-5 h-5 text-yellow-500" fill="currentColor" viewBox="0 0 24 24">
                      <path d="M10 4H4c-1.1 0-1.99.9-1.99 2L2 18c0 1.1.9 2 2 2h16c1.1 0 2-.9 2-2V8c0-1.1-.9-2-2-2h-8l-2-2z" />
                    </svg>
                    <span className="text-sm text-neutral-200">{entry.name}</span>
                  </button>
                ))
              )}
            </div>
          )}
        </div>

        {/* Footer */}
        <div className="flex items-center justify-between p-4 border-t border-neutral-700">
          <div className="text-sm text-neutral-400">
            Selected: <span className="text-neutral-200">{currentPath || 'None'}</span>
          </div>
          <div className="flex gap-2">
            <button
              onClick={onClose}
              className="px-4 py-2 bg-neutral-700 text-white rounded hover:bg-neutral-600 transition-colors text-sm"
            >
              Cancel
            </button>
            <button
              onClick={handleSelect}
              disabled={!currentPath}
              className="px-4 py-2 bg-blue-600 text-white rounded hover:bg-blue-500 disabled:opacity-50 disabled:cursor-not-allowed transition-colors text-sm"
            >
              Select Workspace
            </button>
          </div>
        </div>
      </div>
    </div>
  );
}
