/**
 * @fileoverview Hook Discovery Module
 *
 * Discovers and loads user-defined hooks from the filesystem.
 * Supports both TypeScript/JavaScript hooks and shell script wrappers.
 *
 * Hook locations searched (in order):
 * 1. `.agent/hooks/` - Project-level hooks
 * 2. `~/.config/tron/hooks/` - User-level hooks
 * 3. Custom paths via configuration
 *
 * Hook file naming convention:
 * - `pre-tool-use.ts` or `pre-tool-use.js` - TypeScript/JavaScript hooks
 * - `pre-tool-use.sh` - Shell script hooks
 * - `session-start.ts` - Event-specific hooks
 *
 * @example
 * ```typescript
 * import { discoverHooks, loadDiscoveredHooks } from './discovery';
 *
 * const discovered = await discoverHooks({ projectPath: '/path/to/project' });
 * const hooks = await loadDiscoveredHooks(discovered);
 * ```
 */

import * as fs from 'fs/promises';
import * as path from 'path';
import { spawn } from 'child_process';
import type { HookDefinition, HookType, AnyHookContext, HookResult } from './types.js';
import { createLogger } from '../logging/index.js';
import { getSettings } from '../settings/index.js';

const logger = createLogger('hooks:discovery');

// Get hook settings (loaded lazily on first access)
function getHookSettings() {
  return getSettings().hooks;
}

/**
 * Discovered hook information
 */
export interface DiscoveredHook {
  /** Unique name for this hook */
  name: string;
  /** Absolute path to hook file */
  path: string;
  /** Hook type derived from filename */
  type: HookType;
  /** Whether this is a shell script */
  isShellScript: boolean;
  /** Source location (project, user, custom) */
  source: 'project' | 'user' | 'custom';
  /** Priority if specified in filename (e.g., 100-pre-tool-use.ts) */
  priority?: number;
}

/**
 * Hook discovery configuration
 */
export interface DiscoveryConfig {
  /** Project root path */
  projectPath?: string;
  /** User home directory */
  userHome?: string;
  /** Additional paths to search */
  additionalPaths?: string[];
  /** Whether to search user-level hooks (default: true) */
  includeUserHooks?: boolean;
  /** File extensions to consider (default: .ts, .js, .sh) */
  extensions?: string[];
}

/**
 * Get default hook directory names from settings
 */
function getDefaultProjectHookDir(): string {
  return getHookSettings().projectDir;
}

function getDefaultUserHookDir(): string {
  return getHookSettings().userDir;
}

/**
 * Get default file extensions from settings
 */
function getDefaultExtensions(): string[] {
  return getHookSettings().extensions;
}

/**
 * Map filename patterns to hook types
 */
const HOOK_TYPE_MAP: Record<string, HookType> = {
  'pre-tool-use': 'PreToolUse',
  'pre-tool': 'PreToolUse',
  'post-tool-use': 'PostToolUse',
  'post-tool': 'PostToolUse',
  'session-start': 'SessionStart',
  'session-end': 'SessionEnd',
  'stop': 'Stop',
  'subagent-stop': 'SubagentStop',
  'user-prompt-submit': 'UserPromptSubmit',
  'user-prompt': 'UserPromptSubmit',
  'pre-compact': 'PreCompact',
  'notification': 'Notification',
};

/**
 * Discover hooks from filesystem
 */
