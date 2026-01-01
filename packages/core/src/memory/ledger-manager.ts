/**
 * @fileoverview Markdown-based Ledger Manager
 *
 * Manages session continuity through a structured markdown file.
 * This is the primary mechanism for maintaining focus across tool calls
 * and sessions.
 *
 * @see Implementation Plan - Phase 2: Memory Layer
 */
import * as fs from 'fs/promises';
import * as path from 'path';
import { createLogger } from '../logging/logger.js';

const logger = createLogger('memory:ledger');

// =============================================================================
// Types
// =============================================================================

export interface Decision {
  choice: string;
  reason: string;
  timestamp?: string;
}

export interface Ledger {
  /** Current objective for this session */
  goal: string;
  /** Limitations and requirements to respect */
  constraints: string[];
  /** Tasks that have been completed */
  done: string[];
  /** What the agent is currently working on (drives status line) */
  now: string;
  /** Upcoming tasks in priority order */
  next: string[];
  /** Important decisions made during the session */
  decisions: Decision[];
  /** Files actively being worked on */
  workingFiles: string[];
  /** When the ledger was last updated */
  lastUpdated?: Date;
}

export interface LedgerManagerConfig {
  /** Directory to store ledger files */
  ledgerDir: string;
  /** Base name for ledger files */
  baseName?: string;
  /** Auto-save on updates */
  autoSave?: boolean;
}

// =============================================================================
// Default Empty Ledger
// =============================================================================

const EMPTY_LEDGER: Ledger = {
  goal: '',
  constraints: [],
  done: [],
  now: '',
  next: [],
  decisions: [],
  workingFiles: [],
};

// =============================================================================
// Parsing & Serialization
// =============================================================================

function parseList(section: string): string[] {
  return section
    .split('\n')
    .slice(1) // Skip header line
    .filter(line => line.trim().startsWith('-') && !line.trim().startsWith('---'))
    .map(line =>
      line
        .replace(/^-\s*\[[ xX]\]\s*/, '') // Remove checkbox
        .replace(/^-\s*/, '') // Remove bullet
        .trim()
    )
    .filter(item => item.length > 0);
}

function parseDecisions(section: string): Decision[] {
  const decisions: Decision[] = [];
  const lines = section.split('\n').slice(1);

  for (const line of lines) {
    if (!line.trim().startsWith('-')) continue;

    // Format: - **choice**: reason
    const match = line.match(/^-\s*\*\*(.+?)\*\*:\s*(.+)$/);
    if (match && match[1] && match[2]) {
      decisions.push({
        choice: match[1].trim(),
        reason: match[2].trim(),
      });
    } else {
      // Simple format: - choice
      const simpleMatch = line.match(/^-\s*(.+)$/);
      if (simpleMatch && simpleMatch[1]) {
        decisions.push({
          choice: simpleMatch[1].trim(),
          reason: '',
        });
      }
    }
  }

  return decisions;
}

