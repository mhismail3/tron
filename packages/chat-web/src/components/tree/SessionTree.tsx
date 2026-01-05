/**
 * @fileoverview Session Tree Visualization
 *
 * Interactive tree view showing session history with:
 * - Branch points for forks
 * - Visual path from root to current HEAD
 * - Click to fork from any node
 * - Hover previews of event content
 */

import { useState, useCallback, useMemo, useRef, useEffect } from 'react';
import './SessionTree.css';

// =============================================================================
// Types
// =============================================================================

export interface TreeNode {
  id: string;
  parentId: string | null;
  type: string;
  timestamp: string;
  summary: string;
  hasChildren: boolean;
  childCount: number;
  depth: number;
  isBranchPoint: boolean;
  isHead: boolean;
  /** For UI rendering - calculated position */
  x?: number;
  y?: number;
  /** Session this node belongs to */
  sessionId?: string;
}

export interface TreePath {
  nodeId: string;
  isActive: boolean;
}

export interface SessionTreeProps {
  /** Nodes in the tree */
  nodes: TreeNode[];
  /** ID of the current HEAD node */
  headNodeId?: string;
  /** ID of the currently selected node */
  selectedNodeId?: string;
  /** Callback when a node is clicked (for fork/rewind) */
  onNodeClick?: (nodeId: string, action: 'fork' | 'rewind' | 'select') => void;
  /** Callback when hovering over a node */
  onNodeHover?: (nodeId: string | null) => void;
  /** Whether to show compact view (sidebar) or expanded (dialog) */
  variant?: 'compact' | 'expanded';
  /** Optional title for the tree */
  title?: string;
  /** Show loading state */
  isLoading?: boolean;
  /** Max height for scrollable container */
  maxHeight?: number | string;
}

// =============================================================================
// Node Type Icons & Colors
// =============================================================================

const NODE_ICONS: Record<string, string> = {
  'session.start': '◉',
  'session.end': '◯',
  'session.fork': '◇',
  'message.user': '●',
  'message.assistant': '○',
  'tool.call': '▸',
  'tool.result': '▹',
  'config.model_switch': '⚙',
  'compact.boundary': '≡',
  default: '•',
};

const NODE_COLORS: Record<string, string> = {
  'session.start': 'var(--tree-node-start)',
  'session.end': 'var(--tree-node-end)',
  'session.fork': 'var(--tree-node-fork)',
  'message.user': 'var(--tree-node-user)',
  'message.assistant': 'var(--tree-node-assistant)',
  'tool.call': 'var(--tree-node-tool)',
  'tool.result': 'var(--tree-node-tool)',
  default: 'var(--tree-node-default)',
};

// =============================================================================
// Tree Node Component
// =============================================================================

interface TreeNodeItemProps {
  node: TreeNode;
  isHead: boolean;
  isSelected: boolean;
  isOnPath: boolean;
  level: number;
  variant: 'compact' | 'expanded';
  onSelect: () => void;
  onFork: () => void;
  onRewind: () => void;
  onHover: (hovering: boolean) => void;
}