export async function discoverHooks(
  config: DiscoveryConfig = {}
): Promise<DiscoveredHook[]> {
  const {
    projectPath = process.cwd(),
    userHome = process.env.HOME ?? '',
    additionalPaths = [],
    includeUserHooks = true,
    extensions = getDefaultExtensions(),
  } = config;

  const discovered: DiscoveredHook[] = [];
  const searchPaths: Array<{ path: string; source: 'project' | 'user' | 'custom' }> = [];

  // 1. Project-level hooks
  const projectHookPath = path.join(projectPath, getDefaultProjectHookDir());
  searchPaths.push({ path: projectHookPath, source: 'project' });

  // 2. User-level hooks
  if (includeUserHooks && userHome) {
    const userHookPath = path.join(userHome, getDefaultUserHookDir());
    searchPaths.push({ path: userHookPath, source: 'user' });
  }

  // 3. Additional paths
  for (const customPath of additionalPaths) {
    searchPaths.push({ path: customPath, source: 'custom' });
  }

  // Search each path
  for (const { path: searchPath, source } of searchPaths) {
    try {
      const files = await fs.readdir(searchPath);

      for (const file of files) {
        const ext = path.extname(file);
        if (!extensions.includes(ext)) continue;

        const baseName = path.basename(file, ext);
        const hookInfo = parseHookFilename(baseName);

        if (hookInfo) {
          discovered.push({
            name: `${source}:${hookInfo.name}`,
            path: path.join(searchPath, file),
            type: hookInfo.type,
            isShellScript: ext === '.sh',
            source,
            priority: hookInfo.priority,
          });

          logger.debug('Discovered hook', {
            name: `${source}:${hookInfo.name}`,
            type: hookInfo.type,
            path: path.join(searchPath, file),
          });
        }
      }
    } catch (error) {
      // Directory doesn't exist or isn't readable - that's fine
      if ((error as NodeJS.ErrnoException).code !== 'ENOENT') {
        logger.warn('Error scanning hook directory', {
          path: searchPath,
          error: error instanceof Error ? error.message : String(error),
        });
      }
    }
  }

  logger.info('Hook discovery complete', { count: discovered.length });
  return discovered;
}

/**
 * Parse hook filename to extract type and priority
 */
function parseHookFilename(
  baseName: string
): { name: string; type: HookType; priority?: number } | null {
  // Check for priority prefix (e.g., "100-pre-tool-use")
  let priority: number | undefined;
  let cleanName = baseName;

  const priorityMatch = baseName.match(/^(\d+)-(.+)$/);
  if (priorityMatch && priorityMatch[1] && priorityMatch[2]) {
    priority = parseInt(priorityMatch[1], 10);
    cleanName = priorityMatch[2];
  }

  // Normalize to lowercase and replace underscores
  const normalized = cleanName.toLowerCase().replace(/_/g, '-');

  // Look up hook type
  const hookType = HOOK_TYPE_MAP[normalized];
  if (!hookType) {
    return null;
  }

  return {
    name: cleanName,
    type: hookType,
    priority,
  };
}

/**
 * Load discovered hooks into HookDefinition format
 */
export async function loadDiscoveredHooks(
  discovered: DiscoveredHook[]
): Promise<HookDefinition[]> {
  const hooks: HookDefinition[] = [];

  for (const info of discovered) {
    try {
      const hook = info.isShellScript
        ? createShellHook(info)
        : await loadJavaScriptHook(info);

      if (hook) {
        hooks.push(hook);
        logger.debug('Loaded hook', { name: info.name, type: info.type });
      }
    } catch (error) {
      logger.error('Failed to load hook', {
        name: info.name,
        path: info.path,
        error: error instanceof Error ? error.message : String(error),
      });
    }
  }

  logger.info('Hooks loaded', { count: hooks.length });
  return hooks;
}

/**
 * Create a hook definition that wraps a shell script
 */
function createShellHook(info: DiscoveredHook): HookDefinition {
  return {
    name: info.name,
    type: info.type,
    description: `Shell script hook from ${info.source}`,
    priority: info.priority ?? 0,

    handler: async (context: AnyHookContext): Promise<HookResult> => {
      return executeShellHook(info.path, context);
    },
  };
}

/**
 * Execute a shell script hook
 */
