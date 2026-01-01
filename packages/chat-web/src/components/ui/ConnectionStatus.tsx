/**
 * @fileoverview Connection status banner
 */
import React from 'react';
import type { ConnectionStatus as Status } from '../../hooks/useWebSocket.js';
import { Spinner } from './Spinner.js';

interface ConnectionStatusProps {
  status: Status;
  isOnline: boolean;
  onRetry: () => void;
}

export function ConnectionStatus({
  status,
  isOnline,
  onRetry,
}: ConnectionStatusProps): React.ReactElement {
  const getMessage = () => {
    if (!isOnline) return 'No internet connection';
    if (status === 'connecting') return 'Connecting to server...';
    if (status === 'error') return 'Connection error';
    return 'Disconnected from server';
  };

  const bgColor = status === 'error' || !isOnline ? 'var(--error)' : 'var(--warning)';

  return (
    <div
      style={{
        display: 'flex',
        alignItems: 'center',
        justifyContent: 'center',
        gap: 'var(--space-sm)',
        padding: 'var(--space-sm) var(--space-md)',
        background: bgColor,
        color: 'var(--bg-base)',
        fontWeight: 500,
        fontSize: 'var(--text-sm)',
      }}
    >
      {status === 'connecting' && <Spinner size={14} />}
      <span>{getMessage()}</span>
      {status !== 'connecting' && (
        <button
          onClick={onRetry}
          style={{
            background: 'rgba(0, 0, 0, 0.2)',
            border: 'none',
            borderRadius: 'var(--radius-sm)',
            padding: '2px 8px',
            color: 'inherit',
            cursor: 'pointer',
            fontSize: 'var(--text-sm)',
          }}
        >
          Retry
        </button>
      )}
    </div>
  );
}
