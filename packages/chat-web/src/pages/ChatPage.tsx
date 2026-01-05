/**
 * @fileoverview Main chat page component
 */
import React, { useState, useEffect, useRef, useCallback } from 'react';
import { MessageBubble, type Message } from '../components/chat/MessageBubble.js';
import { InputBar } from '../components/chat/InputBar.js';
import { StatusBar } from '../components/chat/StatusBar.js';
import { useWebSocket } from '../hooks/useWebSocket.js';

export function ChatPage(): React.ReactElement {
  const [messages, setMessages] = useState<Message[]>([]);
  const [isProcessing, setIsProcessing] = useState(false);
  const [streamingContent, setStreamingContent] = useState('');
  const [currentStreamingId, setCurrentStreamingId] = useState<string | null>(null);
  const [tokenUsage, setTokenUsage] = useState({ input: 0, output: 0 });
  const messagesEndRef = useRef<HTMLDivElement>(null);
  const messageIdCounter = useRef(0);
  const { send, subscribe, status } = useWebSocket();

  // Auto-scroll to bottom when new messages arrive
  const scrollToBottom = useCallback(() => {
    messagesEndRef.current?.scrollIntoView({ behavior: 'smooth' });
  }, []);

  useEffect(() => {
    scrollToBottom();
  }, [messages, streamingContent, scrollToBottom]);

  // Subscribe to WebSocket messages
  useEffect(() => {
    const unsubscribe = subscribe((msg) => {
      switch (msg.type) {
        case 'turn_start':
          setIsProcessing(true);
          setStreamingContent('');
          setCurrentStreamingId(`msg_${messageIdCounter.current++}`);
          break;

        case 'message_update':
          if (msg.content && typeof msg.content === 'string') {
            setStreamingContent((prev) => prev + msg.content);
          }
          break;

        case 'tool_execution_start':
          // Finalize streaming content as a message
          if (streamingContent.trim()) {
            const newMsg: Message = {
              id: currentStreamingId || `msg_${messageIdCounter.current++}`,
              role: 'assistant',
              content: streamingContent.trim(),
              timestamp: new Date().toISOString(),
            };
            setMessages((prev) => [...prev, newMsg]);
            setStreamingContent('');
          }
          break;

        case 'tool_execution_end':
          // Add tool result as a message with tool call info
          if (msg.toolName && typeof msg.toolName === 'string') {
            const toolMsg: Message = {
              id: `tool_${messageIdCounter.current++}`,
              role: 'assistant',
              content: '',
              timestamp: new Date().toISOString(),
              toolCalls: [
                {
                  id: (msg.toolCallId as string) || `tool_${Date.now()}`,
                  name: msg.toolName,
                  status: msg.isError ? 'error' : 'success',
                  input: msg.toolInput as string,
                  output: msg.result as string,
                  duration: msg.duration as number,
                },
              ],
            };
            setMessages((prev) => [...prev, toolMsg]);
          }
          break;

        case 'turn_end':
        case 'agent_end':
          // Finalize any remaining streaming content
          if (streamingContent.trim()) {
            const finalMsg: Message = {
              id: currentStreamingId || `msg_${messageIdCounter.current++}`,
              role: 'assistant',
              content: streamingContent.trim(),
              timestamp: new Date().toISOString(),
            };
            setMessages((prev) => [...prev, finalMsg]);
            setStreamingContent('');
          }
          setIsProcessing(false);
          setCurrentStreamingId(null);

          // Update token usage if provided
          if (msg.usage && typeof msg.usage === 'object') {
            const usage = msg.usage as { input?: number; output?: number };
            setTokenUsage((prev) => ({
              input: prev.input + (usage.input || 0),
              output: prev.output + (usage.output || 0),
            }));
          }
          break;
      }
    });

    return unsubscribe;
  }, [subscribe, streamingContent, currentStreamingId]);

  const handleSubmit = useCallback(
    (content: string) => {
      // Add user message
      const userMsg: Message = {
        id: `msg_${messageIdCounter.current++}`,
        role: 'user',
        content,
        timestamp: new Date().toISOString(),
      };
      setMessages((prev) => [...prev, userMsg]);

      // Send to server
      send({ type: 'prompt', text: content });
    },
    [send]
  );

  const handleStop = useCallback(() => {
    send({ type: 'abort' });
    setIsProcessing(false);
  }, [send]);

  return (
    <div
      style={{
        flex: 1,
        display: 'flex',
        flexDirection: 'column',
        overflow: 'hidden',
      }}
    >
      {/* Status bar */}
      <StatusBar
        model="claude-sonnet-4"
        tokenUsage={tokenUsage}
        contextPercent={Math.min(100, Math.round((tokenUsage.input + tokenUsage.output) / 2000))}
      />

      {/* Messages area */}
      <div
        style={{
          flex: 1,
          overflow: 'auto',
          padding: 'var(--space-md)',
        }}
      >
        {messages.length === 0 && !streamingContent && (
          <div
            style={{
              display: 'flex',
              flexDirection: 'column',
              alignItems: 'center',
              justifyContent: 'center',
              height: '100%',
              color: 'var(--text-muted)',
              textAlign: 'center',
              padding: 'var(--space-xl)',
            }}
          >
            <div
              style={{
                fontSize: '48px',
                marginBottom: 'var(--space-md)',
                opacity: 0.3,
              }}
            >
              *
            </div>
            <h2
              style={{
                fontSize: 'var(--text-lg)',
                fontWeight: 500,
                marginBottom: 'var(--space-sm)',
                color: 'var(--text-secondary)',
              }}
            >
              Welcome to Tron
            </h2>
            <p style={{ fontSize: 'var(--text-sm)' }}>
              Your AI coding assistant. Start a conversation below.
            </p>
          </div>
        )}

        {messages.map((msg) => (
          <MessageBubble key={msg.id} message={msg} />
        ))}

        {/* Streaming message */}
        {streamingContent && (
          <MessageBubble
            message={{
              id: currentStreamingId || 'streaming',
              role: 'assistant',
              content: streamingContent,
              timestamp: new Date().toISOString(),
              isStreaming: true,
            }}
          />
        )}

        <div ref={messagesEndRef} />
      </div>

      {/* Input bar */}
      <InputBar
        onSubmit={handleSubmit}
        onStop={handleStop}
        isProcessing={isProcessing}
        disabled={status !== 'connected'}
        placeholder={
          status !== 'connected' ? 'Connecting to server...' : 'Type a message...'
        }
      />
    </div>
  );
}
