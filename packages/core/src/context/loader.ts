/**
 * @fileoverview Hierarchical Context Loader
 *
 * Loads and merges context files (AGENTS.md, CLAUDE.md) from multiple
 * locations following a hierarchical priority system:
 *
 * 1. Global context: ~/.agent/AGENTS.md
 * 2. Project context: ./AGENTS.md or ./CLAUDE.md
 * 3. Directory context: ./subdir/AGENTS.md (closest to working dir)
 *
 * Context files are merged with more specific contexts having higher priority.
 *
 * @example
 * ```typescript
 * const loader = new ContextLoader({ userHome: '~', projectRoot: '/project' });
 * const context = await loader.load('/project/src/components');
 * // Returns merged context from all levels
 * ```
 */
import * as fs from 'fs/promises';
import * as path from 'path';
import { createLogger } from '../logging/logger.js';

const logger = createLogger('context:loader');

// =============================================================================
// Types
// =============================================================================

export interface ContextLoaderConfig {
  /** User home directory (for global context) */
  userHome?: string;
  /** Project root directory */
  projectRoot?: string;
  /** Context file names to search for (default: AGENTS.md, CLAUDE.md) */
  contextFileNames?: string[];
  /** Agent config directory name (default: .agent) */
  agentDir?: string;
  /** Maximum directory depth to search (default: 10) */
  maxDepth?: number;
  /** Whether to cache loaded contexts (default: true) */
  cacheEnabled?: boolean;
}

export interface ContextFile {
  /** Absolute path to the file */
  path: string;
  /** File content */
  content: string;
  /** Source level (global, project, directory) */
  level: 'global' | 'project' | 'directory';
  /** Depth from project root (0 = root) */
  depth: number;
  /** Last modified timestamp */
  modifiedAt: Date;
}

export interface LoadedContext {
  /** Merged context string */
  merged: string;
  /** Individual context files (ordered by priority) */
  files: ContextFile[];
  /** Load timestamp */
  loadedAt: Date;
}

export interface ContextSection {
  /** Section header/title */
  title: string;
  /** Section content */
  content: string;
  /** Source file path */
  source: string;
  /** Priority level (higher = more specific) */
  priority: number;
}

// =============================================================================
// Context Loader Implementation
// =============================================================================

export class ContextLoader {
  private config: Required<ContextLoaderConfig>;
  private cache: Map<string, LoadedContext> = new Map();

  constructor(config: ContextLoaderConfig = {}) {
    this.config = {
      userHome: process.env.HOME ?? '',
      projectRoot: process.cwd(),
      contextFileNames: ['AGENTS.md', 'CLAUDE.md'],
      agentDir: '.agent',
      maxDepth: 10,
      cacheEnabled: true,
      ...config,
    };
  }

  /**
   * Load context for a specific directory
   */
  async load(targetDir?: string): Promise<LoadedContext> {
    const dir = targetDir || this.config.projectRoot;
    const cacheKey = dir;

    // Check cache
    if (this.config.cacheEnabled && this.cache.has(cacheKey)) {
      const cached = this.cache.get(cacheKey)!;
      // Validate cache freshness (check if files have changed)
      if (await this.isCacheValid(cached)) {
        logger.debug('Returning cached context', { dir });
        return cached;
      }
    }

    const files: ContextFile[] = [];

    // 1. Load global context
    const globalContext = await this.loadGlobalContext();
    if (globalContext) {
      files.push(globalContext);
    }

    // 2. Load project context
    const projectContext = await this.loadProjectContext();
    if (projectContext) {
      files.push(projectContext);
    }

    // 3. Load directory context (walk from project root to target)
    const dirContexts = await this.loadDirectoryContexts(dir);
    files.push(...dirContexts);

    // Merge contexts
    const merged = this.mergeContexts(files);

    const result: LoadedContext = {
      merged,
      files,
      loadedAt: new Date(),
    };

    // Cache result
    if (this.config.cacheEnabled) {
      this.cache.set(cacheKey, result);
    }

    logger.info('Context loaded', {
      fileCount: files.length,
      mergedLength: merged.length,
      targetDir: dir,
    });

    return result;
  }

  /**
   * Load only global context
   */
  async loadGlobalContext(): Promise<ContextFile | null> {
    const globalDir = path.join(this.config.userHome, this.config.agentDir);

    for (const fileName of this.config.contextFileNames) {
      const filePath = path.join(globalDir, fileName);
      try {
        const content = await fs.readFile(filePath, 'utf-8');
        const stats = await fs.stat(filePath);

        return {
          path: filePath,
          content,
          level: 'global',
          depth: -1,
          modifiedAt: stats.mtime,
        };
      } catch {
        // File doesn't exist, continue
      }
    }

    return null;
  }

