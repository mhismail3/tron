/**
 * @fileoverview React hook for RPC client
 *
 * Provides typed RPC communication with automatic session management.
 */

import { useState, useEffect, useCallback, useRef } from 'react';
import { RpcClient } from '../rpc/client.js';
import type { RpcEvent, SessionListResult, ModelListResult } from '@tron/core/browser';

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
  /** Create a new session */
  createSession: (workingDirectory?: string, model?: string) => Promise<string>;
  /** Resume an existing session */
  resumeSession: (sessionId: string) => Promise<string>;
  /** Create or resume a session (legacy, uses current sessionId) */
  ensureSession: (workingDirectory?: string) => Promise<string>;
  /** Send a prompt to the agent */
  sendPrompt: (prompt: string, targetSessionId?: string) => Promise<void>;
  /** Abort current agent run */
  abort: (targetSessionId?: string) => Promise<void>;
  /** Switch to a different model */
  switchModel: (modelId: string, targetSessionId?: string) => Promise<{ previousModel: string; newModel: string }>;
  /** Delete/close a session */
  deleteSession: (targetSessionId: string) => Promise<boolean>;
  /** List all sessions from server */
  listSessions: () => Promise<SessionListResult>;
  /** List available models */
  listModels: () => Promise<ModelListResult>;
  /** Set current session ID */
  setSessionId: (sessionId: string | null) => void;
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
  const [sessionId, setSessionIdState] = useState<string | null>(null);
  const [error, setError] = useState<Error | null>(null);

  const clientRef = useRef<RpcClient | null>(null);
  const eventHandlersRef = useRef<Set<(event: RpcEvent) => void>>(new Set());

  // Initialize client on mount
  useEffect(() => {
    const rpcClient = new RpcClient(getWsUrl(), {
      autoReconnect: true,
      reconnectDelay: 1000,
      maxReconnectAttempts: 10,
    });

    // Set up connection handlers
    rpcClient.on('connected', () => {
      console.log('[useRpc] EVENT: connected, socket.readyState=%s', rpcClient.isConnected());
      setStatus('connected');
      setError(null);
    });

    rpcClient.on('disconnected', () => {
      console.log('[useRpc] EVENT: disconnected');
      setStatus('disconnected');
    });

    rpcClient.on('reconnecting', (attempt) => {
      console.log(`[useRpc] EVENT: reconnecting attempt ${attempt}`);
      setStatus('reconnecting');
    });

    rpcClient.on('error', (err) => {
      console.log('[useRpc] EVENT: error', err);
      setStatus('error');
      setError(err);
    });

    // Forward all events to subscribers
    rpcClient.on('*', (event: RpcEvent) => {
      for (const handler of eventHandlersRef.current) {
        handler(event);
      }
    });

    clientRef.current = rpcClient;
    // Note: setClient is called in 'connected' handler to ensure client.isConnected() works

    // Auto-connect on mount
    console.log('[useRpc] Starting auto-connect to', rpcClient.getUrl());
    rpcClient.connect()
      .then(() => {
        console.log('[useRpc] Auto-connect succeeded, isConnected=%s', rpcClient.isConnected());
      })
      .catch((err) => {
        console.error('[useRpc] Auto-connect FAILED:', err);
      });

    return () => {
      rpcClient.disconnect();
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
    setSessionIdState(null);
  }, []);

  // Create a new session
  const createSession = useCallback(
    async (workingDirectory = '/project', model?: string): Promise<string> => {
      const client = clientRef.current;
      if (!client || !client.isConnected()) {
        throw new Error('Not connected');
      }

      const result = await client.sessionCreate({ workingDirectory, model });
      setSessionIdState(result.sessionId);
      return result.sessionId;
    },
    []
  );

  // Resume an existing session
  const resumeSession = useCallback(async (targetSessionId: string): Promise<string> => {
    const client = clientRef.current;
    if (!client || !client.isConnected()) {
      throw new Error('Not connected');
    }

    const result = await client.sessionResume({ sessionId: targetSessionId });
    setSessionIdState(result.sessionId);
    return result.sessionId;
  }, []);

  // Ensure session exists (legacy compatibility)
  const ensureSession = useCallback(
    async (workingDirectory = '/project'): Promise<string> => {
      const client = clientRef.current;
      if (!client || !client.isConnected()) {
        throw new Error('Not connected');
      }

      // If we already have a session, return it
      if (sessionId) {
        return sessionId;
      }

      // Create a new session
      return createSession(workingDirectory);
    },
    [sessionId, createSession]
  );

  // Send prompt
  const sendPrompt = useCallback(
    async (prompt: string, targetSessionId?: string): Promise<void> => {
      const client = clientRef.current;
      if (!client || !client.isConnected()) {
        throw new Error('Not connected');
      }

      // Use provided session or current session
      const effectiveSessionId = targetSessionId || sessionId || (await ensureSession());

      // Send the prompt
      await client.agentPrompt({
        sessionId: effectiveSessionId,
        prompt,
      });
    },
    [sessionId, ensureSession]
  );

  // Abort
  const abort = useCallback(
    async (targetSessionId?: string): Promise<void> => {
      const client = clientRef.current;
      if (!client || !client.isConnected()) {
        return;
      }

      const effectiveSessionId = targetSessionId || sessionId;
      if (!effectiveSessionId) return;

      await client.agentAbort({ sessionId: effectiveSessionId });
    },
    [sessionId]
  );

  // Switch model
  const switchModel = useCallback(
    async (
      modelId: string,
      targetSessionId?: string
    ): Promise<{ previousModel: string; newModel: string }> => {
      const client = clientRef.current;
      if (!client || !client.isConnected()) {
        throw new Error('Not connected');
      }

      // Use provided session or current session
      const effectiveSessionId = targetSessionId || sessionId || (await ensureSession());

      // Switch the model
      const result = await client.modelSwitch({
        sessionId: effectiveSessionId,
        model: modelId,
      });

      return result;
    },
    [sessionId, ensureSession]
  );

  // Delete/close a session
  const deleteSession = useCallback(async (targetSessionId: string): Promise<boolean> => {
    const client = clientRef.current;
    if (!client || !client.isConnected()) {
      throw new Error('Not connected');
    }

    const result = await client.sessionDelete({ sessionId: targetSessionId });

    // If we deleted the current session, clear the sessionId
    if (targetSessionId === sessionId) {
      setSessionIdState(null);
    }

    return result.deleted;
  }, [sessionId]);

  // List sessions from server
  const listSessions = useCallback(async (): Promise<SessionListResult> => {
    const client = clientRef.current;
    if (!client || !client.isConnected()) {
      throw new Error('Not connected');
    }

    return client.sessionList({ includeEnded: false });
  }, []);

  // List available models
  const listModels = useCallback(async (): Promise<ModelListResult> => {
    const client = clientRef.current;
    if (!client || !client.isConnected()) {
      throw new Error('Not connected');
    }

    return client.modelList();
  }, []);

  // Set session ID manually (for switching between sessions)
  const setSessionId = useCallback((newSessionId: string | null) => {
    setSessionIdState(newSessionId);
  }, []);

  // Subscribe to events
  const onEvent = useCallback((handler: (event: RpcEvent) => void): (() => void) => {
    eventHandlersRef.current.add(handler);
    return () => {
      eventHandlersRef.current.delete(handler);
    };
  }, []);

  // Return clientRef.current directly - the status change will trigger re-render
  // and by that time clientRef.current will have the connected client
  return {
    status,
    sessionId,
    client: clientRef.current,
    connect,
    disconnect,
    createSession,
    resumeSession,
    ensureSession,
    sendPrompt,
    abort,
    switchModel,
    deleteSession,
    listSessions,
    listModels,
    setSessionId,
    onEvent,
    error,
  };
}
