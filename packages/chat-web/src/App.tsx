/**
 * @fileoverview Main App component for Tron Chat
 */
import React, { useEffect, useState, useCallback } from 'react';
import { ChatPage } from './pages/ChatPage.js';
import { ConnectionStatus } from './components/ui/ConnectionStatus.js';
import { useWebSocket } from './hooks/useWebSocket.js';

export function App(): React.ReactElement {
  const [isOnline, setIsOnline] = useState(navigator.onLine);
  const { status, connect, disconnect } = useWebSocket();

  // Handle online/offline events
  useEffect(() => {
    const handleOnline = () => {
      setIsOnline(true);
      connect();
    };
    const handleOffline = () => setIsOnline(false);

    window.addEventListener('online', handleOnline);
    window.addEventListener('offline', handleOffline);

    // Initial connection
    if (isOnline) {
      connect();
    }

    return () => {
      window.removeEventListener('online', handleOnline);
      window.removeEventListener('offline', handleOffline);
      disconnect();
    };
  }, [connect, disconnect, isOnline]);

  return (
    <div
      style={{
        height: '100%',
        display: 'flex',
        flexDirection: 'column',
        background: 'var(--bg-base)',
        color: 'var(--text-primary)',
      }}
    >
      {/* Connection status banner */}
      {status !== 'connected' && (
        <ConnectionStatus status={status} isOnline={isOnline} onRetry={connect} />
      )}

      {/* Main content */}
      <ChatPage />
    </div>
  );
}
