/**
 * @fileoverview Welcome Page Component
 *
 * Shown when no sessions exist. Provides a clean landing experience
 * with option to create a new session.
 */

import { useCallback } from 'react';
import './WelcomePage.css';

// =============================================================================
// Types
// =============================================================================

export interface WelcomePageProps {
  /** Called when user wants to create a new session */
  onNewSession: () => void;
  /** Connection status */
  connectionStatus: 'connected' | 'connecting' | 'disconnected' | 'error';
  /** Whether still initializing */
  isInitializing?: boolean;
}

// =============================================================================
// Icons
// =============================================================================

function TronLogo() {
  return (
    <svg width="64" height="64" viewBox="0 0 100 100" fill="none">
      <rect width="100" height="100" rx="20" fill="var(--emerald)" fillOpacity="0.15" />
      <path
        d="M30 30h40v10H55v30H45V40H30V30z"
        fill="var(--emerald)"
      />
    </svg>
  );
}

function PlusIcon() {
  return (
    <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
      <path d="M12 5v14M5 12h14" strokeLinecap="round" />
    </svg>
  );
}

function FolderIcon() {
  return (
    <svg width="20" height="20" viewBox="0 0 24 24" fill="currentColor">
      <path d="M10 4H4c-1.1 0-1.99.9-1.99 2L2 18c0 1.1.9 2 2 2h16c1.1 0 2-.9 2-2V8c0-1.1-.9-2-2-2h-8l-2-2z" />
    </svg>
  );
}

function TerminalIcon() {
  return (
    <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
      <path d="M4 17l6-6-6-6M12 19h8" strokeLinecap="round" strokeLinejoin="round" />
    </svg>
  );
}

function CodeIcon() {
  return (
    <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
      <path d="M16 18l6-6-6-6M8 6l-6 6 6 6" strokeLinecap="round" strokeLinejoin="round" />
    </svg>
  );
}

// =============================================================================
// Component
// =============================================================================

export function WelcomePage({
  onNewSession,
  connectionStatus,
  isInitializing = false,
}: WelcomePageProps) {
  const handleNewSession = useCallback(() => {
    onNewSession();
  }, [onNewSession]);

  // Show loading state while initializing
  if (isInitializing) {
    return (
      <div className="welcome-page">
        <div className="welcome-loading">
          <div className="welcome-spinner" />
          <span className="welcome-loading-text">Connecting...</span>
        </div>
      </div>
    );
  }

  const isConnected = connectionStatus === 'connected';
  const isConnecting = connectionStatus === 'connecting';

  return (
    <div className="welcome-page">
      <div className="welcome-content">
        {/* Logo and title */}
        <div className="welcome-header">
          <TronLogo />
          <h1 className="welcome-title">Tron</h1>
          <p className="welcome-subtitle">AI-powered coding assistant</p>
        </div>

        {/* Status indicator */}
        <div className={`welcome-status ${connectionStatus}`}>
          <span className="welcome-status-dot" />
          <span className="welcome-status-text">
            {isConnected ? 'Connected to server' :
             isConnecting ? 'Connecting...' :
             connectionStatus === 'error' ? 'Connection error' :
             'Disconnected'}
          </span>
        </div>

        {/* Features list */}
        <div className="welcome-features">
          <div className="welcome-feature">
            <span className="welcome-feature-icon"><FolderIcon /></span>
            <span className="welcome-feature-text">Full file system access</span>
          </div>
          <div className="welcome-feature">
            <span className="welcome-feature-icon"><TerminalIcon /></span>
            <span className="welcome-feature-text">Execute shell commands</span>
          </div>
          <div className="welcome-feature">
            <span className="welcome-feature-icon"><CodeIcon /></span>
            <span className="welcome-feature-text">Edit code with precision</span>
          </div>
        </div>

        {/* Create session button */}
        <button
          onClick={handleNewSession}
          className="welcome-button"
          disabled={!isConnected}
        >
          <PlusIcon />
          <span>New Session</span>
        </button>

        {/* Help text */}
        {!isConnected && !isConnecting && (
          <p className="welcome-help">
            Waiting for server connection...
          </p>
        )}

        {/* Keyboard shortcut hint */}
        {isConnected && (
          <p className="welcome-hint">
            <kbd>Ctrl</kbd> + <kbd>N</kbd> to create a new session
          </p>
        )}
      </div>
    </div>
  );
}
