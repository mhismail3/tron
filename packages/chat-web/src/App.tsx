/**
 * @fileoverview Main App component for Tron Chat
 *
 * Integrates state management, layout, and RPC connection.
 * Supports multiple sessions with full persistence across page reloads.
 */
import { useEffect, useState, useCallback, useRef } from 'react';
import { ChatProvider, useChatDispatch, useChat } from './store/context.js';
import { AppShell, Sidebar, type SessionSummary } from './components/layout/index.js';
import { ChatArea } from './components/chat/ChatArea.js';
import { ModelSwitcher } from './components/overlay/index.js';
import { WorkspaceSelector } from './components/workspace/index.js';
import { WelcomePage } from './components/welcome/index.js';
import { useRpc } from './hooks/useRpc.js';
import { useKeyboardShortcuts } from './hooks/useKeyboardShortcuts.js';
import { useSessionPersistence } from './hooks/useSessionPersistence.js';
import type { RpcEvent, ModelInfo } from '@tron/core/browser';
import type { Command } from './commands/index.js';
import type { DisplayMessage, SessionSummary as StoreSessionSummary } from './store/types.js';

// =============================================================================
// Session State Cache (for multi-session support)
// =============================================================================

interface SessionCache {
  messages: DisplayMessage[];
  model: string;
  tokenUsage: { input: number; output: number };
  streamingContent: string;
  thinkingText: string;
  workingDirectory: string;
}

// =============================================================================
// Inner App (with access to chat context)
// =============================================================================

