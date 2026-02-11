/**
 * @fileoverview Rules File Discovery
 *
 * Filesystem scanner that finds CLAUDE.md and AGENTS.md files
 * throughout the project tree. Discovers files in:
 * - `.claude/CLAUDE.md` / `.claude/AGENTS.md` (and .tron/, .agent/ variants)
 * - Standalone `CLAUDE.md` / `AGENTS.md` in any directory (when enabled)
 *
 * Case-insensitive matching: claude.md, CLAUDE.md, agents.md, AGENTS.md.
 */

import * as fs from 'fs';
import * as path from 'path';

export interface DiscoveredRulesFile {
  /** Absolute path */
  path: string;
  /** Relative to project root */
  relativePath: string;
  /** File content (raw, no frontmatter stripping) */
  content: string;
  /** Directory that this rule applies to (relative). "" = root/global */
  scopeDir: string;
  /** true = root-level (scopeDir is "") */
  isGlobal: boolean;
  /** true = not inside an agent dir (.claude/.tron/.agent) */
  isStandalone: boolean;
  /** File size in bytes */
  sizeBytes: number;
  /** Last modification time */
  modifiedAt: Date;
}

export interface RulesDiscoveryConfig {
  projectRoot: string;
  /** Also discover standalone CLAUDE.md/AGENTS.md outside agent dirs. Default: true */
  discoverStandaloneFiles?: boolean;
  /** Skip root-level files (ContextLoader handles those). Default: true */
  excludeRootLevel?: boolean;
  /** Maximum directory depth to scan. Default: 10 */
  maxDepth?: number;
  /** Directories to exclude from scanning. Default: standard set */
  excludeDirs?: string[];
}

const CONTEXT_FILENAMES = new Set(['claude.md', 'agents.md']);
const AGENT_DIRS = ['.claude', '.tron', '.agent'];
const DEFAULT_EXCLUDE_DIRS = new Set([
  'node_modules', '.git', '.hg', '.svn',
  'dist', 'build', 'out', '.next', '.nuxt',
  'coverage', '.nyc_output', '__pycache__',
]);
const DEFAULT_MAX_DEPTH = 10;

/**
 * Discover CLAUDE.md/AGENTS.md files throughout the project tree.
 *
 * Walks from projectRoot, looking for context files in agent dirs
 * (.claude/, .tron/, .agent/) and optionally as standalone files.
 * Returns files classified as global or scoped based on their location.
 */
export async function discoverRulesFiles(config: RulesDiscoveryConfig): Promise<DiscoveredRulesFile[]> {
  const {
    projectRoot,
    discoverStandaloneFiles = true,
    excludeRootLevel = true,
    maxDepth = DEFAULT_MAX_DEPTH,
    excludeDirs,
  } = config;

  const excludeSet = excludeDirs ? new Set(excludeDirs) : DEFAULT_EXCLUDE_DIRS;
  const results: DiscoveredRulesFile[] = [];
  const seenRealPaths = new Set<string>();

  scanDirectory(
    projectRoot,
    projectRoot,
    excludeSet,
    maxDepth,
    0,
    results,
    discoverStandaloneFiles,
    excludeRootLevel,
    seenRealPaths,
  );

  return results;
}

