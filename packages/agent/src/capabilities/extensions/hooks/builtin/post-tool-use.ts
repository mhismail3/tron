/**
 * @fileoverview PostToolUse Built-in Hook
 *
 * Executes after each tool use. Responsibilities:
 * - Track file modifications
 * - Log tool usage patterns
 * - Update session statistics
 *
 * This hook maintains awareness of what files are being worked on.
 */

import type {
  HookDefinition,
  PostToolHookContext,
  HookResult,
} from '../types.js';
import { createLogger } from '@infrastructure/logging/index.js';

const logger = createLogger('hooks:post-tool-use');

/**
 * Configuration for PostToolUse hook
 */
export interface PostToolUseHookConfig {
  /** Whether to track file modifications (default: true) */
  trackFiles?: boolean;
  /** Maximum files to track (default: 20) */
  maxTrackedFiles?: number;
  /** Tools that modify files */
  fileModifyingTools?: string[];
  /** Tools that read files */
  fileReadingTools?: string[];
  /** Custom file path extractor */
  filePathExtractor?: (toolName: string, args: Record<string, unknown>) => string | null;
}

/**
 * Default tools that modify files
 */
const DEFAULT_FILE_MODIFYING_TOOLS = ['write', 'edit', 'Write', 'Edit'];

/**
 * Default tools that read files
 */
const DEFAULT_FILE_READING_TOOLS = ['read', 'Read'];

/**
 * Create the PostToolUse hook
 *
 * This hook runs after each tool use and:
 * 1. Extracts file paths from tool arguments
 * 2. Tracks tool usage patterns
 * 3. Logs tool performance metrics
 */
export function createPostToolUseHook(
  config: PostToolUseHookConfig = {}
): HookDefinition {
  const {
    trackFiles = true,
    maxTrackedFiles = 20,
    fileModifyingTools = DEFAULT_FILE_MODIFYING_TOOLS,
    fileReadingTools = DEFAULT_FILE_READING_TOOLS,
    filePathExtractor,
  } = config;

  // Track recent files for deduplication
  const recentFiles = new Set<string>();

  return {
    name: 'builtin:post-tool-use',
    type: 'PostToolUse',
    description: 'Tracks file modifications and tool usage patterns',
    priority: 50, // Run after higher-priority hooks

    handler: async (ctx): Promise<HookResult> => {
      const context = ctx as PostToolHookContext;

      logger.debug('PostToolUse hook executing', {
        toolName: context.toolName,
        toolCallId: context.toolCallId,
        duration: context.duration,
        isError: context.result.isError,
      });

      // Skip if tracking is disabled
      if (!trackFiles) {
        return { action: 'continue' };
      }

      // Check if this is a file-related tool
      const isModifyingTool = fileModifyingTools.includes(context.toolName);
      const isReadingTool = fileReadingTools.includes(context.toolName);

      if (!isModifyingTool && !isReadingTool) {
        return { action: 'continue' };
      }

      // Extract file path
      const filePath = filePathExtractor
        ? filePathExtractor(context.toolName, context.data as Record<string, unknown>)
        : extractFilePath(context.toolName, context.data as Record<string, unknown>);

      if (!filePath) {
        return { action: 'continue' };
      }

      // Deduplicate
      if (recentFiles.has(filePath)) {
        return { action: 'continue' };
      }

      recentFiles.add(filePath);

      // Limit recent files set size
      if (recentFiles.size > maxTrackedFiles * 2) {
        const toRemove = Array.from(recentFiles).slice(0, maxTrackedFiles);
        toRemove.forEach(f => recentFiles.delete(f));
      }

      // Log metrics
      if (context.result.isError) {
        logger.warn('Tool execution failed', {
          toolName: context.toolName,
          filePath,
          duration: context.duration,
        });
      } else {
        logger.debug('Tool execution succeeded', {
          toolName: context.toolName,
          filePath,
          duration: context.duration,
          operation: isModifyingTool ? 'modify' : 'read',
        });
      }

      return {
        action: 'continue',
        modifications: {
          fileTracked: filePath,
          operation: isModifyingTool ? 'modify' : 'read',
        },
      };
    },
  };
}

/**
 * Extract file path from tool arguments
 */
export function extractFilePath(
  toolName: string,
  args: Record<string, unknown>
): string | null {
  // Common argument names for file paths
  const pathKeys = ['file_path', 'filePath', 'path', 'file', 'target'];

  for (const key of pathKeys) {
    const value = args[key];
    if (typeof value === 'string' && value.length > 0) {
      return value;
    }
  }

  // Tool-specific extraction
  const toolLower = toolName.toLowerCase();

  if (toolLower === 'bash' || toolLower === 'shell') {
    // Try to extract file paths from bash commands
    const command = args['command'] as string;
    if (command) {
      return extractPathFromBashCommand(command);
    }
  }

  return null;
}

/**
 * Extract file path from bash command (best effort)
 */
function extractPathFromBashCommand(command: string): string | null {
  // Simple patterns for common file operations
  const patterns = [
    /(?:cat|less|more|head|tail|vim|nano|code)\s+([^\s|><&;]+)/,
    /(?:cp|mv|rm)\s+(?:-[rf]*\s+)?([^\s|><&;]+)/,
    /(?:touch|mkdir)\s+(?:-p\s+)?([^\s|><&;]+)/,
  ];

  for (const pattern of patterns) {
    const match = command.match(pattern);
    if (match?.[1]) {
      return match[1];
    }
  }

  return null;
}

/**
 * Default export for convenience
 */
export default createPostToolUseHook;