  /**
   * Load project-level context
   */
  async loadProjectContext(): Promise<ContextFile | null> {
    // Check .agent directory first
    const agentDir = path.join(this.config.projectRoot, this.config.agentDir);
    for (const fileName of this.config.contextFileNames) {
      const filePath = path.join(agentDir, fileName);
      try {
        const content = await fs.readFile(filePath, 'utf-8');
        const stats = await fs.stat(filePath);

        return {
          path: filePath,
          content,
          level: 'project',
          depth: 0,
          modifiedAt: stats.mtime,
        };
      } catch {
        // Continue to next file name
      }
    }

    // Check project root
    for (const fileName of this.config.contextFileNames) {
      const filePath = path.join(this.config.projectRoot, fileName);
      try {
        const content = await fs.readFile(filePath, 'utf-8');
        const stats = await fs.stat(filePath);

        return {
          path: filePath,
          content,
          level: 'project',
          depth: 0,
          modifiedAt: stats.mtime,
        };
      } catch {
        // Continue
      }
    }

    return null;
  }

  /**
   * Load directory-level contexts from project root to target
   */
  async loadDirectoryContexts(targetDir: string): Promise<ContextFile[]> {
    const contexts: ContextFile[] = [];

    // Ensure target is within project
    const relative = path.relative(this.config.projectRoot, targetDir);
    if (relative.startsWith('..')) {
      return contexts;
    }

    // Walk from project root to target
    const parts = relative.split(path.sep).filter(Boolean);
    let currentPath = this.config.projectRoot;
    let depth = 0;

    for (const part of parts.slice(0, this.config.maxDepth)) {
      currentPath = path.join(currentPath, part);
      depth++;

      for (const fileName of this.config.contextFileNames) {
        const filePath = path.join(currentPath, fileName);
        try {
          const content = await fs.readFile(filePath, 'utf-8');
          const stats = await fs.stat(filePath);

          contexts.push({
            path: filePath,
            content,
            level: 'directory',
            depth,
            modifiedAt: stats.mtime,
          });

          // Only one context file per directory
          break;
        } catch {
          // Continue
        }
      }
    }

    return contexts;
  }

  /**
   * Merge multiple contexts into one
   */
  mergeContexts(files: ContextFile[]): string {
    if (files.length === 0) {
      return '';
    }

    // Sort by priority (global first, then by depth)
    const sorted = [...files].sort((a, b) => {
      if (a.level === 'global' && b.level !== 'global') return -1;
      if (a.level !== 'global' && b.level === 'global') return 1;
      return a.depth - b.depth;
    });

    const sections: string[] = [];

    for (const file of sorted) {
      const levelLabel = this.getLevelLabel(file.level, file.depth);
      const relativePath = this.getRelativePath(file.path);

      sections.push(`<!-- Context: ${levelLabel} (${relativePath}) -->`);
      sections.push(file.content.trim());
      sections.push('');
    }

    return sections.join('\n').trim();
  }