function scanDirectory(
  dir: string,
  projectRoot: string,
  excludeDirs: Set<string>,
  maxDepth: number,
  currentDepth: number,
  results: DiscoveredRulesFile[],
  discoverStandalone: boolean,
  excludeRootLevel: boolean,
  seenRealPaths: Set<string>,
): void {
  if (currentDepth > maxDepth) return;

  const isRoot = dir === projectRoot;

  // Check agent dirs for context files at this level
  for (const agentDir of AGENT_DIRS) {
    const agentDirPath = path.join(dir, agentDir);
    try {
      const entries = fs.readdirSync(agentDirPath, { withFileTypes: true });
      for (const entry of entries) {
        if (!entry.isFile()) continue;
        if (!isContextFilename(entry.name)) continue;

        const filePath = path.join(agentDirPath, entry.name);
        if (isRoot && excludeRootLevel) continue;

        tryAddFile(filePath, projectRoot, false, results, seenRealPaths);
      }
    } catch {
      // Agent dir doesn't exist, skip
    }
  }

  // Check for standalone context files at this level (not inside agent dirs)
  if (discoverStandalone) {
    try {
      const entries = fs.readdirSync(dir, { withFileTypes: true });
      for (const entry of entries) {
        if (!entry.isFile()) continue;
        if (!isContextFilename(entry.name)) continue;

        const filePath = path.join(dir, entry.name);
        if (isRoot && excludeRootLevel) continue;

        tryAddFile(filePath, projectRoot, true, results, seenRealPaths);
      }
    } catch {
      // Can't read dir, skip
    }
  }

  // Recurse into subdirectories
  if (currentDepth >= maxDepth) return;

  let entries: fs.Dirent[];
  try {
    entries = fs.readdirSync(dir, { withFileTypes: true });
  } catch {
    return;
  }

  for (const entry of entries) {
    if (!entry.isDirectory()) continue;
    const name = entry.name;

    // Skip excluded and hidden directories (agent dirs are not recursed into)
    if (excludeDirs.has(name)) continue;
    if (name.startsWith('.')) continue;

    scanDirectory(
      path.join(dir, name),
      projectRoot,
      excludeDirs,
      maxDepth,
      currentDepth + 1,
      results,
      discoverStandalone,
      excludeRootLevel,
      seenRealPaths,
    );
  }
}

function isContextFilename(name: string): boolean {
  return CONTEXT_FILENAMES.has(name.toLowerCase());
}

function tryAddFile(
  filePath: string,
  projectRoot: string,
  isStandalone: boolean,
  results: DiscoveredRulesFile[],
  seenRealPaths: Set<string>,
): void {
  try {
    // Deduplicate on case-insensitive filesystem
    const realPath = fs.realpathSync(filePath);
    if (seenRealPaths.has(realPath)) return;
    seenRealPaths.add(realPath);

    const content = fs.readFileSync(filePath, 'utf-8');
    const stat = fs.statSync(filePath);
    const relativePath = path.relative(projectRoot, filePath);

    // Compute scopeDir:
    // - For agent dir files (e.g. packages/foo/.claude/CLAUDE.md) → "packages/foo"
    // - For standalone files (e.g. packages/foo/CLAUDE.md) → "packages/foo"
    // - For root-level files → ""
    const scopeDir = computeScopeDir(relativePath, isStandalone);
    const isGlobal = scopeDir === '';

    results.push({
      path: filePath,
      relativePath,
      content,
      scopeDir,
      isGlobal,
      isStandalone,
      sizeBytes: stat.size,
      modifiedAt: stat.mtime,
    });
  } catch {
    // File can't be read, skip
  }
}

/**
 * Compute the scope directory for a discovered file.
 *
 * For agent dir files: parent of the agent dir
 *   e.g. "packages/foo/.claude/CLAUDE.md" → "packages/foo"
 *   e.g. ".claude/CLAUDE.md" → ""
 *
 * For standalone files: parent directory
 *   e.g. "packages/foo/CLAUDE.md" → "packages/foo"
 *   e.g. "CLAUDE.md" → ""
 */
function computeScopeDir(relativePath: string, isStandalone: boolean): string {
  if (isStandalone) {
    const dir = path.dirname(relativePath);
    return dir === '.' ? '' : dir;
  }

  // Agent dir file: go up two levels (past .claude/ and the filename)
  // e.g. "packages/foo/.claude/CLAUDE.md" → dirname = "packages/foo/.claude" → dirname = "packages/foo"
  const agentDir = path.dirname(relativePath);
  const parentDir = path.dirname(agentDir);
  return parentDir === '.' ? '' : parentDir;
}
