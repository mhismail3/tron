/**
 * @fileoverview ChatArea Component
 *
 * Main chat area integrating MessageList, InputBar, and CommandPalette.
 * Handles input processing, command detection, and message submission.
 */

import { useState, useCallback, useRef, useEffect } from 'react';
import { useChat, useChatDispatch } from '../../store/context.js';
import { MessageList } from './MessageList.js';
import { InputBar } from './InputBar.js';
import { StatusBar } from './StatusBar.js';
import { SessionHistoryPanel } from './SessionHistoryPanel.js';
import { SessionBrowser } from '../session/SessionBrowser.js';
import { CommandPalette } from '../overlay/CommandPalette.js';
import { useSessionHistory } from '../../hooks/index.js';
import { isCommand, parseCommand, findCommand } from '../../commands/index.js';
import type { Command } from '../../commands/index.js';
import type { SessionSummary } from '../../store/types.js';
import './ChatArea.css';

// =============================================================================
// Types
// =============================================================================

export interface ChatAreaProps {
  /** Called when user submits a message */
  onSubmit?: (message: string) => void;
  /** Called when command is executed */
  onCommand?: (command: Command, args: string[]) => void;
  /** Called when user requests to stop processing */
  onStop?: () => void;
  /** Called when user changes the model */
  onModelChange?: (model: string) => void;
  /** RPC call function for server communication */
  rpcCall?: <T>(method: string, params?: unknown) => Promise<T>;
  /** Called when user forks to a new session */
  onSessionChange?: (sessionId: string) => void;
}

// =============================================================================
// Component
// =============================================================================

// Context window sizes by model (approximate)
const MODEL_CONTEXT_SIZES: Record<string, number> = {
  'claude-opus-4-5-20251101': 200000,
  'claude-sonnet-4-20250514': 200000,
  'claude-3-5-sonnet-20241022': 200000,
  'claude-3-5-haiku-20241022': 200000,
  'claude-3-opus-20240229': 200000,
  'claude-3-sonnet-20240229': 200000,
  'claude-3-haiku-20240307': 200000,
};