async function executeShellHook(
  scriptPath: string,
  context: AnyHookContext
): Promise<HookResult> {
  return new Promise((resolve) => {
    const settings = getHookSettings();
    const child = spawn(scriptPath, [], {
      env: {
        ...process.env,
        HOOK_CONTEXT: JSON.stringify(context),
        HOOK_TYPE: context.hookType,
        HOOK_SESSION_ID: context.sessionId,
      },
      timeout: settings.discoveryTimeoutMs,
    });

    let stdout = '';
    let stderr = '';

    child.stdout.on('data', (data) => {
      stdout += data.toString();
    });

    child.stderr.on('data', (data) => {
      stderr += data.toString();
    });

    child.on('close', (code) => {
      if (code !== 0) {
        logger.warn('Shell hook exited with error', {
          path: scriptPath,
          code,
          stderr,
        });
        resolve({ action: 'continue' });
        return;
      }

      // Try to parse JSON result from stdout
      try {
        const result = JSON.parse(stdout.trim());
        resolve({
          action: result.action ?? 'continue',
          reason: result.reason,
          message: result.message,
          modifications: result.modifications,
        });
      } catch {
        // Non-JSON output treated as message
        resolve({
          action: 'continue',
          message: stdout.trim() || undefined,
        });
      }
    });

    child.on('error', (error) => {
      logger.error('Shell hook execution error', {
        path: scriptPath,
        error: error.message,
      });
      resolve({ action: 'continue' });
    });
  });
}

/**
 * Load a JavaScript/TypeScript hook module
 */
async function loadJavaScriptHook(
  info: DiscoveredHook
): Promise<HookDefinition | null> {
  try {
    // Dynamic import for ES modules
    const module = await import(info.path);

    // Check for default export
    if (module.default && typeof module.default === 'object') {
      return {
        ...module.default,
        name: info.name,
        type: info.type,
        priority: info.priority ?? module.default.priority ?? 0,
      };
    }

    // Check for named export matching hook type
    const hookKey = `${info.type}Hook`;
    if (module[hookKey] && typeof module[hookKey] === 'object') {
      return {
        ...module[hookKey],
        name: info.name,
        type: info.type,
        priority: info.priority ?? module[hookKey].priority ?? 0,
      };
    }

    // Check for handler function
    if (module.handler && typeof module.handler === 'function') {
      return {
        name: info.name,
        type: info.type,
        priority: info.priority ?? 0,
        handler: module.handler,
      };
    }

    logger.warn('No valid hook export found', { path: info.path });
    return null;
  } catch (error) {
    logger.error('Failed to import hook module', {
      path: info.path,
      error: error instanceof Error ? error.message : String(error),
    });
    return null;
  }
}

/**
 * Watch for hook file changes (for development)
 */
export async function watchHooks(
  config: DiscoveryConfig,
  onChange: (hooks: DiscoveredHook[]) => void
): Promise<() => void> {
  const { projectPath = process.cwd() } = config;
  const hookDir = path.join(projectPath, getDefaultProjectHookDir());

  try {
    // fs.watch returns an FSWatcher which is also an AsyncIterable
    const watcher = fs.watch(hookDir, { recursive: true });
    let closed = false;

    const listener = async () => {
      const discovered = await discoverHooks(config);
      onChange(discovered);
    };

    // Use async iterator pattern
    (async () => {
      try {
        for await (const _event of watcher) {
          if (closed) break;
          // Debounce by waiting a bit
          await new Promise(resolve => setTimeout(resolve, 100));
          await listener();
        }
      } catch {
        // Watcher closed or error
      }
    })();

    logger.info('Watching for hook changes', { path: hookDir });

    return () => {
      closed = true;
      // The FSWatcher returned by fs.watch has a close method
      // Cast to access it since the async iterator type doesn't expose it
      (watcher as unknown as { close: () => void }).close();
      logger.debug('Hook watcher closed');
    };
  } catch (error) {
    logger.warn('Could not watch hooks directory', {
      path: hookDir,
      error: error instanceof Error ? error.message : String(error),
    });
    return () => {}; // No-op cleanup
  }
}
