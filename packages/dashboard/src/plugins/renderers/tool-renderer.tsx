/**
 * @fileoverview Tool event renderer plugin
 */

import React from 'react';
import type { EventRendererPlugin, EventRendererProps } from '../types.js';
import type { TronSessionEvent } from '@tron/agent';
import { JsonViewer } from '../../components/ui/JsonViewer.js';
import { Badge } from '../../components/ui/Badge.js';

/**
 * Render tool call event
 */
function ToolCallContent({ event, expanded }: { event: TronSessionEvent; expanded: boolean }) {
  const payload = event.payload as {
    toolCallId: string;
    name: string;
    arguments: Record<string, unknown>;
    turn?: number;
  };

  return (
    <div className="tool-renderer tool-renderer-call">
      <div className="tool-header">
        <Badge variant="info">{payload.name}</Badge>
        <span className="tool-id">{payload.toolCallId}</span>
      </div>

      {expanded && (
        <div className="tool-arguments">
          <span className="tool-label">Arguments:</span>
          <JsonViewer data={payload.arguments} initialExpanded={true} />
        </div>
      )}
    </div>
  );
}

/**
 * Render tool result event
 */
function ToolResultContent({ event, expanded }: { event: TronSessionEvent; expanded: boolean }) {
  const payload = event.payload as {
    toolCallId: string;
    content: string;
    isError?: boolean;
    duration?: number;
  };

  return (
    <div className={`tool-renderer tool-renderer-result ${payload.isError ? 'tool-error' : ''}`}>
      <div className="tool-header">
        <Badge variant={payload.isError ? 'error' : 'success'}>
          {payload.isError ? 'Error' : 'Success'}
        </Badge>
        <span className="tool-id">{payload.toolCallId}</span>
        {payload.duration !== undefined && (
          <span className="tool-duration">{payload.duration}ms</span>
        )}
      </div>

      {expanded && (
        <div className="tool-content">
          <span className="tool-label">Result:</span>
          <pre className="tool-output">{payload.content}</pre>
        </div>
      )}
    </div>
  );
}

/**
 * Tool renderer plugin
 */
export const toolRendererPlugin: EventRendererPlugin = {
  id: 'tool-renderer',
  name: 'Tool Renderer',
  priority: 10,

  canRender(event: TronSessionEvent): boolean {
    return event.type === 'tool.call' || event.type === 'tool.result';
  },

  render(props: EventRendererProps): React.ReactNode {
    const { event, expanded } = props;

    if (event.type === 'tool.call') {
      return <ToolCallContent event={event} expanded={expanded} />;
    }

    if (event.type === 'tool.result') {
      return <ToolResultContent event={event} expanded={expanded} />;
    }

    return null;
  },
};
