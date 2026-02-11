/**
 * @fileoverview Rules Index
 *
 * In-memory index that answers "which rules match this file path?"
 * using directory-prefix matching. No glob patterns — a rule's scopeDir
 * is a simple directory prefix that activates when the agent touches
 * any file under that directory.
 */

import type { DiscoveredRulesFile } from './rules-discovery.js';

/**
 * Index of discovered rules files with directory-prefix matching.
 *
 * Separates rules into global (always-on) and scoped (directory-matched).
 * Scoped rules are sorted by scopeDir length (most specific first) for
 * deterministic matching order.
 */
export class RulesIndex {
  private globalRules: DiscoveredRulesFile[];
  private scopedRules: DiscoveredRulesFile[];

  constructor(rulesFiles: DiscoveredRulesFile[]) {
    this.globalRules = [];
    this.scopedRules = [];

    for (const file of rulesFiles) {
      if (file.isGlobal) {
        this.globalRules.push(file);
      } else {
        this.scopedRules.push(file);
      }
    }

    // Sort scoped rules by scopeDir length descending (most specific first)
    this.scopedRules.sort((a, b) => b.scopeDir.length - a.scopeDir.length);
  }

  /**
   * Get rules that match a given relative file path.
   * A scoped rule matches if the file path starts with the rule's scopeDir + "/".
   */
  matchPath(relativePath: string): DiscoveredRulesFile[] {
    const matched: DiscoveredRulesFile[] = [];

    for (const rule of this.scopedRules) {
      if (pathStartsWith(relativePath, rule.scopeDir)) {
        matched.push(rule);
      }
    }

    return matched;
  }

  /** Get all global (always-on) rules */
  getGlobalRules(): DiscoveredRulesFile[] {
    return [...this.globalRules];
  }

  /** Get all scoped rules (for audit/debug) */
  getScopedRules(): DiscoveredRulesFile[] {
    return [...this.scopedRules];
  }

  /** Total number of indexed rules */
  get totalCount(): number {
    return this.globalRules.length + this.scopedRules.length;
  }

  /** Total number of global rules */
  get globalCount(): number {
    return this.globalRules.length;
  }

  /** Total number of scoped rules */
  get scopedCount(): number {
    return this.scopedRules.length;
  }
}

/**
 * Check if a file path falls under a scope directory.
 * e.g. pathStartsWith("packages/foo/src/bar.ts", "packages/foo") → true
 */
function pathStartsWith(filePath: string, scopeDir: string): boolean {
  if (!scopeDir) return true; // empty scope = root = matches everything
  return filePath.startsWith(scopeDir + '/') || filePath === scopeDir;
}
