/**
 * @fileoverview React hook for RPC client
 *
 * Provides typed RPC communication with automatic session management.
 */

import { useState, useEffect, useCallback, useRef } from 'react';
import { RpcClient } from '../rpc/client.js';
import type { RpcEvent } from '@tron/core/browser';

// =============================================================================
// Types
// =============================================================================

export type RpcConnectionStatus = 'disconnected' | 'connecting' | 'connected' | 'reconnecting' | 'error';

export interface UseRpcReturn {
  /** Connection status */
  status: RpcConnectionStatus;
  /** Current session ID (if session created) */
  sessionId: string | null;
  /** The RPC client instance */
  client: RpcClient | null;
  /** Connect to server */
  connect: () => Promise<void>;
  /** Disconnect from server */
  disconnect: () => void;
  /** Create or resume a session */
  ensureSession: (workingDirectory?: string) => Promise<string>;
  /** Send a prompt to the agent */
  sendPrompt: (prompt: string) => Promise<void>;
  /** Abort current agent run */
  abort: () => Promise<void>;
  /** Switch to a different model */
  switchModel: (modelId: string) => Promise<{ previousModel: string; newModel: string }>;
  /** Subscribe to all RPC events */
  onEvent: (handler: (event: RpcEvent) => void) => () => void;
  /** Last error */
  error: Error | null;
}

// =============================================================================
// Constants
// =============================================================================

// Use page hostname to support Tailscale/remote access
const getWsUrl = (): string => {
  if (typeof window === 'undefined') return 'ws://localhost:8080/ws';
  const envUrl = (import.meta as { env?: Record<string, string> }).env?.VITE_WS_URL;
  return envUrl || `ws://${window.location.hostname || 'localhost'}:8080/ws`;
};

// =============================================================================
// Hook
// =============================================================================

export function useRpc(): UseRpcReturn {
  const [status, setStatus] = useState<RpcConnectionStatus>('disconnected');
  const [sessionId, setSessionId] = useState<string | null>(null);
  const [error, setError] = useState<Error | null>(null);

  const clientRef = useRef<RpcClient | null>(null);
  const eventHandlersRef = useRef<Set<(event: RpcEvent) => void>>(new Set());

  // Initialize client on mount
  useEffect(() => {
    const client = new RpcClient(getWsUrl(), {
      autoReconnect: true,
      reconnectDelay: 1000,
      maxReconnectAttempts: 10,
    });

    // Set up connection handlers
    client.on('connected', () => {
      setStatus('connected');
      setError(null);
    });

    client.on('disconnected', () => {
      setStatus('disconnected');
    });

    client.on('reconnecting', (attempt) => {
      setStatus('reconnecting');
      console.log(`[RPC] Reconnecting attempt ${attempt}`);
    });

    client.on('error', (err) => {
      setStatus('error');
      setError(err);
    });

    // Forward all events to subscribers
    client.on('*', (event: RpcEvent) => {
      for (const handler of eventHandlersRef.current) {
        handler(event);
      }
    });

    clientRef.current = client;

    return () => {
      client.disconnect();
      clientRef.current = null;
    };
  }, []);

  // Connect
  const connect = useCallback(async () => {
    const client = clientRef.current;
    if (!client) return;

    setStatus('connecting');
    setError(null);

    try {
      await client.connect();
      setStatus('connected');
    } catch (err) {
      setStatus('error');
      setError(err instanceof Error ? err : new Error(String(err)));
    }
  }, []);

  // Disconnect
  const disconnect = useCallback(() => {
    clientRef.current?.disconnect();
    setStatus('disconnected');
    setSessionId(null);
  }, []);

  // Ensure session exists
  const ensureSession = useCallback(async (workingDirectory = '/project'): Promise<string> => {
    const client = clientRef.current;
    if (!client || !client.isConnected()) {
      throw new Error('Not connected');
    }

    // If we already have a session, return it
    if (sessionId) {
      return sessionId;
    }

    // Create a new session
    const result = await client.sessionCreate({ workingDirectory });
    setSessionId(result.sessionId);
    return result.sessionId;
  }, [sessionId]);

  // Send prompt
  const sendPrompt = useCallback(async (prompt: string): Promise<void> => {
    const client = clientRef.current;
    if (!client || !client.isConnected()) {
      throw new Error('Not connected');
    }

    // Ensure we have a session
    const currentSessionId = sessionId || await ensureSession();

    // Send the prompt
    await client.agentPrompt({
      sessionId: currentSessionId,
      prompt,
    });
  }, [sessionId, ensureSession]);

  // Abort
  const abort = useCallback(async (): Promise<void> => {
    const client = clientRef.current;
    if (!client || !client.isConnected() || !sessionId) {
      return;
    }

    await client.agentAbort({ sessionId });
  }, [sessionId]);

  // Switch model
  const switchModel = useCallback(async (modelId: string): Promise<{ previousModel: string; newModel: string }> => {
    const client = clientRef.current;
    if (!client || !client.isConnected()) {
      throw new Error('Not connected');
    }

    // Ensure we have a session
    const currentSessionId = sessionId || await ensureSession();

    // Switch the model
    const result = await client.modelSwitch({
      sessionId: currentSessionId,
      model: modelId,
    });

    return result;
  }, [sessionId, ensureSession]);

  // Subscribe to events
  const onEvent = useCallback((handler: (event: RpcEvent) => void): (() => void) => {
    eventHandlersRef.current.add(handler);
    return () => {
      eventHandlersRef.current.delete(handler);
    };
  }, []);

  return {
    status,
    sessionId,
    client: clientRef.current,
    connect,
    disconnect,
    ensureSession,
    sendPrompt,
    abort,
    switchModel,
    onEvent,
    error,
  };
}