function TreeNodeItem({
  node,
  isHead,
  isSelected,
  isOnPath,
  level,
  variant,
  onSelect,
  onFork,
  onRewind,
  onHover,
}: TreeNodeItemProps) {
  const [showActions, setShowActions] = useState(false);
  const icon = NODE_ICONS[node.type] || NODE_ICONS.default;
  const color = NODE_COLORS[node.type] || NODE_COLORS.default;

  const nodeClasses = [
    'tree-node',
    isHead && 'is-head',
    isSelected && 'is-selected',
    isOnPath && 'is-on-path',
    node.isBranchPoint && 'is-branch-point',
    variant,
  ]
    .filter(Boolean)
    .join(' ');

  const handleMouseEnter = useCallback(() => {
    setShowActions(true);
    onHover(true);
  }, [onHover]);

  const handleMouseLeave = useCallback(() => {
    setShowActions(false);
    onHover(false);
  }, [onHover]);

  const formatTimestamp = (ts: string) => {
    const date = new Date(ts);
    const now = new Date();
    const diffMs = now.getTime() - date.getTime();
    const diffMins = Math.floor(diffMs / 60000);
    const diffHours = Math.floor(diffMins / 60);
    const diffDays = Math.floor(diffHours / 24);

    if (diffMins < 1) return 'now';
    if (diffMins < 60) return `${diffMins}m ago`;
    if (diffHours < 24) return `${diffHours}h ago`;
    if (diffDays < 7) return `${diffDays}d ago`;
    return date.toLocaleDateString();
  };

  return (
    <div
      className={nodeClasses}
      style={{
        '--node-level': level,
        '--node-color': color,
      } as React.CSSProperties}
      onMouseEnter={handleMouseEnter}
      onMouseLeave={handleMouseLeave}
      onClick={onSelect}
      role="treeitem"
      aria-selected={isSelected}
      aria-expanded={node.hasChildren}
      tabIndex={0}
      onKeyDown={(e) => {
        if (e.key === 'Enter') onSelect();
        if (e.key === 'f' && e.ctrlKey) onFork();
        if (e.key === 'r' && e.ctrlKey) onRewind();
      }}
    >
      {/* Connector line to parent */}
      {level > 0 && (
        <div className="tree-connector">
          <div className="connector-vertical" />
          <div className="connector-horizontal" />
        </div>
      )}

      {/* Node content */}
      <div className="tree-node-content">
        <span className="node-icon" aria-hidden="true">
          {icon}
        </span>

        {variant === 'expanded' && (
          <>
            <span className="node-summary" title={node.summary}>
              {node.summary.length > 40
                ? `${node.summary.slice(0, 40)}...`
                : node.summary}
            </span>
            <span className="node-time">{formatTimestamp(node.timestamp)}</span>
          </>
        )}

        {isHead && <span className="head-badge">HEAD</span>}

        {node.isBranchPoint && (
          <span className="branch-badge" title={`${node.childCount} branches`}>
            {node.childCount}
          </span>
        )}
      </div>

      {/* Action buttons (visible on hover) */}
      {showActions && variant === 'expanded' && !isHead && (
        <div className="tree-node-actions">
          <button
            className="action-btn fork"
            onClick={(e) => {
              e.stopPropagation();
              onFork();
            }}
            title="Fork from this point"
            type="button"
          >
            ⎇ Fork
          </button>
          <button
            className="action-btn rewind"
            onClick={(e) => {
              e.stopPropagation();
              onRewind();
            }}
            title="Rewind to this point"
            type="button"
          >
            ↩ Rewind
          </button>
        </div>
      )}
    </div>
  );
}

// =============================================================================
// Main Session Tree Component
// =============================================================================

export function SessionTree({
  nodes,
  headNodeId,
  selectedNodeId,
  onNodeClick,
  onNodeHover,
  variant = 'expanded',
  title,
  isLoading,
  maxHeight = '400px',
}: SessionTreeProps) {
  const containerRef = useRef<HTMLDivElement>(null);
  const [hoveredNodeId, setHoveredNodeId] = useState<string | null>(null);

  // Build tree structure from flat nodes
  const { treeStructure, pathToHead } = useMemo(() => {
    // Group nodes by parentId
    const childrenMap = new Map<string | null, TreeNode[]>();
    const nodeMap = new Map<string, TreeNode>();

    for (const node of nodes) {
      nodeMap.set(node.id, node);
      const siblings = childrenMap.get(node.parentId) || [];
      siblings.push(node);
      childrenMap.set(node.parentId, siblings);
    }

    // Build path to HEAD
    const path = new Set<string>();
    if (headNodeId) {
      let current = headNodeId;
      while (current) {
        path.add(current);
        const node = nodeMap.get(current);
        if (node?.parentId) {
          current = node.parentId;
        } else {
          break;
        }
      }
    }

    // Get root nodes (parentId is null)
    const roots = childrenMap.get(null) || [];

    return {
      treeStructure: { roots, childrenMap, nodeMap },
      pathToHead: path,
    };
  }, [nodes, headNodeId]);

  // Render tree recursively
  const renderNode = useCallback(
    (node: TreeNode, level: number): React.ReactNode => {
      const children = treeStructure.childrenMap.get(node.id) || [];
      const isOnPath = pathToHead.has(node.id);

      return (
        <div key={node.id} className="tree-branch">
          <TreeNodeItem
            node={node}
            isHead={node.id === headNodeId}
            isSelected={node.id === selectedNodeId}
            isOnPath={isOnPath}
            level={level}
            variant={variant}
            onSelect={() => onNodeClick?.(node.id, 'select')}
            onFork={() => onNodeClick?.(node.id, 'fork')}
            onRewind={() => onNodeClick?.(node.id, 'rewind')}
            onHover={(hovering) => {
              setHoveredNodeId(hovering ? node.id : null);
              onNodeHover?.(hovering ? node.id : null);
            }}
          />

          {/* Render children */}
          {children.length > 0 && (
            <div className="tree-children">
              {children
                .sort(
                  (a, b) =>
                    new Date(a.timestamp).getTime() -
                    new Date(b.timestamp).getTime(),
                )
                .map((child) => renderNode(child, level + 1))}
            </div>
          )}
        </div>
      );
    },
    [
      treeStructure.childrenMap,
      pathToHead,
      headNodeId,
      selectedNodeId,
      variant,
      onNodeClick,
      onNodeHover,
    ],
  );

  // Auto-scroll to head when it changes
  useEffect(() => {
    if (headNodeId && containerRef.current) {
      const headElement = containerRef.current.querySelector('.is-head');
      if (headElement) {
        headElement.scrollIntoView({ behavior: 'smooth', block: 'center' });
      }
    }
  }, [headNodeId]);

  if (isLoading) {
    return (
      <div className={`session-tree ${variant} loading`}>
        <div className="tree-loading">
          <span className="loading-icon">◌</span>
          <span className="loading-text">Loading tree...</span>
        </div>
      </div>
    );
  }

  if (nodes.length === 0) {
    return (
      <div className={`session-tree ${variant} empty`}>
        <div className="tree-empty">
          <span className="empty-icon">◇</span>
          <span className="empty-text">No session history</span>
        </div>
      </div>
    );
  }

  return (
    <div className={`session-tree ${variant}`}>
      {title && <div className="tree-header">{title}</div>}

      <div
        ref={containerRef}
        className="tree-container"
        style={{ maxHeight }}
        role="tree"
        aria-label="Session history tree"
      >
        {treeStructure.roots
          .sort(
            (a, b) =>
              new Date(a.timestamp).getTime() - new Date(b.timestamp).getTime(),
          )
          .map((root) => renderNode(root, 0))}
      </div>

      {/* Hover preview (expanded variant only) */}
      {variant === 'expanded' && hoveredNodeId && (
        <TreeNodePreview
          node={treeStructure.nodeMap.get(hoveredNodeId) || null}
        />
      )}
    </div>
  );
}