function parseLedgerContent(content: string): Ledger {
  const ledger: Ledger = { ...EMPTY_LEDGER };

  // Split by ## headers
  const sections = content.split(/\n## /);

  for (const section of sections) {
    const trimmed = section.trim();

    if (trimmed.startsWith('Goal')) {
      const lines = trimmed.split('\n').slice(1);
      ledger.goal = lines.join('\n').trim();
    } else if (trimmed.startsWith('Constraints')) {
      ledger.constraints = parseList(trimmed);
    } else if (trimmed.startsWith('Done')) {
      ledger.done = parseList(trimmed);
    } else if (trimmed.startsWith('Now')) {
      const lines = trimmed.split('\n').slice(1);
      ledger.now = lines.join('\n').trim();
    } else if (trimmed.startsWith('Next')) {
      ledger.next = parseList(trimmed);
    } else if (trimmed.startsWith('Key Decisions') || trimmed.startsWith('Decisions')) {
      ledger.decisions = parseDecisions(trimmed);
    } else if (trimmed.startsWith('Working Files')) {
      ledger.workingFiles = parseList(trimmed);
    }
  }

  // Extract timestamp from footer
  const timestampMatch = content.match(/\*Last updated: (.+?)\*/);
  if (timestampMatch?.[1]) {
    try {
      ledger.lastUpdated = new Date(timestampMatch[1]);
    } catch {
      // Invalid date, ignore
    }
  }

  return ledger;
}

function serializeLedger(ledger: Ledger): string {
  const lines: string[] = [];

  lines.push('# Continuity Ledger');
  lines.push('');

  // Goal
  lines.push('## Goal');
  lines.push(ledger.goal || '_No goal set_');
  lines.push('');

  // Constraints
  if (ledger.constraints.length > 0) {
    lines.push('## Constraints');
    for (const constraint of ledger.constraints) {
      lines.push(`- ${constraint}`);
    }
    lines.push('');
  }

  // Done
  if (ledger.done.length > 0) {
    lines.push('## Done');
    for (const item of ledger.done) {
      lines.push(`- [x] ${item}`);
    }
    lines.push('');
  }

  // Now
  lines.push('## Now');
  lines.push(ledger.now || '_Nothing in progress_');
  lines.push('');

  // Next
  if (ledger.next.length > 0) {
    lines.push('## Next');
    for (const item of ledger.next) {
      lines.push(`- [ ] ${item}`);
    }
    lines.push('');
  }

  // Decisions
  if (ledger.decisions.length > 0) {
    lines.push('## Key Decisions');
    for (const decision of ledger.decisions) {
      if (decision.reason) {
        lines.push(`- **${decision.choice}**: ${decision.reason}`);
      } else {
        lines.push(`- ${decision.choice}`);
      }
    }
    lines.push('');
  }

  // Working Files
  if (ledger.workingFiles.length > 0) {
    lines.push('## Working Files');
    for (const file of ledger.workingFiles) {
      lines.push(`- ${file}`);
    }
    lines.push('');
  }

  // Footer
  lines.push('---');
  lines.push(`*Last updated: ${ledger.lastUpdated?.toISOString() || new Date().toISOString()}*`);
  lines.push('');

  return lines.join('\n');
}

// =============================================================================
// Ledger Manager Class
// =============================================================================

export class LedgerManager {
  private config: LedgerManagerConfig;
  private ledgerPath: string;
  private ledgerCache: Ledger | null = null;

  constructor(config: LedgerManagerConfig) {
    this.config = {
      baseName: 'CONTINUITY',
      autoSave: true,
      ...config,
    };
    this.ledgerPath = path.join(
      this.config.ledgerDir,
      `${this.config.baseName}.md`
    );
  }

  /**
   * Initialize the ledger manager
   */
  async initialize(): Promise<void> {
    await fs.mkdir(this.config.ledgerDir, { recursive: true });
    logger.debug('Ledger manager initialized', { ledgerDir: this.config.ledgerDir });
  }

  /**
   * Get the path to the ledger file
   */
  getPath(): string {
    return this.ledgerPath;
  }

  /**
   * Load the ledger from disk
   */
  async load(): Promise<Ledger> {
    try {
      const content = await fs.readFile(this.ledgerPath, 'utf-8');
      this.ledgerCache = parseLedgerContent(content);
      logger.debug('Ledger loaded', { path: this.ledgerPath });
      return this.ledgerCache;
    } catch (error) {
      // File doesn't exist, return empty ledger
      logger.debug('No existing ledger found, using empty', { path: this.ledgerPath });
      this.ledgerCache = { ...EMPTY_LEDGER };
      return this.ledgerCache;
    }
  }

  /**
   * Save the ledger to disk
   */
  async save(ledger: Ledger): Promise<void> {
    ledger.lastUpdated = new Date();
    const content = serializeLedger(ledger);
    await fs.writeFile(this.ledgerPath, content, 'utf-8');
    this.ledgerCache = ledger;
    logger.debug('Ledger saved', { path: this.ledgerPath });
  }

  /**
   * Get the current ledger (from cache if available)
   */
  async get(): Promise<Ledger> {
    if (this.ledgerCache) {
      return this.ledgerCache;
    }
    return this.load();
  }

  /**
   * Update partial fields of the ledger
   */
  async update(updates: Partial<Ledger>): Promise<Ledger> {
    const current = await this.get();
    const updated = { ...current, ...updates, lastUpdated: new Date() };

    if (this.config.autoSave) {
      await this.save(updated);
    } else {
      this.ledgerCache = updated;
    }

    logger.debug('Ledger updated', { updates: Object.keys(updates) });
    return updated;
  }

  /**
   * Set the current goal
   */
  async setGoal(goal: string): Promise<Ledger> {
    return this.update({ goal });
  }

  /**
   * Set what the agent is currently working on
   */
  async setNow(now: string): Promise<Ledger> {
    return this.update({ now });
  }

  /**
   * Add an item to the done list
   */
  async addDone(item: string): Promise<Ledger> {
    const current = await this.get();
    return this.update({
      done: [...current.done, item],
    });
  }

  /**
   * Add an item to the next list
   */
  async addNext(item: string): Promise<Ledger> {
    const current = await this.get();
    return this.update({
      next: [...current.next, item],
    });
  }

  /**
   * Remove an item from next (when starting it)
   */
  async popNext(): Promise<{ item: string | null; ledger: Ledger }> {
    const current = await this.get();
    if (current.next.length === 0) {
      return { item: null, ledger: current };
    }

    const [item, ...rest] = current.next;
    const ledger = await this.update({ next: rest });
    return { item: item!, ledger };
  }

  /**
   * Move current 'now' to 'done' and start next item
   */
  async completeNow(): Promise<Ledger> {
    const current = await this.get();
    const updates: Partial<Ledger> = {
      done: current.now ? [...current.done, current.now] : current.done,
    };

    // Pop next item if available
    if (current.next.length > 0) {
      const [nextItem, ...rest] = current.next;
      updates.now = nextItem;
      updates.next = rest;
    } else {
      updates.now = '';
    }

    return this.update(updates);
  }

  /**
   * Add a decision
   */
  async addDecision(choice: string, reason: string): Promise<Ledger> {
    const current = await this.get();
    return this.update({
      decisions: [
        ...current.decisions,
        { choice, reason, timestamp: new Date().toISOString() },
      ],
    });
  }

  /**
   * Add a working file
   */
  async addWorkingFile(filePath: string): Promise<Ledger> {
    const current = await this.get();
    if (current.workingFiles.includes(filePath)) {
      return current; // Already tracked
    }
    return this.update({
      workingFiles: [...current.workingFiles, filePath],
    });
  }

  /**
   * Remove a working file
   */
  async removeWorkingFile(filePath: string): Promise<Ledger> {
    const current = await this.get();
    return this.update({
      workingFiles: current.workingFiles.filter(f => f !== filePath),
    });
  }

  /**
   * Add a constraint
   */
  async addConstraint(constraint: string): Promise<Ledger> {
    const current = await this.get();
    if (current.constraints.includes(constraint)) {
      return current;
    }
    return this.update({
      constraints: [...current.constraints, constraint],
    });
  }

  /**
   * Clear the ledger for a new session
   */
  async clear(preserveGoal: boolean = false): Promise<Ledger> {
    const current = await this.get();
    return this.update({
      goal: preserveGoal ? current.goal : '',
      constraints: preserveGoal ? current.constraints : [],
      done: [],
      now: '',
      next: [],
      decisions: [],
      workingFiles: [],
    });
  }

  /**
   * Format ledger as context for the agent
   */
  async formatForContext(): Promise<string> {
    const ledger = await this.get();
    const lines: string[] = [];

    lines.push('## Current Session State');
    lines.push('');

    if (ledger.goal) {
      lines.push(`**Goal**: ${ledger.goal}`);
    }

    if (ledger.now) {
      lines.push(`**Working on**: ${ledger.now}`);
    }

    if (ledger.next.length > 0) {
      lines.push(`**Next up**: ${ledger.next.slice(0, 3).join(', ')}`);
    }

    if (ledger.workingFiles.length > 0) {
      lines.push(`**Files**: ${ledger.workingFiles.join(', ')}`);
    }

    if (ledger.constraints.length > 0) {
      lines.push(`**Constraints**: ${ledger.constraints.join('; ')}`);
    }

    return lines.join('\n');
  }
}

// =============================================================================
// Factory Function
// =============================================================================

export function createLedgerManager(ledgerDir: string): LedgerManager {
  return new LedgerManager({ ledgerDir });
}
