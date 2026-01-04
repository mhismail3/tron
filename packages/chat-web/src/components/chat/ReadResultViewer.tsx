/**
 * ReadResultViewer Component
 *
 * Displays file read results with:
 * - File path in header with icon
 * - Line numbers
 * - Syntax highlighting hints via CSS classes
 * - Scrollable content
 * - Language detection from extension
 */

import { useState, useMemo, useCallback } from 'react';
import './ReadResultViewer.css';

export interface ReadResultViewerProps {
  filePath: string;
  content: string;
  maxHeight?: number;
}

interface ParsedLine {
  lineNum: number;
  content: string;
  originalLineNum?: number; // If content includes line numbers from cat -n
}

/**
 * Get language/type from file extension
 */
function getLanguageFromPath(filePath: string): string {
  const ext = filePath.split('.').pop()?.toLowerCase() || '';
  const langMap: Record<string, string> = {
    ts: 'typescript',
    tsx: 'typescript',
    js: 'javascript',
    jsx: 'javascript',
    py: 'python',
    rb: 'ruby',
    rs: 'rust',
    go: 'go',
    java: 'java',
    kt: 'kotlin',
    swift: 'swift',
    c: 'c',
    cpp: 'cpp',
    h: 'c',
    hpp: 'cpp',
    css: 'css',
    scss: 'scss',
    less: 'less',
    html: 'html',
    xml: 'xml',
    json: 'json',
    yaml: 'yaml',
    yml: 'yaml',
    md: 'markdown',
    sh: 'bash',
    bash: 'bash',
    zsh: 'bash',
    fish: 'fish',
    sql: 'sql',
    graphql: 'graphql',
    vue: 'vue',
    svelte: 'svelte',
    toml: 'toml',
    ini: 'ini',
    conf: 'config',
    env: 'env',
    dockerfile: 'dockerfile',
    makefile: 'makefile',
  };

  // Check for special filenames
  const filename = filePath.split('/').pop()?.toLowerCase() || '';
  if (filename === 'dockerfile') return 'dockerfile';
  if (filename === 'makefile' || filename === 'gnumakefile') return 'makefile';
  if (filename.startsWith('.env')) return 'env';

  return langMap[ext] || 'text';
}

/**
 * Get file icon based on language/type
 */
function getFileIcon(lang: string): string {
  const iconMap: Record<string, string> = {
    typescript: '⟨⟩',
    javascript: '⟨⟩',
    python: '🐍',
    ruby: '💎',
    rust: '⚙',
    go: '◇',
    java: '☕',
    css: '🎨',
    scss: '🎨',
    html: '◇',
    json: '{ }',
    yaml: '≡',
    markdown: '📝',
    bash: '$',
    sql: '⊞',
    dockerfile: '🐳',
    config: '⚙',
    text: '📄',
  };
  return iconMap[lang] || '📄';
}

/**
 * Parse file content, handling cat -n style line numbers
 */
function parseContent(content: string): ParsedLine[] {
  const lines = content.split('\n');
  const result: ParsedLine[] = [];

  // Check if content has cat -n style line numbers (spaces + number + tab/spaces + content)
  const hasCatLineNums = lines.some((line) =>
    /^\s*\d+[\t→]/.test(line)
  );

  for (let i = 0; i < lines.length; i++) {
    const line = lines[i] ?? '';

    if (hasCatLineNums) {
      // Parse cat -n format: "    1→content" or "   42\tcontent"
      const match = line.match(/^\s*(\d+)[\t→](.*)$/);
      if (match && match[1]) {
        result.push({
          lineNum: i + 1,
          originalLineNum: parseInt(match[1], 10),
          content: match[2] ?? '',
        });
      } else {
        // Line doesn't match pattern, use as-is
        result.push({
          lineNum: i + 1,
          content: line,
        });
      }
    } else {
      result.push({
        lineNum: i + 1,
        content: line,
      });
    }
  }

  // Remove trailing empty lines
  while (result.length > 0) {
    const lastLine = result[result.length - 1];
    if (lastLine && lastLine.content === '') {
      result.pop();
    } else {
      break;
    }
  }

  return result;
}

/**
 * Extract filename from path
 */
function getFileName(path: string): string {
  const parts = path.split('/');
  const fileName = parts.pop() || path;
  const dir = parts.length > 0 ? parts.slice(-1).join('/') : '';
  return dir ? `${dir}/${fileName}` : fileName;
}

export function ReadResultViewer({
  filePath,
  content,
  maxHeight = 500,
}: ReadResultViewerProps) {
  const [isExpanded, setIsExpanded] = useState(true);
  const [copied, setCopied] = useState(false);

  const language = useMemo(() => getLanguageFromPath(filePath), [filePath]);
  const fileIcon = useMemo(() => getFileIcon(language), [language]);
  const displayPath = useMemo(() => getFileName(filePath), [filePath]);
  const parsed = useMemo(() => parseContent(content), [content]);
  const lineCount = parsed.length;
  const hasOriginalLineNums = parsed.some((l) => l.originalLineNum !== undefined);

  const handleCopy = useCallback(async () => {
    try {
      // Copy the raw content without line numbers
      const rawContent = parsed.map((l) => l.content).join('\n');
      await navigator.clipboard.writeText(rawContent);
      setCopied(true);
      setTimeout(() => setCopied(false), 2000);
    } catch {
      // Clipboard API not available
    }
  }, [parsed]);

  const toggleExpand = useCallback(() => {
    setIsExpanded((prev) => !prev);
  }, []);

  return (
    <div className={`read-viewer read-viewer--${language}`}>
      {/* Header */}
      <div className="read-header">
        <div className="read-header-left">
          <span className="read-icon">{fileIcon}</span>
          <span className="read-path" title={filePath}>
            {displayPath}
          </span>
          <span className="read-lang">{language}</span>
        </div>
        <div className="read-header-right">
          <button
            className="read-copy"
            onClick={handleCopy}
            title="Copy content"
          >
            {copied ? '✓' : '⧉'}
          </button>
          <span className="read-line-count">{lineCount} lines</span>
          <button
            className="read-toggle"
            onClick={toggleExpand}
            aria-expanded={isExpanded}
          >
            {isExpanded ? '▾' : '▸'}
          </button>
        </div>
      </div>

      {/* Content */}
      {isExpanded && (
        <div className="read-content" style={{ maxHeight }}>
          <div className="read-lines">
            {parsed.map((line, idx) => (
              <div key={idx} className="read-line">
                <span className="read-line-num">
                  {hasOriginalLineNums
                    ? line.originalLineNum || ''
                    : line.lineNum}
                </span>
                <span className="read-line-content">
                  {line.content || '\u00A0'}
                </span>
              </div>
            ))}
          </div>
        </div>
      )}
    </div>
  );
}

export default ReadResultViewer;