// =============================================================================
// Node Preview Component
// =============================================================================

interface TreeNodePreviewProps {
  node: TreeNode | null;
}

function TreeNodePreview({ node }: TreeNodePreviewProps) {
  if (!node) return null;

  return (
    <div className="tree-preview">
      <div className="preview-header">
        <span className="preview-type">{node.type.replace('.', ' ')}</span>
        <span className="preview-time">
          {new Date(node.timestamp).toLocaleString()}
        </span>
      </div>
      <div className="preview-content">{node.summary}</div>
      {node.isBranchPoint && (
        <div className="preview-branches">
          {node.childCount} branch{node.childCount !== 1 ? 'es' : ''} from this
          point
        </div>
      )}
    </div>
  );
}

// =============================================================================
// Compact Tree View (for sidebar)
// =============================================================================

export interface CompactTreeProps {
  nodes: TreeNode[];
  headNodeId?: string;
  onNodeClick?: (nodeId: string, action: 'fork' | 'select') => void;
}

export function CompactTree({ nodes, headNodeId, onNodeClick }: CompactTreeProps) {
  // Show only path to HEAD, simplified
  const pathNodes = useMemo(() => {
    const nodeMap = new Map(nodes.map((n) => [n.id, n]));
    const path: TreeNode[] = [];

    if (headNodeId) {
      let current = headNodeId;
      while (current) {
        const node = nodeMap.get(current);
        if (node) {
          path.unshift(node); // Add to beginning
          if (node.parentId) {
            current = node.parentId;
          } else {
            break;
          }
        } else {
          break;
        }
      }
    }

    return path;
  }, [nodes, headNodeId]);

  if (pathNodes.length === 0) {
    return <div className="compact-tree empty">No history</div>;
  }

  // Show only key nodes: start, branch points, and recent
  const displayNodes = pathNodes.filter(
    (node, index) =>
      index === 0 || // Start
      node.isBranchPoint || // Branch points
      index >= pathNodes.length - 3, // Last 3
  );

  return (
    <div className="compact-tree">
      {displayNodes.map((node, index) => (
        <div
          key={node.id}
          className={`compact-node ${node.id === headNodeId ? 'is-head' : ''}`}
          onClick={() => onNodeClick?.(node.id, 'select')}
          title={node.summary}
        >
          <span className="compact-icon">
            {NODE_ICONS[node.type] || NODE_ICONS.default}
          </span>
          {index < displayNodes.length - 1 && (
            <span className="compact-connector">─</span>
          )}
        </div>
      ))}
    </div>
  );
}
