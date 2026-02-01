/**
 * @fileoverview Collapsible JSON tree viewer component
 */

import React, { useState, memo } from 'react';

export interface JsonViewerProps {
  data: unknown;
  initialExpanded?: boolean;
  depth?: number;
  maxDepth?: number;
  className?: string;
}

/**
 * Collapsible JSON tree viewer
 */
export const JsonViewer = memo(function JsonViewer({
  data,
  initialExpanded = false,
  depth = 0,
  maxDepth = 10,
  className = '',
}: JsonViewerProps) {
  const [expanded, setExpanded] = useState(initialExpanded);

  // Handle primitives
  if (data === null) {
    return <span className="json-null">null</span>;
  }

  if (data === undefined) {
    return <span className="json-undefined">undefined</span>;
  }

  if (typeof data === 'boolean') {
    return <span className="json-boolean">{data.toString()}</span>;
  }

  if (typeof data === 'number') {
    return <span className="json-number">{data}</span>;
  }

  if (typeof data === 'string') {
    // Check for long strings
    if (data.length > 100 && !expanded) {
      return (
        <span className="json-string">
          "{data.slice(0, 100)}..."
          <button
            className="json-expand-btn"
            onClick={() => setExpanded(true)}
            aria-label="Show full text"
          >
            [+{data.length - 100} chars]
          </button>
        </span>
      );
    }
    return <span className="json-string">"{data}"</span>;
  }

  // Prevent infinite depth
  if (depth >= maxDepth) {
    return <span className="json-max-depth">[max depth reached]</span>;
  }

  // Handle arrays
  if (Array.isArray(data)) {
    if (data.length === 0) {
      return <span className="json-array">[]</span>;
    }

    return (
      <div className={`json-array ${className}`}>
        <button
          className="json-toggle"
          onClick={() => setExpanded(!expanded)}
          role="button"
          aria-expanded={expanded}
        >
          <span className="json-toggle-icon">{expanded ? '▼' : '▶'}</span>
          <span className="json-bracket">[</span>
          {!expanded && <span className="json-count">{data.length} items</span>}
        </button>
        {expanded && (
          <div className="json-content">
            {data.map((item, index) => (
              <div key={index} className="json-item">
                <span className="json-index">{index}:</span>
                <JsonViewer
                  data={item}
                  initialExpanded={false}
                  depth={depth + 1}
                  maxDepth={maxDepth}
                />
                {index < data.length - 1 && <span className="json-comma">,</span>}
              </div>
            ))}
          </div>
        )}
        {expanded && <span className="json-bracket">]</span>}
        {!expanded && <span className="json-bracket">]</span>}
      </div>
    );
  }

  // Handle objects
  if (typeof data === 'object') {
    const entries = Object.entries(data);
    if (entries.length === 0) {
      return <span className="json-object">{'{}'}</span>;
    }

    return (
      <div className={`json-object ${className}`}>
        <button
          className="json-toggle"
          onClick={() => setExpanded(!expanded)}
          role="button"
          aria-expanded={expanded}
        >
          <span className="json-toggle-icon">{expanded ? '▼' : '▶'}</span>
          <span className="json-bracket">{'{'}</span>
          {!expanded && <span className="json-count">{entries.length} keys</span>}
        </button>
        {expanded && (
          <div className="json-content">
            {entries.map(([key, value], index) => (
              <div key={key} className="json-item">
                <span className="json-key">"{key}":</span>
                <JsonViewer
                  data={value}
                  initialExpanded={false}
                  depth={depth + 1}
                  maxDepth={maxDepth}
                />
                {index < entries.length - 1 && <span className="json-comma">,</span>}
              </div>
            ))}
          </div>
        )}
        {expanded && <span className="json-bracket">{'}'}</span>}
        {!expanded && <span className="json-bracket">{'}'}</span>}
      </div>
    );
  }

  // Fallback for unknown types
  return <span className="json-unknown">{String(data)}</span>;
});
