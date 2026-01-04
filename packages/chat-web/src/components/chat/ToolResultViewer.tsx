/**
 * ToolResultViewer Component
 *
 * Routes tool results to specialized viewers based on tool type.
 * Provides elegant, comprehensive display for each tool's output.
 */

import { useMemo } from 'react';
import { DiffViewer } from './DiffViewer.js';
import { BashResultViewer } from './BashResultViewer.js';
import { ReadResultViewer } from './ReadResultViewer.js';
import { FileListViewer } from './FileListViewer.js';
import { GenericResultViewer } from './GenericResultViewer.js';
import './ToolResultViewer.css';

export interface ToolResultViewerProps {
  toolName: string;
  toolInput?: string;
  content: string;
  status: 'running' | 'success' | 'error';
  isCollapsed?: boolean;
}

/**
 * Parse tool input JSON safely
 */
function parseToolInput(toolInput?: string): Record<string, unknown> {
  if (!toolInput) return {};
  try {
    return JSON.parse(toolInput);
  } catch {
    return {};
  }
}

/**
 * Determine which viewer to use based on tool name
 */
function getToolCategory(toolName: string): string {
  const name = toolName.toLowerCase();

  // Edit tools -> DiffViewer
  if (name === 'edit' || name === 'notebookedit') {
    return 'diff';
  }

  // Shell/command tools -> BashResultViewer
  if (name === 'bash' || name === 'shell' || name === 'command') {
    return 'bash';
  }

  // File read tools -> ReadResultViewer
  if (name === 'read' || name === 'cat' || name === 'readfile') {
    return 'read';
  }

  // Search/listing tools -> FileListViewer
  if (name === 'glob' || name === 'find' || name === 'ls' || name === 'list') {
    return 'filelist';
  }

  // Grep/search content tools -> FileListViewer (with content mode)
  if (name === 'grep' || name === 'search' || name === 'ripgrep' || name === 'rg') {
    return 'grep';
  }

  // Write tools -> simple confirmation
  if (name === 'write' || name === 'writefile') {
    return 'write';
  }

  // Task/Agent tools
  if (name === 'task' || name.includes('agent')) {
    return 'task';
  }

  // Web tools
  if (name === 'webfetch' || name === 'websearch' || name.startsWith('web')) {
    return 'web';
  }

  return 'generic';
}

export function ToolResultViewer({
  toolName,
  toolInput,
  content,
  status,
  isCollapsed = false,
}: ToolResultViewerProps) {
  const args = useMemo(() => parseToolInput(toolInput), [toolInput]);
  const category = useMemo(() => getToolCategory(toolName), [toolName]);

  // Handle running state
  if (status === 'running') {
    return (
      <div className="tool-result-viewer tool-result-viewer--running">
        <div className="tool-result-loading">
          <span className="tool-result-spinner">↻</span>
          <span className="tool-result-loading-text">Running...</span>
        </div>
      </div>
    );
  }

  // Route to appropriate viewer
  switch (category) {
    case 'diff':
      return (
        <DiffViewer
          content={content}
          maxHeight={isCollapsed ? 150 : 400}
          defaultExpanded={!isCollapsed}
        />
      );

    case 'bash':
      return (
        <BashResultViewer
          command={args.command as string | undefined}
          content={content}
          isError={status === 'error'}
          maxHeight={isCollapsed ? 150 : 400}
        />
      );

    case 'read':
      return (
        <ReadResultViewer
          filePath={
            (args.file_path as string) ||
            (args.path as string) ||
            ''
          }
          content={content}
          maxHeight={isCollapsed ? 150 : 500}
        />
      );

    case 'filelist':
    case 'grep':
      return (
        <FileListViewer
          pattern={
            (args.pattern as string) ||
            (args.query as string) ||
            (args.path as string) ||
            ''
          }
          content={content}
          mode={category === 'grep' ? 'grep' : 'list'}
          maxHeight={isCollapsed ? 150 : 400}
        />
      );

    case 'write':
      return (
        <GenericResultViewer
          content={content}
          variant="success"
          icon="✓"
          maxHeight={isCollapsed ? 150 : 200}
        />
      );

    case 'task':
      return (
        <GenericResultViewer
          content={content}
          variant="info"
          icon="◈"
          maxHeight={isCollapsed ? 150 : 500}
        />
      );

    case 'web':
      return (
        <GenericResultViewer
          content={content}
          variant="default"
          icon="🌐"
          maxHeight={isCollapsed ? 150 : 500}
        />
      );

    default:
      return (
        <GenericResultViewer
          content={content}
          variant={status === 'error' ? 'error' : 'default'}
          maxHeight={isCollapsed ? 150 : 400}
        />
      );
  }
}

export default ToolResultViewer;
