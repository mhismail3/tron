/**
 * @fileoverview Main App component for Tron Chat
 *
 * Integrates state management, layout, and RPC connection.
 */
import { useEffect, useState, useCallback, useMemo } from 'react';
import { ChatProvider, useChatDispatch, useChat } from './store/context.js';
import { AppShell, Sidebar, type SessionSummary } from './components/layout/index.js';
import { ChatArea } from './components/chat/ChatArea.js';
import { ConnectionStatus } from './components/ui/ConnectionStatus.js';
import { ModelSwitcher } from './components/overlay/index.js';
import { useRpc } from './hooks/useRpc.js';
import type { RpcEvent, ModelInfo } from '@tron/core/browser';
import type { Command } from './commands/index.js';

// =============================================================================
// Inner App (with access to chat context)
// =============================================================================

function AppContent() {
  const state = useChat();
  const dispatch = useChatDispatch();
  const {
    status,
    sessionId: rpcSessionId,
    connect,
    disconnect,
    sendPrompt,
    abort,
    switchModel,
    onEvent,
    error,
  } = useRpc();

  const [isOnline, setIsOnline] = useState(navigator.onLine);
  const [sidebarOpen, setSidebarOpen] = useState(true);
  const [modelSwitcherOpen, setModelSwitcherOpen] = useState(false);
  const [modelSwitching, setModelSwitching] = useState(false);

  // Detect mobile
  const [isMobile, setIsMobile] = useState(
    typeof window !== 'undefined' && window.innerWidth < 640
  );

  useEffect(() => {
    const handleResize = () => {
      const mobile = window.innerWidth < 640;
      setIsMobile(mobile);
      if (mobile) setSidebarOpen(false);
    };

    window.addEventListener('resize', handleResize);
    return () => window.removeEventListener('resize', handleResize);
  }, []);

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

  // Sync RPC session to state
  useEffect(() => {
    if (rpcSessionId && rpcSessionId !== state.sessionId) {
      dispatch({ type: 'SET_SESSION', payload: rpcSessionId });
      dispatch({ type: 'SET_INITIALIZED', payload: true });
    }
  }, [rpcSessionId, state.sessionId, dispatch]);

  // Subscribe to RPC events
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

        case 'agent.tool_start':
          // Finalize streaming content as a message
          if (state.streamingContent.trim()) {
            dispatch({
              type: 'ADD_MESSAGE',
              payload: {
                id: `msg_${Date.now()}`,
                role: 'assistant',
                content: state.streamingContent.trim(),
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

        case 'agent.tool_end':
          // Add tool result as a message
          if (data.toolName && typeof data.toolName === 'string') {
            dispatch({
              type: 'ADD_MESSAGE',
              payload: {
                id: `tool_${Date.now()}`,
                role: 'tool',
                content: (data.output as string) || (data.error as string) || '',
                timestamp: new Date().toISOString(),
                toolName: data.toolName,
                toolStatus: data.success ? 'success' : 'error',
                duration: data.duration as number,
              },
            });
          }
          dispatch({ type: 'SET_ACTIVE_TOOL', payload: null });
          dispatch({ type: 'SET_ACTIVE_TOOL_INPUT', payload: null });
          break;

        case 'agent.turn_end':
          // Finalize any remaining streaming content
          if (state.streamingContent.trim()) {
            dispatch({
              type: 'ADD_MESSAGE',
              payload: {
                id: `msg_${Date.now()}`,
                role: 'assistant',
                content: state.streamingContent.trim(),
                timestamp: new Date().toISOString(),
              },
            });
            dispatch({ type: 'CLEAR_STREAMING' });
          }
          break;

        case 'agent.complete':
          // Final cleanup
          if (state.streamingContent.trim()) {
            dispatch({
              type: 'ADD_MESSAGE',
              payload: {
                id: `msg_${Date.now()}`,
                role: 'assistant',
                content: state.streamingContent.trim(),
                timestamp: new Date().toISOString(),
              },
            });
            dispatch({ type: 'CLEAR_STREAMING' });
          }
          dispatch({ type: 'SET_PROCESSING', payload: false });
          dispatch({ type: 'SET_STREAMING', payload: false });
          dispatch({ type: 'SET_THINKING_TEXT', payload: '' });

          // Update token usage if provided
          const usage = data.tokenUsage as { input?: number; output?: number } | undefined;
          if (usage) {
            dispatch({
              type: 'SET_TOKEN_USAGE',
              payload: {
                input: (state.tokenUsage?.input || 0) + (usage.input || 0),
                output: (state.tokenUsage?.output || 0) + (usage.output || 0),
              },
            });
          }
          break;

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
  }, [onEvent, dispatch, state.streamingContent, state.tokenUsage]);

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

  // Handle message submission
  const handleSubmit = useCallback(
    async (message: string) => {
      try {
        await sendPrompt(message);
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
    [sendPrompt, dispatch]
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

  // Handle model selection
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

  // Session management - convert store sessions to Sidebar format
  const sessions = useMemo<SessionSummary[]>(() => {
    const activeSessionId = state.sessionId || rpcSessionId;
    if (activeSessionId) {
      return [
        {
          sessionId: activeSessionId,
          workingDirectory: '/project',
          model: state.currentModel,
          messageCount: state.messages.length,
          createdAt: new Date().toISOString(),
          lastActivity: new Date().toISOString(),
          isActive: true,
        },
      ];
    }
    return [];
  }, [state.sessionId, state.messages.length, state.currentModel, rpcSessionId]);

  const handleSessionSelect = useCallback(
    (_sessionId: string) => {
      // TODO: Implement session switching via RPC
    },
    []
  );

  const handleNewSession = useCallback(() => {
    // TODO: Create new session via RPC
    dispatch({ type: 'RESET' });
  }, [dispatch]);

  const handleSessionDelete = useCallback(
    (_sessionId: string) => {
      // TODO: Delete session via RPC
    },
    []
  );

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
    />
  );

  // Map RPC status to connection status component format
  const connectionStatus = status === 'connected' ? 'connected' :
                          status === 'connecting' || status === 'reconnecting' ? 'connecting' :
                          status === 'error' ? 'error' : 'disconnected';

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
      {connectionStatus !== 'connected' && (
        <ConnectionStatus
          status={connectionStatus}
          isOnline={isOnline}
          onRetry={connect}
        />
      )}

      {/* Error banner */}
      {error && (
        <div
          style={{
            padding: 'var(--space-sm) var(--space-md)',
            background: 'rgba(239, 68, 68, 0.15)',
            color: 'var(--error)',
            fontSize: 'var(--text-sm)',
            borderBottom: '1px solid var(--error)',
          }}
        >
          {error.message}
        </div>
      )}

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