export function ChatArea({ onSubmit, onCommand, onStop, onModelChange, rpcCall, onSessionChange }: ChatAreaProps) {
  const state = useChat();
  const dispatch = useChatDispatch();

  // Calculate context usage percentage
  const totalTokens = (state.tokenUsage?.input ?? 0) + (state.tokenUsage?.output ?? 0);
  const contextSize = MODEL_CONTEXT_SIZES[state.currentModel] ?? 200000;
  const contextPercent = Math.round((totalTokens / contextSize) * 100);

  const [showCommandPalette, setShowCommandPalette] = useState(false);
  const [showHistoryPanel, setShowHistoryPanel] = useState(false);
  const [showSessionBrowser, setShowSessionBrowser] = useState(false);
  const [pastSessions, setPastSessions] = useState<SessionSummary[]>([]);
  const [commandQuery, setCommandQuery] = useState('');
  const inputRef = useRef<HTMLTextAreaElement>(null);

  // Session history hook - only active if we have rpcCall
  const noopRpcCall = useCallback(
    async <T,>(): Promise<T> => ({ events: [], hasMore: false }) as T,
    []
  );
  const sessionHistory = useSessionHistory({
    sessionId: state.sessionId,
    rpcCall: rpcCall ?? noopRpcCall,
    headEventId: state.headEventId ?? null,
    includeBranches: showHistoryPanel,
  });

  // Handle fork
  const handleFork = useCallback(
    async (eventId: string) => {
      const result = await sessionHistory.fork(eventId);
      if (result?.newSessionId) {
        onSessionChange?.(result.newSessionId);
        setShowHistoryPanel(false);
      }
    },
    [sessionHistory, onSessionChange]
  );

  // Handle rewind
  const handleRewind = useCallback(
    async (eventId: string) => {
      const success = await sessionHistory.rewind(eventId);
      if (success) {
        // Refresh the messages after rewind
        dispatch({ type: 'REWIND_TO_EVENT', payload: eventId });
        setShowHistoryPanel(false);
      }
    },
    [sessionHistory, dispatch]
  );

  // Fetch past sessions when browser is opened
  useEffect(() => {
    if (showSessionBrowser && rpcCall) {
      rpcCall<{ sessions: Array<{
        sessionId: string;
        workingDirectory: string;
        model: string;
        messageCount: number;
        createdAt: string;
        lastActivity: string;
        isActive: boolean;
        title?: string;
      }> }>('session.list', { includeEnded: true, limit: 100 })
        .then((result) => {
          const sessions: SessionSummary[] = result.sessions.map((s) => ({
            id: s.sessionId,
            title: s.title || `Session ${s.sessionId.slice(0, 8)}`,
            workingDirectory: s.workingDirectory,
            model: s.model,
            messageCount: s.messageCount,
            lastActivity: s.lastActivity,
          }));
          setPastSessions(sessions);
        })
        .catch((err) => {
          console.error('[ChatArea] Failed to fetch sessions:', err);
        });
    }
  }, [showSessionBrowser, rpcCall]);

  // Handle session selection from browser (just display, not fork)
  const handleSelectSession = useCallback((_sessionId: string) => {
    // Just selecting to view history - no action needed
  }, []);

  // Handle fork from past session
  const handleForkFromPastSession = useCallback(
    async (sessionId: string, eventId: string) => {
      if (!rpcCall) return;

      try {
        const result = await rpcCall<{
          newSessionId: string;
          rootEventId: string;
        }>('session.fork', {
          sessionId,
          fromEventId: eventId,
        });

        if (result.newSessionId) {
          onSessionChange?.(result.newSessionId);
          setShowSessionBrowser(false);
        }
      } catch (err) {
        console.error('[ChatArea] Failed to fork session:', err);
      }
    },
    [rpcCall, onSessionChange]
  );

  // Handle input changes - detect slash commands
  const handleInputChange = useCallback((value: string) => {
    dispatch({ type: 'SET_INPUT', payload: value });

    // Open command palette when typing /
    if (value === '/') {
      setCommandQuery('');
      setShowCommandPalette(true);
    } else if (value.startsWith('/') && !value.includes(' ')) {
      // Continue filtering as user types command name
      setCommandQuery(value.slice(1));
      setShowCommandPalette(true);
    }
  }, [dispatch]);

  // Handle message submission
  const handleSubmit = useCallback(() => {
    const input = state.input.trim();
    if (!input) return;

    // Check if it's a command
    if (isCommand(input)) {
      const parsed = parseCommand(input);
      if (parsed) {
        const command = findCommand(parsed.name);
        if (command) {
          // Execute command
          onCommand?.(command, parsed.args);
          dispatch({ type: 'SET_INPUT', payload: '' });
          return;
        }
      }
      // Unknown command - show error
      dispatch({
        type: 'ADD_MESSAGE',
        payload: {
          id: `msg_${Date.now()}`,
          role: 'system',
          content: `Unknown command: ${input}. Type /help for available commands.`,
          timestamp: new Date().toISOString(),
        },
      });
      dispatch({ type: 'SET_INPUT', payload: '' });
      return;
    }

    // Regular message - submit (parent will add to messages)
    dispatch({ type: 'SET_INPUT', payload: '' });
    onSubmit?.(input);
  }, [state.input, dispatch, onSubmit, onCommand]);

  // Handle command selection from palette
  const handleCommandSelect = useCallback(
    (command: Command) => {
      // If command has options (like model switcher), we need a submenu
      // For now, just execute the command
      onCommand?.(command, []);
      dispatch({ type: 'SET_INPUT', payload: '' });
      setShowCommandPalette(false);
    },
    [dispatch, onCommand],
  );

  // Handle command palette close
  const handleCommandPaletteClose = useCallback(() => {
    setShowCommandPalette(false);
    // Keep focus on input
    inputRef.current?.focus();
  }, []);

  // Handle keyboard shortcuts
  const handleKeyDown = useCallback(
    (e: React.KeyboardEvent) => {
      // Ctrl+K or Ctrl+/ to open command palette
      if ((e.ctrlKey || e.metaKey) && (e.key === 'k' || e.key === '/')) {
        e.preventDefault();
        setCommandQuery('');
        setShowCommandPalette(true);
        return;
      }

      // Escape to cancel/interrupt
      if (e.key === 'Escape') {
        if (state.isProcessing && onStop) {
          onStop();
        }
      }
    },
    [state.isProcessing, onStop],
  );

  // Focus input on mount
  useEffect(() => {
    inputRef.current?.focus();
  }, []);

  // Handle escape key from InputBar
  const handleEscape = useCallback(() => {
    if (showCommandPalette) {
      setShowCommandPalette(false);
    } else if (state.isProcessing && onStop) {
      onStop();
    }
  }, [showCommandPalette, state.isProcessing, onStop]);

  // Handle slash command detection from InputBar
  const handleSlashCommand = useCallback((partial: string) => {
    setCommandQuery(partial.slice(1)); // Remove leading /
    setShowCommandPalette(true);
  }, []);

  return (
    <div className="chat-area" onKeyDown={handleKeyDown}>
      {/* Messages */}
      <div className="chat-area-messages">
        <MessageList
          messages={state.messages}
          isProcessing={state.isProcessing}
          activeTool={state.activeTool}
          activeToolInput={state.activeToolInput}
          streamingContent={state.streamingContent}
          isStreaming={state.isStreaming}
          thinkingText={state.thinkingText}
        />
      </div>

      {/* Input */}
      <div className="chat-area-input">
        <InputBar
          ref={inputRef}
          value={state.input}
          onChange={handleInputChange}
          onSubmit={handleSubmit}
          onStop={onStop}
          onSlashCommand={handleSlashCommand}
          onEscape={handleEscape}
          isProcessing={state.isProcessing}
          commandPaletteOpen={showCommandPalette}
          placeholder={
            state.isProcessing
              ? 'Processing...'
              : 'Type a message or / for commands'
          }
        />
        <StatusBar
          status={state.status as 'idle' | 'processing' | 'error' | 'connected'}
          model={state.currentModel}
          workingDirectory={state.workingDirectory}
          tokenUsage={state.tokenUsage}
          contextPercent={contextPercent}
          onModelChange={onModelChange}
          eventCount={sessionHistory.events.length}
          branchCount={sessionHistory.branchCount}
          onHistoryClick={rpcCall ? () => setShowHistoryPanel(true) : undefined}
          onBrowseSessionsClick={rpcCall ? () => setShowSessionBrowser(true) : undefined}
        />
      </div>

      {/* Command Palette Overlay */}
      <CommandPalette
        open={showCommandPalette}
        onClose={handleCommandPaletteClose}
        onSelect={handleCommandSelect}
        initialQuery={commandQuery}
      />

      {/* Session History Panel */}
      <SessionHistoryPanel
        isOpen={showHistoryPanel}
        onClose={() => setShowHistoryPanel(false)}
        events={sessionHistory.events}
        headEventId={sessionHistory.headEventId}
        sessionId={state.sessionId}
        onFork={handleFork}
        onRewind={handleRewind}
        isLoading={sessionHistory.isLoading}
      />

      {/* Session Browser for past sessions */}
      <SessionBrowser
        isOpen={showSessionBrowser}
        onClose={() => setShowSessionBrowser(false)}
        sessions={pastSessions}
        rpcCall={rpcCall ?? noopRpcCall}
        onSelectSession={handleSelectSession}
        onForkFromEvent={handleForkFromPastSession}
        currentSessionId={state.sessionId ?? undefined}
      />
    </div>
  );
}