function AppContent() {
  const state = useChat();
  const dispatch = useChatDispatch();
  const {
    status,
    sessionId: rpcSessionId,
    client,
    connect,
    disconnect,
    createSession,
    deleteSession,
    resumeSession,
    sendPrompt,
    abort,
    switchModel,
    setSessionId: setRpcSessionId,
    onEvent,
    error,
  } = useRpc();

  const persistence = useSessionPersistence();

  const [isOnline, setIsOnline] = useState(navigator.onLine);
  const [sidebarOpen, setSidebarOpen] = useState(true);
  const [modelSwitcherOpen, setModelSwitcherOpen] = useState(false);
  const [modelSwitching, setModelSwitching] = useState(false);
  const [sessions, setSessions] = useState<SessionSummary[]>([]);
  const [workspaceSelectorOpen, setWorkspaceSelectorOpen] = useState(false);

  // Initialization state - prevents banner flashing
  const [appInitialized, setAppInitialized] = useState(false);
  const [connectionAttempted, setConnectionAttempted] = useState(false);

  // Session cache to store state when switching between sessions
  const sessionCacheRef = useRef<Map<string, SessionCache>>(new Map());

  // Detect mobile
  const [isMobile, setIsMobile] = useState(
    typeof window !== 'undefined' && window.innerWidth < 640
  );

  // Input ref for focus management
  const inputRef = useRef<HTMLTextAreaElement>(null);

  // Track if initial load has happened
  const initialLoadRef = useRef(false);

  useEffect(() => {
    const handleResize = () => {
      const mobile = window.innerWidth < 640;
      setIsMobile(mobile);
      if (mobile) setSidebarOpen(false);
    };

    window.addEventListener('resize', handleResize);
    return () => window.removeEventListener('resize', handleResize);
  }, []);

  // Load persisted sessions on mount
  useEffect(() => {
    if (initialLoadRef.current) return;
    initialLoadRef.current = true;

    const { sessions: persistedSessions, activeSessionId } = persistence.loadSessions();

    if (persistedSessions.length > 0) {
      // Convert to sidebar format
      const sidebarSessions: SessionSummary[] = persistedSessions.map((s) => ({
        sessionId: s.id,
        workingDirectory: s.workingDirectory || '/project',
        model: s.model || 'claude-opus-4-5-20251101',
        messageCount: s.messageCount || 0,
        createdAt: s.lastActivity,
        lastActivity: s.lastActivity,
        isActive: true,
      }));
      setSessions(sidebarSessions);

      // If there's an active session, load its state
      if (activeSessionId) {
        const sessionState = persistence.loadSessionState(activeSessionId);
        if (sessionState) {
          dispatch({ type: 'SET_SESSION', payload: activeSessionId });
          dispatch({ type: 'SET_CURRENT_MODEL', payload: sessionState.model });
          dispatch({ type: 'SET_TOKEN_USAGE', payload: sessionState.tokenUsage });
          dispatch({ type: 'SET_WORKING_DIRECTORY', payload: sessionState.workingDirectory || '/project' });
          dispatch({ type: 'SET_INITIALIZED', payload: true });

          // Load messages
          for (const msg of sessionState.messages) {
            dispatch({ type: 'ADD_MESSAGE', payload: msg });
          }

          // Pre-set the RPC session ID (it will be validated when connected)
          setRpcSessionId(activeSessionId);
        }
      }
    }
  }, [persistence, dispatch, setRpcSessionId]);

  // Handle online/offline events and initial connection
  useEffect(() => {
    const handleOnline = () => {
      setIsOnline(true);
      connect();
    };
    const handleOffline = () => setIsOnline(false);

    window.addEventListener('online', handleOnline);
    window.addEventListener('offline', handleOffline);

    // Initial connection attempt
    if (isOnline && !connectionAttempted) {
      setConnectionAttempted(true);
      connect().finally(() => {
        // Mark app as initialized after first connection attempt completes
        // (regardless of success/failure)
        setTimeout(() => setAppInitialized(true), 100);
      });
    } else if (!isOnline) {
      // If offline, still mark as initialized
      setAppInitialized(true);
    }

    return () => {
      window.removeEventListener('online', handleOnline);
      window.removeEventListener('offline', handleOffline);
      // Note: Don't call disconnect() here - useRpc manages its own connection lifecycle.
      // Calling disconnect here causes race conditions with React Strict Mode and
      // state changes (like setConnectionAttempted) that trigger effect re-runs.
    };
  }, [connect, isOnline, connectionAttempted]);

  // Sync RPC session to state when a new session is created
  useEffect(() => {
    if (rpcSessionId && rpcSessionId !== state.sessionId) {
      dispatch({ type: 'SET_SESSION', payload: rpcSessionId });
      dispatch({ type: 'SET_INITIALIZED', payload: true });
    }
  }, [rpcSessionId, state.sessionId, dispatch]);

  // Persist session state whenever messages change
  useEffect(() => {
    const sessionId = state.sessionId || rpcSessionId;
    if (sessionId && state.messages.length > 0) {
      persistence.saveSessionState(sessionId, {
        messages: state.messages,
        model: state.currentModel,
        tokenUsage: state.tokenUsage,
        workingDirectory: state.workingDirectory,
      });
    }
  }, [state.messages, state.currentModel, state.tokenUsage, state.workingDirectory, state.sessionId, rpcSessionId, persistence]);

  // Refs to avoid stale closures in event handlers
  const streamingContentRef = useRef(state.streamingContent);
  const tokenUsageRef = useRef(state.tokenUsage);
  const activeToolInputRef = useRef(state.activeToolInput);

  useEffect(() => {
    streamingContentRef.current = state.streamingContent;
  }, [state.streamingContent]);

  useEffect(() => {
    tokenUsageRef.current = state.tokenUsage;
  }, [state.tokenUsage]);

  useEffect(() => {
    activeToolInputRef.current = state.activeToolInput;
  }, [state.activeToolInput]);

  // Subscribe to RPC events (stable subscription - no re-subscribing on state changes)
  useEffect(() => {
    const unsubscribe = onEvent((event: RpcEvent) => {
      const data = event.data as Record<string, unknown>;

      switch (event.type) {
        case 'agent.turn_start':
          dispatch({ type: 'SET_PROCESSING', payload: true });
          dispatch({ type: 'SET_STREAMING', payload: true });
          dispatch({ type: 'CLEAR_STREAMING' });
          dispatch({ type: 'SET_THINKING_TEXT', payload: '' });
          break;

        case 'agent.text_delta':
          if (data.delta && typeof data.delta === 'string') {
            dispatch({
              type: 'APPEND_STREAMING_CONTENT',
              payload: data.delta,
            });
          }
          break;

        case 'agent.thinking_delta':
          if (data.delta && typeof data.delta === 'string') {
            dispatch({
              type: 'APPEND_THINKING_TEXT',
              payload: data.delta,
            });
          }
          break;

        case 'agent.tool_start': {
          // Finalize streaming content as a message
          const currentStreaming = streamingContentRef.current;
          if (currentStreaming.trim()) {
            dispatch({
              type: 'ADD_MESSAGE',
              payload: {
                id: `msg_${Date.now()}`,
                role: 'assistant',
                content: currentStreaming.trim(),
                timestamp: new Date().toISOString(),
              },
            });
            dispatch({ type: 'CLEAR_STREAMING' });
          }
          // Set active tool
          dispatch({
            type: 'SET_ACTIVE_TOOL',
            payload: (data.toolName as string) || 'unknown',
          });
          dispatch({
            type: 'SET_ACTIVE_TOOL_INPUT',
            payload: JSON.stringify(data.arguments ?? {}, null, 2),
          });
          break;
        }

        case 'agent.tool_end': {
          // Add tool result as a message
          const toolInput = activeToolInputRef.current; // Use ref to get current value
          if (data.toolName && typeof data.toolName === 'string') {
            dispatch({
              type: 'ADD_MESSAGE',
              payload: {
                id: `tool_${Date.now()}`,
                role: 'tool',
                content: (data.output as string) || (data.error as string) || '',
                timestamp: new Date().toISOString(),
                toolName: data.toolName,
                toolInput: toolInput || undefined,
                toolStatus: data.success ? 'success' : 'error',
                duration: data.duration as number,
              },
            });
          }
          dispatch({ type: 'SET_ACTIVE_TOOL', payload: null });
          dispatch({ type: 'SET_ACTIVE_TOOL_INPUT', payload: null });
          break;
        }

        case 'agent.turn_end': {
          // Turn ended - update token usage from this turn
          const turnUsage = data.tokenUsage as { inputTokens?: number; outputTokens?: number } | undefined;
          if (turnUsage) {
            const currentTokenUsage = tokenUsageRef.current;
            dispatch({
              type: 'SET_TOKEN_USAGE',
              payload: {
                input: (currentTokenUsage?.input || 0) + (turnUsage.inputTokens || 0),
                output: (currentTokenUsage?.output || 0) + (turnUsage.outputTokens || 0),
              },
            });
          }
          break;
        }

        case 'agent.complete': {
          // Final cleanup - finalize any remaining streaming content
          const currentStreaming = streamingContentRef.current;
          if (currentStreaming.trim()) {
            dispatch({
              type: 'ADD_MESSAGE',
              payload: {
                id: `msg_${Date.now()}`,
                role: 'assistant',
                content: currentStreaming.trim(),
                timestamp: new Date().toISOString(),
              },
            });
            dispatch({ type: 'CLEAR_STREAMING' });
          }
          dispatch({ type: 'SET_PROCESSING', payload: false });
          dispatch({ type: 'SET_STREAMING', payload: false });
          dispatch({ type: 'SET_THINKING_TEXT', payload: '' });
          break;
        }

        case 'agent.error':
          dispatch({
            type: 'ADD_MESSAGE',
            payload: {
              id: `error_${Date.now()}`,
              role: 'system',
              content: `Error: ${data.message || 'Unknown error occurred'}`,
              timestamp: new Date().toISOString(),
            },
          });
          dispatch({ type: 'SET_PROCESSING', payload: false });
          dispatch({ type: 'SET_STREAMING', payload: false });
          break;

        case 'session.created':
          dispatch({
            type: 'SET_SESSION',
            payload: data.sessionId as string,
          });
          dispatch({ type: 'SET_INITIALIZED', payload: true });
          break;
      }
    });

    return unsubscribe;
  }, [onEvent, dispatch]);

  // Update connection status in state
  useEffect(() => {
    const statusMap: Record<string, string> = {
      connected: 'idle',
      disconnected: 'disconnected',
      connecting: 'connecting',
      reconnecting: 'connecting',
      error: 'error',
    };
    dispatch({
      type: 'SET_STATUS',
      payload: statusMap[status] || status,
    });
  }, [status, dispatch]);

  // Save current session state to cache before switching
  const saveCurrentSessionToCache = useCallback(() => {
    const sessionId = state.sessionId || rpcSessionId;
    if (sessionId) {
      sessionCacheRef.current.set(sessionId, {
        messages: state.messages,
        model: state.currentModel,
        tokenUsage: state.tokenUsage,
        streamingContent: state.streamingContent,
        thinkingText: state.thinkingText,
        workingDirectory: state.workingDirectory,
      });
    }
  }, [state, rpcSessionId]);

  // Load session state from cache
  const loadSessionFromCache = useCallback(
    (sessionId: string) => {
      const cached = sessionCacheRef.current.get(sessionId);
      if (cached) {
        // Clear current messages
        dispatch({ type: 'RESET' });

        // Load cached state
        dispatch({ type: 'SET_SESSION', payload: sessionId });
        dispatch({ type: 'SET_CURRENT_MODEL', payload: cached.model });
        dispatch({ type: 'SET_TOKEN_USAGE', payload: cached.tokenUsage });
        dispatch({ type: 'SET_WORKING_DIRECTORY', payload: cached.workingDirectory });

        for (const msg of cached.messages) {
          dispatch({ type: 'ADD_MESSAGE', payload: msg });
        }

        return true;
      }

      // Try loading from persistence
      const persisted = persistence.loadSessionState(sessionId);
      if (persisted) {
        dispatch({ type: 'RESET' });
        dispatch({ type: 'SET_SESSION', payload: sessionId });
        dispatch({ type: 'SET_CURRENT_MODEL', payload: persisted.model });
        dispatch({ type: 'SET_TOKEN_USAGE', payload: persisted.tokenUsage });
        if (persisted.workingDirectory) {
          dispatch({ type: 'SET_WORKING_DIRECTORY', payload: persisted.workingDirectory });
        }

        for (const msg of persisted.messages) {
          dispatch({ type: 'ADD_MESSAGE', payload: msg });
        }

        return true;
      }

      return false;
    },
    [dispatch, persistence]
  );

  // Handle message submission
  const handleSubmit = useCallback(
    async (message: string) => {
      const sessionId = state.sessionId || rpcSessionId;

      // Add user message immediately
      dispatch({
        type: 'ADD_MESSAGE',
        payload: {
          id: `user_${Date.now()}`,
          role: 'user',
          content: message,
          timestamp: new Date().toISOString(),
        },
      });

      try {
        await sendPrompt(message, sessionId || undefined);
      } catch (err) {
        console.error('Failed to send message:', err);
        dispatch({
          type: 'ADD_MESSAGE',
          payload: {
            id: `error_${Date.now()}`,
            role: 'system',
            content: `Failed to send message: ${err instanceof Error ? err.message : 'Unknown error'}`,
            timestamp: new Date().toISOString(),
          },
        });
      }
    },
    [sendPrompt, dispatch, state.sessionId, rpcSessionId]
  );

  // Handle stop button
  const handleStop = useCallback(async () => {
    try {
      await abort();
      dispatch({ type: 'SET_PROCESSING', payload: false });
      dispatch({ type: 'SET_STREAMING', payload: false });
    } catch (err) {
      console.error('Failed to abort:', err);
    }
  }, [abort, dispatch]);

  // Handle model selection (from ModelSwitcher overlay)
  const handleModelSelect = useCallback(
    async (model: ModelInfo) => {
      setModelSwitching(true);
      try {
        const result = await switchModel(model.id);
        dispatch({ type: 'SET_CURRENT_MODEL', payload: result.newModel });
        dispatch({
          type: 'ADD_MESSAGE',
          payload: {
            id: `msg_${Date.now()}`,
            role: 'system',
            content: `Switched model: ${result.previousModel} \u2192 ${result.newModel}`,
            timestamp: new Date().toISOString(),
          },
        });
        setModelSwitcherOpen(false);
      } catch (err) {
        console.error('Failed to switch model:', err);
        dispatch({
          type: 'ADD_MESSAGE',
          payload: {
            id: `error_${Date.now()}`,
            role: 'system',
            content: `Failed to switch model: ${err instanceof Error ? err.message : 'Unknown error'}`,
            timestamp: new Date().toISOString(),
          },
        });
      } finally {
        setModelSwitching(false);
      }
    },
    [switchModel, dispatch]
  );

  // Handle model change from StatusBar dropdown
  const handleModelChange = useCallback(
    async (modelId: string) => {
      try {
        const result = await switchModel(modelId);
        dispatch({ type: 'SET_CURRENT_MODEL', payload: result.newModel });
      } catch (err) {
        console.error('Failed to switch model:', err);
        dispatch({
          type: 'ADD_MESSAGE',
          payload: {
            id: `error_${Date.now()}`,
            role: 'system',
            content: `Failed to switch model: ${err instanceof Error ? err.message : 'Unknown error'}`,
            timestamp: new Date().toISOString(),
          },
        });
      }
    },
    [switchModel, dispatch]
  );

  // Handle command execution
  const handleCommand = useCallback(
    (command: Command, _args: string[]) => {
      switch (command.name) {
        case 'clear':
          dispatch({ type: 'RESET' });
          break;

        case 'model':
          setModelSwitcherOpen(true);
          break;

        case 'help':
          dispatch({
            type: 'ADD_MESSAGE',
            payload: {
              id: `msg_${Date.now()}`,
              role: 'system',
              content:
                'Available commands:\n' +
                '/help - Show this help\n' +
                '/model - Switch AI model\n' +
                '/clear - Clear messages\n' +
                '/session - Show session info\n' +
                '/history - Show history count\n' +
                '/context - Show loaded context',
              timestamp: new Date().toISOString(),
            },
          });
          break;

        case 'session':
          dispatch({
            type: 'ADD_MESSAGE',
            payload: {
              id: `msg_${Date.now()}`,
              role: 'system',
              content: `Session: ${state.sessionId || rpcSessionId || 'Not created'}\nModel: ${state.currentModel}`,
              timestamp: new Date().toISOString(),
            },
          });
          break;

        case 'history':
          dispatch({
            type: 'ADD_MESSAGE',
            payload: {
              id: `msg_${Date.now()}`,
              role: 'system',
              content: `Message history: ${state.messages.length} messages`,
              timestamp: new Date().toISOString(),
            },
          });
          break;

        default:
          dispatch({
            type: 'ADD_MESSAGE',
            payload: {
              id: `msg_${Date.now()}`,
              role: 'system',
              content: `Command /${command.name} not yet implemented`,
              timestamp: new Date().toISOString(),
            },
          });
      }
    },
    [dispatch, state.sessionId, state.currentModel, state.messages.length, rpcSessionId]
  );

  // Handle session selection (switching)
  const handleSessionSelect = useCallback(
    async (sessionId: string) => {
      const currentSessionId = state.sessionId || rpcSessionId;
      if (sessionId === currentSessionId) return;

      // Save current session state
      saveCurrentSessionToCache();

      // Load the selected session
      loadSessionFromCache(sessionId);

      // Update RPC session
      setRpcSessionId(sessionId);

      // Update persistence
      persistence.setActiveSession(sessionId);

      // Try to resume the session with the server
      if (status === 'connected') {
        try {
          await resumeSession(sessionId);
        } catch (err) {
          console.warn('Failed to resume session with server:', err);
          // Session might not exist on server yet - that's okay for locally persisted sessions
        }
      }
    },
    [
      state.sessionId,
      rpcSessionId,
      saveCurrentSessionToCache,
      loadSessionFromCache,
      setRpcSessionId,
      persistence,
      status,
      resumeSession,
    ]
  );

  // Handle new session creation - opens workspace selector
  const handleNewSession = useCallback(() => {
    // Open workspace selector to choose directory
    setWorkspaceSelectorOpen(true);
  }, []);

  // Handle workspace selection - creates the actual session
  const handleWorkspaceSelect = useCallback(async (workingDirectory: string) => {
    setWorkspaceSelectorOpen(false);

    // Save current session state first
    saveCurrentSessionToCache();

    // Reset UI state for new session
    dispatch({ type: 'RESET' });
    // Set working directory for the new session
    dispatch({ type: 'SET_WORKING_DIRECTORY', payload: workingDirectory });

    const now = new Date().toISOString();

    try {
      // Create new session via RPC if connected
      if (status === 'connected') {
        const newSessionId = await createSession(workingDirectory, state.currentModel);

        // Create session summary
        const newSession: SessionSummary = {
          sessionId: newSessionId,
          workingDirectory,
          model: state.currentModel,
          messageCount: 0,
          createdAt: now,
          lastActivity: now,
          isActive: true,
        };

        // Update sessions list
        setSessions((prev) => [...prev, newSession]);

        // Save to persistence
        const storeSession: StoreSessionSummary = {
          id: newSessionId,
          title: workingDirectory.split('/').pop() || 'New Session',
          lastActivity: now,
          model: state.currentModel,
          messageCount: 0,
          workingDirectory,
        };
        persistence.saveSession(storeSession);
        persistence.setActiveSession(newSessionId);

        // Update state
        dispatch({ type: 'SET_SESSION', payload: newSessionId });
        dispatch({ type: 'SET_INITIALIZED', payload: true });
      } else {
        // Create local-only session if not connected
        const localSessionId = `local_${Date.now()}`;

        const newSession: SessionSummary = {
          sessionId: localSessionId,
          workingDirectory,
          model: state.currentModel,
          messageCount: 0,
          createdAt: now,
          lastActivity: now,
          isActive: true,
        };

        setSessions((prev) => [...prev, newSession]);

        const storeSession: StoreSessionSummary = {
          id: localSessionId,
          title: workingDirectory.split('/').pop() || 'New Session',
          lastActivity: now,
          model: state.currentModel,
          messageCount: 0,
          workingDirectory,
        };
        persistence.saveSession(storeSession);
        persistence.setActiveSession(localSessionId);

        dispatch({ type: 'SET_SESSION', payload: localSessionId });
        dispatch({ type: 'SET_INITIALIZED', payload: true });
      }
    } catch (err) {
      console.error('Failed to create session:', err);
      dispatch({
        type: 'ADD_MESSAGE',
        payload: {
          id: `error_${Date.now()}`,
          role: 'system',
          content: `Failed to create session: ${err instanceof Error ? err.message : 'Unknown error'}`,
          timestamp: new Date().toISOString(),
        },
      });
    }
  }, [
    saveCurrentSessionToCache,
    dispatch,
    status,
    createSession,
    state.currentModel,
    persistence,
  ]);

  // Handle session deletion
  const handleSessionDelete = useCallback(
    async (sessionId: string) => {
      try {
        // Abort any ongoing processing for this session
        if (state.isProcessing && (state.sessionId === sessionId || rpcSessionId === sessionId)) {
          await abort(sessionId);
        }

        // Delete from server if connected
        if (status === 'connected') {
          try {
            await deleteSession(sessionId);
          } catch (err) {
            console.warn('Failed to delete session from server:', err);
            // Continue with local deletion even if server deletion fails
          }
        }

        // Remove from local state
        setSessions((prev) => prev.filter((s) => s.sessionId !== sessionId));

        // Remove from persistence
        persistence.removeSession(sessionId);

        // Remove from cache
        sessionCacheRef.current.delete(sessionId);

        // If this was the active session, switch to another or create new
        const currentSessionId = state.sessionId || rpcSessionId;
        if (sessionId === currentSessionId) {
          dispatch({ type: 'RESET' });
          setRpcSessionId(null);

          // Switch to another session if available
          const remainingSessions = sessions.filter((s) => s.sessionId !== sessionId);
          if (remainingSessions.length > 0) {
            const nextSession = remainingSessions[0]!;
            loadSessionFromCache(nextSession.sessionId);
            setRpcSessionId(nextSession.sessionId);
            persistence.setActiveSession(nextSession.sessionId);
          }
        }
      } catch (err) {
        console.error('Failed to delete session:', err);
        dispatch({
          type: 'ADD_MESSAGE',
          payload: {
            id: `error_${Date.now()}`,
            role: 'system',
            content: `Failed to delete session: ${err instanceof Error ? err.message : 'Unknown error'}`,
            timestamp: new Date().toISOString(),
          },
        });
      }
    },
    [
      state.isProcessing,
      state.sessionId,
      rpcSessionId,
      abort,
      status,
      deleteSession,
      persistence,
      sessions,
      dispatch,
      setRpcSessionId,
      loadSessionFromCache,
    ]
  );

  // Global keyboard shortcuts
  useKeyboardShortcuts({
    enabled: true,
    shortcuts: {
      onOpenCommandPalette: () => {
        // Focus input and type / to open command palette
        if (inputRef.current) {
          inputRef.current.focus();
          dispatch({ type: 'SET_INPUT', payload: '/' });
        }
      },
      onEscape: () => {
        if (modelSwitcherOpen) {
          setModelSwitcherOpen(false);
        } else if (state.isProcessing) {
          abort();
        }
      },
      onFocusInput: () => {
        inputRef.current?.focus();
      },
      onNewSession: handleNewSession,
    },
  });

  // Sidebar component
  const sidebar = (
    <Sidebar
      sessions={sessions}
      activeSessionId={state.sessionId || rpcSessionId || undefined}
      onSessionSelect={handleSessionSelect}
      onNewSession={handleNewSession}
      onSessionDelete={handleSessionDelete}
      collapsed={!sidebarOpen}
    />
  );

  // Main chat area with stop handler
  const main = (
    <ChatArea
      onSubmit={handleSubmit}
      onCommand={handleCommand}
      onStop={handleStop}
      onModelChange={handleModelChange}
    />
  );

  // Map RPC status to connection status component format
  const connectionStatus =
    status === 'connected'
      ? 'connected'
      : status === 'connecting' || status === 'reconnecting'
        ? 'connecting'
        : status === 'error'
          ? 'error'
          : 'disconnected';

  // Determine if we have sessions
  const hasSessions = sessions.length > 0;

  // Show welcome page if no sessions exist
  if (!hasSessions) {
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
        <WelcomePage
          onNewSession={handleNewSession}
          connectionStatus={connectionStatus}
          isInitializing={!appInitialized}
        />

        {/* Workspace Selector (for creating first session) */}
        <WorkspaceSelector
          isOpen={workspaceSelectorOpen}
          onSelect={handleWorkspaceSelect}
          onClose={() => setWorkspaceSelectorOpen(false)}
          client={client}
          connectionStatus={status}
        />
      </div>
    );
  }

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
      {/* Main layout */}
      <AppShell
        sidebar={sidebar}
        main={main}
        sidebarOpen={sidebarOpen}
        onSidebarToggle={() => setSidebarOpen((prev) => !prev)}
        isMobile={isMobile}
      />

      {/* Model Switcher Overlay */}
      <ModelSwitcher
        open={modelSwitcherOpen}
        currentModel={state.currentModel}
        onClose={() => setModelSwitcherOpen(false)}
        onSelect={handleModelSelect}
        loading={modelSwitching}
      />

      {/* Workspace Selector */}
      <WorkspaceSelector
        isOpen={workspaceSelectorOpen}
        onSelect={handleWorkspaceSelect}
        onClose={() => setWorkspaceSelectorOpen(false)}
        client={client}
        connectionStatus={status}
      />
    </div>
  );
}

// =============================================================================
// Main App (provides context)
// =============================================================================

export function App() {
  return (
    <ChatProvider>
      <AppContent />
    </ChatProvider>
  );
}
