/**
 * @fileoverview Message event renderer plugin
 */

import React from 'react';
import type { EventRendererPlugin, EventRendererProps } from '../types.js';
import type { TronSessionEvent } from '@tron/agent';

/**
 * Render user message content
 */
function UserMessageContent({ event }: { event: TronSessionEvent }) {
  const payload = event.payload as { content: string; turn?: number };

  return (
    <div className="message-renderer message-renderer-user">
      <div className="message-turn">Turn {payload.turn ?? 1}</div>
      <div className="message-content">{payload.content}</div>
    </div>
  );
}

/**
 * Render assistant message content
 */
function AssistantMessageContent({ event }: { event: TronSessionEvent }) {
  const payload = event.payload as {
    content: Array<{ type: string; text?: string; id?: string; name?: string; input?: unknown }>;
    turn?: number;
    model?: string;
    stopReason?: string;
    tokenUsage?: { inputTokens: number; outputTokens: number };
  };

  return (
    <div className="message-renderer message-renderer-assistant">
      <div className="message-header">
        <span className="message-turn">Turn {payload.turn ?? 1}</span>
        {payload.model && <span className="message-model">{payload.model}</span>}
        {payload.stopReason && (
          <span className="message-stop-reason">{payload.stopReason}</span>
        )}
      </div>

      <div className="message-blocks">
        {payload.content.map((block, index) => {
          if (block.type === 'text') {
            return (
              <div key={index} className="message-block message-block-text">
                {block.text}
              </div>
            );
          }
          if (block.type === 'tool_use') {
            return (
              <div key={index} className="message-block message-block-tool-use">
                <span className="tool-name">{block.name}</span>
                <span className="tool-id">{block.id}</span>
              </div>
            );
          }
          return null;
        })}
      </div>

      {payload.tokenUsage && (
        <div className="message-tokens">
          <span>In: {payload.tokenUsage.inputTokens}</span>
          <span>Out: {payload.tokenUsage.outputTokens}</span>
        </div>
      )}
    </div>
  );
}

/**
 * Message renderer plugin
 */
export const messageRendererPlugin: EventRendererPlugin = {
  id: 'message-renderer',
  name: 'Message Renderer',
  priority: 10,

  canRender(event: TronSessionEvent): boolean {
    return event.type === 'message.user' || event.type === 'message.assistant';
  },

  render(props: EventRendererProps): React.ReactNode {
    const { event } = props;

    if (event.type === 'message.user') {
      return <UserMessageContent event={event} />;
    }

    if (event.type === 'message.assistant') {
      return <AssistantMessageContent event={event} />;
    }

    return null;
  },
};
