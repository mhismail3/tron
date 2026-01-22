/**
 * @fileoverview File Completion
 *
 * File path auto-completion with @ prefix trigger.
 * Uses fuzzy matching similar to fzf for quick file selection.
 */

import * as fs from 'fs/promises';
import * as path from 'path';

/**
 * Check if query matches target using fuzzy matching
 * Characters in query must appear in order in target
 */
export function fuzzyMatch(query: string, target: string): boolean {
  if (!query) return true;

  const q = query.toLowerCase();
  const t = target.toLowerCase();

  let qi = 0;
  for (let ti = 0; ti < t.length && qi < q.length; ti++) {
    if (t[ti] === q[qi]) {
      qi++;
    }
  }

  return qi === q.length;
}

/**
 * Score a match for ranking
 * Higher scores are better matches
 */
export function scoreMatch(query: string, target: string): number {
  if (!fuzzyMatch(query, target)) return 0;

  const q = query.toLowerCase();
  const t = target.toLowerCase();

  let score = 100;

  // Exact match bonus
  if (t === q) score += 50;

  // Prefix match bonus
  if (t.startsWith(q)) score += 30;

  // Filename match bonus
  const filename = path.basename(target).toLowerCase();
  if (filename.startsWith(q)) score += 25;
  if (filename === q) score += 20;

  // Penalize longer paths
  score -= target.split('/').length * 2;

  // Penalize longer targets
  score -= target.length * 0.5;

  return Math.max(0, score);
}

/**
 * File completion with @ trigger
 */
export class FileCompletion {
  readonly trigger = '@';
  private rootDir: string;
  private files: string[] = [];
  private filesLoaded = false;

  constructor(rootDir: string) {
    this.rootDir = rootDir;
  }

  /**
   * Set files directly (useful for testing or pre-loaded file lists)
   */
  setFiles(files: string[]): void {
    this.files = files;
    this.filesLoaded = true;
  }

  /**
   * Load files from the root directory
   */
  async loadFiles(maxDepth = 5): Promise<void> {
    if (this.filesLoaded) return;

    this.files = [];
    await this.walkDir(this.rootDir, '', maxDepth);
    this.filesLoaded = true;
  }

  /**
   * Recursively walk directory and collect files
   */
  private async walkDir(
    dir: string,
    prefix: string,
    depth: number
  ): Promise<void> {
    if (depth <= 0) return;

    try {
      const entries = await fs.readdir(dir, { withFileTypes: true });

      for (const entry of entries) {
        // Skip hidden files and common ignore patterns
        if (entry.name.startsWith('.')) continue;
        if (entry.name === 'node_modules') continue;
        if (entry.name === 'dist') continue;
        if (entry.name === 'build') continue;

        const relativePath = prefix ? `${prefix}/${entry.name}` : entry.name;

        if (entry.isDirectory()) {
          await this.walkDir(
            path.join(dir, entry.name),
            relativePath,
            depth - 1
          );
        } else if (entry.isFile()) {
          this.files.push(relativePath);
        }
      }
    } catch {
      // Ignore errors (permission denied, etc.)
    }
  }

  /**
   * Search for files matching the query
   */
  async search(query: string, limit = 20): Promise<string[]> {
    if (!this.filesLoaded) {
      await this.loadFiles();
    }

    // Filter and score matches
    const matches = this.files
      .filter((file) => fuzzyMatch(query, file))
      .map((file) => ({
        file,
        score: scoreMatch(query, file),
      }))
      .sort((a, b) => b.score - a.score)
      .slice(0, limit)
      .map((m) => m.file);

    return matches;
  }

  /**
   * Get the full path for a selected file
   */
  getFullPath(relativePath: string): string {
    return path.join(this.rootDir, relativePath);
  }
}
