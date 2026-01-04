/**
 * DiffViewer Component
 *
 * Renders unified diff output with syntax highlighting,
 * line numbers, and visual indicators for changes.
 */

import { useMemo, useState } from 'react';
import './DiffViewer.css';

interface DiffLine {
  type: 'context' | 'addition' | 'deletion' | 'hunk-header' | 'file-header' | 'info';
  content: string;
  oldLineNum?: number;
  newLineNum?: number;
}

interface DiffHunk {
  header: string;
  oldStart: number;
  oldCount: number;
  newStart: number;
  newCount: number;
  lines: DiffLine[];
}

interface ParsedDiff {
  filePath: string;
  hunks: DiffHunk[];
  additions: number;
  deletions: number;
  infoLines: string[];
}

interface DiffViewerProps {
  content: string;
  maxHeight?: number;
  defaultExpanded?: boolean;
}

/**
 * Parse unified diff format into structured data
 */
function parseUnifiedDiff(content: string): ParsedDiff {
  const lines = content.split('\n');
  const result: ParsedDiff = {
    filePath: '',
    hunks: [],
    additions: 0,
    deletions: 0,
    infoLines: [],
  };

  let currentHunk: DiffHunk | null = null;
  let oldLineNum = 0;
  let newLineNum = 0;

  for (const line of lines) {
    // File path detection - look for common patterns
    const filePathMatch =
      line.match(/^Successfully replaced \d+ occurrences? in (.+)$/) ||
      line.match(/^--- a\/(.+)$/) ||
      line.match(/^(?:File|Modified|Edited): (.+)$/i);

    if (filePathMatch && filePathMatch[1]) {
      result.filePath = filePathMatch[1];
      result.infoLines.push(line);
      continue;
    }

    // Skip +++ lines (new file indicator in standard diff)
    if (line.startsWith('+++ ')) {
      continue;
    }

    // Hunk header: @@ -oldStart,oldCount +newStart,newCount @@
    const hunkMatch = line.match(/^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@(.*)$/);
    if (hunkMatch) {
      if (currentHunk) {
        result.hunks.push(currentHunk);
      }

      const oldStart = parseInt(hunkMatch[1] || '1', 10);
      const oldCount = hunkMatch[2] ? parseInt(hunkMatch[2], 10) : 1;
      const newStart = parseInt(hunkMatch[3] || '1', 10);
      const newCount = hunkMatch[4] ? parseInt(hunkMatch[4], 10) : 1;

      currentHunk = {
        header: line,
        oldStart,
        oldCount,
        newStart,
        newCount,
        lines: [],
      };

      oldLineNum = oldStart;
      newLineNum = newStart;

      currentHunk.lines.push({
        type: 'hunk-header',
        content: hunkMatch[5]?.trim() || '',
      });
      continue;
    }

    // Diff lines (only process if we're inside a hunk)
    if (currentHunk) {
      if (line.startsWith('-')) {
        result.deletions++;
        currentHunk.lines.push({
          type: 'deletion',
          content: line.slice(1),
          oldLineNum: oldLineNum++,
        });
      } else if (line.startsWith('+')) {
        result.additions++;
        currentHunk.lines.push({
          type: 'addition',
          content: line.slice(1),
          newLineNum: newLineNum++,
        });
      } else if (line.startsWith(' ') || line === '') {
        // Context line
        currentHunk.lines.push({
          type: 'context',
          content: line.slice(1) || '',
          oldLineNum: oldLineNum++,
          newLineNum: newLineNum++,
        });
      }
    } else if (line.trim()) {
      // Info line before any hunks
      result.infoLines.push(line);
    }
  }

  // Push the last hunk
  if (currentHunk) {
    result.hunks.push(currentHunk);
  }

  return result;
}

/**
 * Check if content looks like a diff
 */
function isDiffContent(content: string): boolean {
  return (
    content.includes('@@ -') ||
    content.includes('+++') ||
    /^[-+] /m.test(content)
  );
}

export function DiffViewer({
  content,
  maxHeight = 400,
  defaultExpanded = true,
}: DiffViewerProps) {
  const [isExpanded, setIsExpanded] = useState(defaultExpanded);

  const parsed = useMemo(() => parseUnifiedDiff(content), [content]);
  const hasDiff = parsed.hunks.length > 0;

  // If it doesn't look like a diff, render as plain text
  if (!hasDiff && !isDiffContent(content)) {
    return (
      <div className="diff-viewer diff-viewer--plain">
        <pre className="diff-plain-content">{content}</pre>
      </div>
    );
  }

  const totalChanges = parsed.additions + parsed.deletions;

  return (
    <div className="diff-viewer">
      {/* Header with file info and stats */}
      <div className="diff-header">
        <div className="diff-header-left">
          {parsed.filePath && (
            <span className="diff-file-path" title={parsed.filePath}>
              {getFileName(parsed.filePath)}
            </span>
          )}
        </div>
        <div className="diff-header-right">
          {totalChanges > 0 && (
            <div className="diff-stats">
              {parsed.additions > 0 && (
                <span className="diff-stat diff-stat--add">+{parsed.additions}</span>
              )}
              {parsed.deletions > 0 && (
                <span className="diff-stat diff-stat--del">−{parsed.deletions}</span>
              )}
            </div>
          )}
          {parsed.hunks.length > 1 && (
            <button
              className="diff-toggle"
              onClick={() => setIsExpanded(!isExpanded)}
              aria-expanded={isExpanded}
            >
              {isExpanded ? '▾ Collapse' : '▸ Expand'}
            </button>
          )}
        </div>
      </div>

      {/* Info lines (success message, etc.) */}
      {parsed.infoLines.length > 0 && (
        <div className="diff-info">
          {parsed.infoLines.map((line, i) => (
            <div key={i} className="diff-info-line">
              {line}
            </div>
          ))}
        </div>
      )}

      {/* Diff content */}
      {isExpanded && (
        <div className="diff-content" style={{ maxHeight }}>
          {parsed.hunks.map((hunk, hunkIndex) => (
            <div key={hunkIndex} className="diff-hunk">
              <div className="diff-hunk-header">
                <span className="diff-hunk-range">
                  @@ -{hunk.oldStart},{hunk.oldCount} +{hunk.newStart},{hunk.newCount} @@
                </span>
                {hunk.lines[0]?.type === 'hunk-header' && hunk.lines[0].content && (
                  <span className="diff-hunk-context">{hunk.lines[0].content}</span>
                )}
              </div>
              <div className="diff-lines">
                {hunk.lines
                  .filter((line) => line.type !== 'hunk-header')
                  .map((line, lineIndex) => (
                    <div
                      key={lineIndex}
                      className={`diff-line diff-line--${line.type}`}
                    >
                      <span className="diff-line-num diff-line-num--old">
                        {line.oldLineNum ?? ''}
                      </span>
                      <span className="diff-line-num diff-line-num--new">
                        {line.newLineNum ?? ''}
                      </span>
                      <span className="diff-line-marker">
                        {line.type === 'addition'
                          ? '+'
                          : line.type === 'deletion'
                            ? '−'
                            : ' '}
                      </span>
                      <span className="diff-line-content">
                        {line.content || '\u00A0'}
                      </span>
                    </div>
                  ))}
              </div>
            </div>
          ))}
        </div>
      )}
    </div>
  );
}

/**
 * Extract filename from path
 */
function getFileName(path: string): string {
  const parts = path.split('/');
  const fileName = parts.pop() || path;
  const dir = parts.length > 0 ? parts.slice(-2).join('/') : '';
  return dir ? `${dir}/${fileName}` : fileName;
}

export default DiffViewer;
