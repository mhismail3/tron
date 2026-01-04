/**
 * BashResultViewer Component
 *
 * Displays Bash command execution results with:
 * - Command preview in header
 * - Scrollable output area
 * - Error state handling
 * - Copy command functionality
 */

import { useState, useMemo, useCallback } from 'react';
import './BashResultViewer.css';

export interface BashResultViewerProps {
  command?: string;
  content: string;
  isError?: boolean;
  maxHeight?: number;
}

/**
 * Parse bash output to detect structure
 */
interface ParsedOutput {
  lines: OutputLine[];
  hasStderr: boolean;
  exitCode?: number;
}

interface OutputLine {
  type: 'stdout' | 'stderr' | 'info';
  content: string;
  lineNum: number;
}

function parseOutput(content: string): ParsedOutput {
  const lines = content.split('\n');
  const result: ParsedOutput = {
    lines: [],
    hasStderr: false,
  };

  let lineNum = 1;
  for (const line of lines) {
    // Check for exit code patterns
    const exitMatch = line.match(/exit code[:\s]+(\d+)/i);
    if (exitMatch && exitMatch[1]) {
      result.exitCode = parseInt(exitMatch[1], 10);
    }

    // Detect stderr markers (common patterns)
    const isStderr =
      line.startsWith('error:') ||
      line.startsWith('Error:') ||
      line.startsWith('ERROR:') ||
      line.includes(': error:') ||
      line.includes(': Error:') ||
      line.startsWith('warning:') ||
      line.startsWith('Warning:') ||
      line.startsWith('fatal:') ||
      line.startsWith('FATAL:');

    if (isStderr) {
      result.hasStderr = true;
    }

    result.lines.push({
      type: isStderr ? 'stderr' : 'stdout',
      content: line,
      lineNum: lineNum++,
    });
  }

  // Remove trailing empty lines
  while (result.lines.length > 0) {
    const lastLine = result.lines[result.lines.length - 1];
    if (lastLine && lastLine.content === '') {
      result.lines.pop();
    } else {
      break;
    }
  }

  return result;
}

/**
 * Truncate command for display
 */
function truncateCommand(cmd: string, maxLen: number = 80): string {
  if (!cmd) return '';
  // Remove newlines for display
  const singleLine = cmd.replace(/\n/g, ' ').replace(/\s+/g, ' ').trim();
  if (singleLine.length <= maxLen) return singleLine;
  return singleLine.slice(0, maxLen - 1) + '…';
}

export function BashResultViewer({
  command,
  content,
  isError = false,
  maxHeight = 400,
}: BashResultViewerProps) {
  const [isExpanded, setIsExpanded] = useState(true);
  const [showFullCommand, setShowFullCommand] = useState(false);
  const [copied, setCopied] = useState(false);

  const parsed = useMemo(() => parseOutput(content), [content]);
  const displayCommand = useMemo(
    () => truncateCommand(command || '', 60),
    [command]
  );
  const isMultilineCommand = command?.includes('\n') || (command?.length || 0) > 60;
  const hasOutput = parsed.lines.length > 0;
  const lineCount = parsed.lines.length;

  const handleCopyCommand = useCallback(async () => {
    if (!command) return;
    try {
      await navigator.clipboard.writeText(command);
      setCopied(true);
      setTimeout(() => setCopied(false), 2000);
    } catch {
      // Clipboard API not available
    }
  }, [command]);

  const toggleExpand = useCallback(() => {
    setIsExpanded((prev) => !prev);
  }, []);

  const toggleFullCommand = useCallback(() => {
    setShowFullCommand((prev) => !prev);
  }, []);

  return (
    <div
      className={`bash-viewer ${isError ? 'bash-viewer--error' : ''} ${
        parsed.hasStderr ? 'bash-viewer--has-stderr' : ''
      }`}
    >
      {/* Header with command */}
      <div className="bash-header">
        <div className="bash-header-left">
          <span className="bash-prompt">$</span>
          <code
            className="bash-command"
            onClick={isMultilineCommand ? toggleFullCommand : undefined}
            title={command}
          >
            {displayCommand || '(no command)'}
          </code>
          {isMultilineCommand && (
            <button
              className="bash-expand-cmd"
              onClick={toggleFullCommand}
              title={showFullCommand ? 'Hide full command' : 'Show full command'}
            >
              {showFullCommand ? '▴' : '▾'}
            </button>
          )}
        </div>
        <div className="bash-header-right">
          {command && (
            <button
              className="bash-copy"
              onClick={handleCopyCommand}
              title="Copy command"
            >
              {copied ? '✓' : '⧉'}
            </button>
          )}
          {hasOutput && (
            <>
              <span className="bash-line-count">{lineCount} lines</span>
              <button
                className="bash-toggle"
                onClick={toggleExpand}
                aria-expanded={isExpanded}
              >
                {isExpanded ? '▾' : '▸'}
              </button>
            </>
          )}
        </div>
      </div>

      {/* Full command display (when expanded) */}
      {showFullCommand && command && (
        <div className="bash-full-command">
          <pre>{command}</pre>
        </div>
      )}

      {/* Output */}
      {isExpanded && hasOutput && (
        <div className="bash-output" style={{ maxHeight }}>
          <div className="bash-lines">
            {parsed.lines.map((line, idx) => (
              <div
                key={idx}
                className={`bash-line bash-line--${line.type}`}
              >
                <span className="bash-line-num">{line.lineNum}</span>
                <span className="bash-line-content">
                  {line.content || '\u00A0'}
                </span>
              </div>
            ))}
          </div>
        </div>
      )}

      {/* Empty state */}
      {!hasOutput && !isError && (
        <div className="bash-empty">
          <span className="bash-empty-text">No output</span>
        </div>
      )}

      {/* Exit code indicator */}
      {parsed.exitCode !== undefined && parsed.exitCode !== 0 && (
        <div className="bash-footer">
          <span className="bash-exit-code">Exit code: {parsed.exitCode}</span>
        </div>
      )}
    </div>
  );
}

export default BashResultViewer;
