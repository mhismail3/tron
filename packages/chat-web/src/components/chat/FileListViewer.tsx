/**
 * FileListViewer Component
 *
 * Displays file listing and search results with:
 * - Pattern/query display in header
 * - File paths with icons
 * - Grep mode: shows matching lines with highlights
 * - List mode: shows file paths only
 * - Collapsible sections per file
 */

import { useState, useMemo, useCallback } from 'react';
import './FileListViewer.css';

export interface FileListViewerProps {
  pattern: string;
  content: string;
  mode: 'list' | 'grep';
  maxHeight?: number;
}

interface FileEntry {
  path: string;
  displayPath: string;
  icon: string;
  matches?: GrepMatch[];
}

interface GrepMatch {
  lineNum?: number;
  content: string;
}

/**
 * Get icon for file based on extension
 */
function getFileIcon(path: string): string {
  const ext = path.split('.').pop()?.toLowerCase() || '';
  const iconMap: Record<string, string> = {
    ts: '⟨⟩',
    tsx: '⟨⟩',
    js: '⟨⟩',
    jsx: '⟨⟩',
    py: '🐍',
    rb: '💎',
    rs: '⚙',
    go: '◇',
    css: '🎨',
    scss: '🎨',
    html: '◇',
    json: '{ }',
    yaml: '≡',
    yml: '≡',
    md: '📝',
    sh: '$',
    sql: '⊞',
  };
  return iconMap[ext] || '📄';
}

/**
 * Shorten path for display
 */
function shortenPath(path: string): string {
  const parts = path.split('/');
  if (parts.length <= 3) return path;
  return '…/' + parts.slice(-3).join('/');
}

/**
 * Parse content based on mode
 */
function parseContent(
  content: string,
  mode: 'list' | 'grep'
): FileEntry[] {
  const lines = content.split('\n').filter((l) => l.trim());

  if (mode === 'list') {
    // Simple file list - one file per line
    return lines.map((line) => ({
      path: line.trim(),
      displayPath: shortenPath(line.trim()),
      icon: getFileIcon(line.trim()),
    }));
  }

  // Grep mode - parse file:line:content or file:content format
  const files = new Map<string, GrepMatch[]>();

  for (const line of lines) {
    // Try to match file:line:content
    const match = line.match(/^(.+?):(\d+):(.*)$/) ||
                  line.match(/^(.+?):(\d+)-(.*)$/);

    if (match && match[1] && match[2]) {
      const filePath = match[1];
      const lineNum = match[2];
      const matchContent = match[3] || '';
      if (!files.has(filePath)) {
        files.set(filePath, []);
      }
      files.get(filePath)!.push({
        lineNum: parseInt(lineNum, 10),
        content: matchContent,
      });
    } else {
      // Try file:content (no line number)
      const simpleMatch = line.match(/^(.+?):(.+)$/);
      if (simpleMatch && simpleMatch[1] && simpleMatch[2]) {
        const filePath = simpleMatch[1];
        const matchContent = simpleMatch[2];
        // Check if it looks like a file path
        if (filePath.includes('/') || filePath.includes('.')) {
          if (!files.has(filePath)) {
            files.set(filePath, []);
          }
          files.get(filePath)!.push({ content: matchContent });
        } else {
          // Probably just a file path on its own
          if (!files.has(line)) {
            files.set(line, []);
          }
        }
      } else {
        // Assume it's just a file path
        if (!files.has(line)) {
          files.set(line, []);
        }
      }
    }
  }

  return Array.from(files.entries()).map(([path, matches]) => ({
    path,
    displayPath: shortenPath(path),
    icon: getFileIcon(path),
    matches: matches.length > 0 ? matches : undefined,
  }));
}

export function FileListViewer({
  pattern,
  content,
  mode,
  maxHeight = 400,
}: FileListViewerProps) {
  const [isExpanded, setIsExpanded] = useState(true);
  const [expandedFiles, setExpandedFiles] = useState<Set<string>>(new Set());

  const files = useMemo(() => parseContent(content, mode), [content, mode]);
  const fileCount = files.length;
  const matchCount = files.reduce(
    (sum, f) => sum + (f.matches?.length || 0),
    0
  );

  const toggleExpand = useCallback(() => {
    setIsExpanded((prev) => !prev);
  }, []);

  const toggleFile = useCallback((path: string) => {
    setExpandedFiles((prev) => {
      const next = new Set(prev);
      if (next.has(path)) {
        next.delete(path);
      } else {
        next.add(path);
      }
      return next;
    });
  }, []);

  const expandAll = useCallback(() => {
    setExpandedFiles(new Set(files.map((f) => f.path)));
  }, [files]);

  const collapseAll = useCallback(() => {
    setExpandedFiles(new Set());
  }, []);

  const hasMatches = mode === 'grep' && matchCount > 0;

  return (
    <div className={`filelist-viewer filelist-viewer--${mode}`}>
      {/* Header */}
      <div className="filelist-header">
        <div className="filelist-header-left">
          <span className="filelist-icon">{mode === 'grep' ? '🔍' : '📁'}</span>
          {pattern && (
            <code className="filelist-pattern" title={pattern}>
              {pattern.length > 40 ? pattern.slice(0, 40) + '…' : pattern}
            </code>
          )}
        </div>
        <div className="filelist-header-right">
          <span className="filelist-count">
            {fileCount} file{fileCount !== 1 ? 's' : ''}
            {hasMatches && `, ${matchCount} match${matchCount !== 1 ? 'es' : ''}`}
          </span>
          {hasMatches && (
            <>
              <button
                className="filelist-expand-all"
                onClick={expandAll}
                title="Expand all"
              >
                ⊞
              </button>
              <button
                className="filelist-collapse-all"
                onClick={collapseAll}
                title="Collapse all"
              >
                ⊟
              </button>
            </>
          )}
          <button
            className="filelist-toggle"
            onClick={toggleExpand}
            aria-expanded={isExpanded}
          >
            {isExpanded ? '▾' : '▸'}
          </button>
        </div>
      </div>

      {/* Content */}
      {isExpanded && (
        <div className="filelist-content" style={{ maxHeight }}>
          {files.map((file, idx) => (
            <div key={idx} className="filelist-file">
              <div
                className="filelist-file-header"
                onClick={() => file.matches && toggleFile(file.path)}
              >
                <span className="filelist-file-icon">{file.icon}</span>
                <span className="filelist-file-path" title={file.path}>
                  {file.displayPath}
                </span>
                {file.matches && file.matches.length > 0 && (
                  <>
                    <span className="filelist-file-match-count">
                      {file.matches.length}
                    </span>
                    <span className="filelist-file-toggle">
                      {expandedFiles.has(file.path) ? '▾' : '▸'}
                    </span>
                  </>
                )}
              </div>

              {/* Matches (grep mode) */}
              {file.matches &&
                expandedFiles.has(file.path) &&
                file.matches.length > 0 && (
                  <div className="filelist-matches">
                    {file.matches.map((match, matchIdx) => (
                      <div key={matchIdx} className="filelist-match">
                        {match.lineNum !== undefined && (
                          <span className="filelist-match-line">
                            {match.lineNum}
                          </span>
                        )}
                        <span className="filelist-match-content">
                          {match.content}
                        </span>
                      </div>
                    ))}
                  </div>
                )}
            </div>
          ))}

          {files.length === 0 && (
            <div className="filelist-empty">No results</div>
          )}
        </div>
      )}
    </div>
  );
}

export default FileListViewer;