  /**
   * Parse a context file into sections
   */
  parseIntoSections(file: ContextFile): ContextSection[] {
    const sections: ContextSection[] = [];
    const lines = file.content.split('\n');

    let currentTitle = '';
    let currentContent: string[] = [];
    let priority = file.level === 'global' ? 0 : file.level === 'project' ? 10 : 10 + file.depth;

    for (const line of lines) {
      // Check for markdown headers
      const headerMatch = line.match(/^(#{1,3})\s+(.+)$/);
      if (headerMatch) {
        // Save previous section
        if (currentTitle || currentContent.length > 0) {
          sections.push({
            title: currentTitle,
            content: currentContent.join('\n').trim(),
            source: file.path,
            priority,
          });
        }

        currentTitle = headerMatch[2]!;
        currentContent = [];
      } else {
        currentContent.push(line);
      }
    }

    // Save final section
    if (currentTitle || currentContent.length > 0) {
      sections.push({
        title: currentTitle,
        content: currentContent.join('\n').trim(),
        source: file.path,
        priority,
      });
    }

    return sections;
  }

  /**
   * Get context for a specific section/topic
   */
  async getSection(
    targetDir: string,
    sectionPattern: string | RegExp
  ): Promise<ContextSection[]> {
    const context = await this.load(targetDir);
    const allSections: ContextSection[] = [];

    for (const file of context.files) {
      const sections = this.parseIntoSections(file);
      allSections.push(...sections);
    }

    const pattern = typeof sectionPattern === 'string'
      ? new RegExp(sectionPattern, 'i')
      : sectionPattern;

    // Filter and sort by priority (highest first for matching)
    return allSections
      .filter(s => pattern.test(s.title) || pattern.test(s.content))
      .sort((a, b) => b.priority - a.priority);
  }

  /**
   * Clear the context cache
   */
  clearCache(): void {
    this.cache.clear();
    logger.debug('Context cache cleared');
  }

  /**
   * Invalidate cache for a specific directory
   */
  invalidateCache(dir: string): void {
    this.cache.delete(dir);
    logger.debug('Cache invalidated', { dir });
  }

  /**
   * Watch for context file changes
   */
  async watch(
    onChange: (context: LoadedContext) => void
  ): Promise<() => void> {
    const paths = [
      path.join(this.config.userHome, this.config.agentDir),
      this.config.projectRoot,
    ];

    const watchers: Array<{ close: () => void }> = [];

    for (const watchPath of paths) {
      try {
        const watcher = fs.watch(watchPath, { recursive: true });
        let closed = false;

        (async () => {
          try {
            for await (const event of watcher) {
              if (closed) break;

              // Check if it's a context file
              const fileName = event.filename;
              if (fileName && this.config.contextFileNames.some(n => fileName.endsWith(n))) {
                this.clearCache();
                const context = await this.load(this.config.projectRoot);
                onChange(context);
              }
            }
          } catch {
            // Watcher closed
          }
        })();

        watchers.push({
          close: () => {
            closed = true;
            (watcher as unknown as { close: () => void }).close();
          },
        });
      } catch (error) {
        logger.warn('Could not watch path', { path: watchPath, error });
      }
    }

    return () => {
      for (const w of watchers) {
        w.close();
      }
      logger.debug('Context watchers closed');
    };
  }

  /**
   * Find all context files in the project
   */
  async findAllContextFiles(): Promise<ContextFile[]> {
    const files: ContextFile[] = [];

    // Global
    const global = await this.loadGlobalContext();
    if (global) files.push(global);

    // Recursive search in project
    await this.searchDirectory(this.config.projectRoot, files, 0);

    return files;
  }

  // ===========================================================================
  // Private Helpers
  // ===========================================================================

  private async searchDirectory(
    dir: string,
    files: ContextFile[],
    depth: number
  ): Promise<void> {
    if (depth > this.config.maxDepth) return;

    try {
      const entries = await fs.readdir(dir, { withFileTypes: true });

      for (const entry of entries) {
        const fullPath = path.join(dir, entry.name);

        if (entry.isFile() && this.config.contextFileNames.includes(entry.name)) {
          try {
            const content = await fs.readFile(fullPath, 'utf-8');
            const stats = await fs.stat(fullPath);

            files.push({
              path: fullPath,
              content,
              level: depth === 0 ? 'project' : 'directory',
              depth,
              modifiedAt: stats.mtime,
            });
          } catch {
            // Skip unreadable files
          }
        } else if (entry.isDirectory() && !entry.name.startsWith('.') && entry.name !== 'node_modules') {
          await this.searchDirectory(fullPath, files, depth + 1);
        }
      }
    } catch {
      // Skip inaccessible directories
    }
  }

  private async isCacheValid(cached: LoadedContext): Promise<boolean> {
    for (const file of cached.files) {
      try {
        const stats = await fs.stat(file.path);
        if (stats.mtime.getTime() > file.modifiedAt.getTime()) {
          return false;
        }
      } catch {
        return false; // File no longer exists
      }
    }
    return true;
  }

  private getLevelLabel(level: string, depth: number): string {
    if (level === 'global') return 'Global';
    if (level === 'project') return 'Project';
    return `Directory (depth ${depth})`;
  }

  private getRelativePath(filePath: string): string {
    if (filePath.startsWith(this.config.userHome)) {
      return '~' + filePath.slice(this.config.userHome.length);
    }
    return path.relative(this.config.projectRoot, filePath) || filePath;
  }
}

// =============================================================================
// Factory Function
// =============================================================================

export function createContextLoader(config?: ContextLoaderConfig): ContextLoader {
  return new ContextLoader(config);
}
