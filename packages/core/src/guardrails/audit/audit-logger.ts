/**
 * @fileoverview Guardrail Audit Logger
 *
 * Structured logging for guardrail decisions. Maintains an in-memory
 * log of all evaluations for debugging and analysis.
 */

import { createLogger } from '../../logging/logger.js';
import type { AuditEntry, GuardrailEvaluation } from '../types.js';
import { DEFAULT_GUARDRAIL_AUDIT } from '../../settings/defaults.js';

const logger = createLogger('guardrails:audit');

// =============================================================================
// Types
// =============================================================================

export interface AuditLoggerOptions {
  /** Maximum entries to keep in memory */
  maxEntries?: number;
  /** Enable logging to console/file logger */
  enableConsoleLog?: boolean;
}

// =============================================================================
// Audit Logger
// =============================================================================

/**
 * Audit logger for guardrail decisions
 *
 * Maintains a circular buffer of recent evaluations for debugging.
 */
export class GuardrailAuditLogger {
  private entries: AuditEntry[] = [];
  private maxEntries: number;
  private enableConsoleLog: boolean;
  private idCounter = 0;

  constructor(options: AuditLoggerOptions = {}) {
    this.maxEntries = options.maxEntries ?? DEFAULT_GUARDRAIL_AUDIT.maxEntries;
    this.enableConsoleLog = options.enableConsoleLog ?? true;
  }

  /**
   * Log a guardrail evaluation
   */
  log(params: {
    sessionId?: string;
    toolName: string;
    toolCallId?: string;
    toolArguments?: Record<string, unknown>;
    evaluation: GuardrailEvaluation;
  }): AuditEntry {
    const entry: AuditEntry = {
      id: `audit-${++this.idCounter}`,
      timestamp: new Date().toISOString(),
      sessionId: params.sessionId,
      toolName: params.toolName,
      toolCallId: params.toolCallId,
      evaluation: params.evaluation,
      toolArguments: this.redactSensitive(params.toolArguments),
    };

    // Add to circular buffer
    this.entries.push(entry);
    if (this.entries.length > this.maxEntries) {
      this.entries.shift();
    }

    // Log to console/file logger if enabled
    if (this.enableConsoleLog) {
      if (params.evaluation.blocked) {
        logger.warn('Guardrail blocked tool execution', {
          toolName: params.toolName,
          reason: params.evaluation.blockReason,
          triggeredRules: params.evaluation.triggeredRules.map(r => r.ruleId),
        });
      } else if (params.evaluation.hasWarnings) {
        logger.info('Guardrail warnings', {
          toolName: params.toolName,
          warnings: params.evaluation.warnings,
        });
      } else {
        logger.debug('Guardrail evaluation passed', {
          toolName: params.toolName,
          durationMs: params.evaluation.durationMs,
        });
      }
    }

    return entry;
  }

  /**
   * Get recent audit entries
   */
  getEntries(limit?: number): AuditEntry[] {
    const count = limit ?? this.entries.length;
    return this.entries.slice(-count);
  }

  /**
   * Get entries for a specific session
   */
  getEntriesForSession(sessionId: string, limit?: number): AuditEntry[] {
    const sessionEntries = this.entries.filter(e => e.sessionId === sessionId);
    const count = limit ?? sessionEntries.length;
    return sessionEntries.slice(-count);
  }

  /**
   * Get entries where a rule was triggered
   */
  getTriggeredEntries(ruleId?: string): AuditEntry[] {
    return this.entries.filter(e => {
      if (e.evaluation.triggeredRules.length === 0) return false;
      if (!ruleId) return true;
      return e.evaluation.triggeredRules.some(r => r.ruleId === ruleId);
    });
  }

  /**
   * Get blocked entries
   */
  getBlockedEntries(): AuditEntry[] {
    return this.entries.filter(e => e.evaluation.blocked);
  }

  /**
   * Clear all entries
   */
  clear(): void {
    this.entries = [];
  }

  /**
   * Get statistics about audit entries
   */
  getStats(): {
    total: number;
    blocked: number;
    warnings: number;
    passed: number;
    byTool: Record<string, number>;
    byRule: Record<string, number>;
  } {
    const stats = {
      total: this.entries.length,
      blocked: 0,
      warnings: 0,
      passed: 0,
      byTool: {} as Record<string, number>,
      byRule: {} as Record<string, number>,
    };

    for (const entry of this.entries) {
      // Count by outcome
      if (entry.evaluation.blocked) {
        stats.blocked++;
      } else if (entry.evaluation.hasWarnings) {
        stats.warnings++;
      } else {
        stats.passed++;
      }

      // Count by tool
      stats.byTool[entry.toolName] = (stats.byTool[entry.toolName] ?? 0) + 1;

      // Count by rule
      for (const rule of entry.evaluation.triggeredRules) {
        stats.byRule[rule.ruleId] = (stats.byRule[rule.ruleId] ?? 0) + 1;
      }
    }

    return stats;
  }

  /**
   * Redact sensitive information from tool arguments
   */
  private redactSensitive(
    args: Record<string, unknown> | undefined
  ): Record<string, unknown> | undefined {
    if (!args) return undefined;

    const redacted: Record<string, unknown> = {};
    const sensitiveKeys = ['password', 'token', 'secret', 'key', 'auth', 'credential'];

    for (const [key, value] of Object.entries(args)) {
      const lowerKey = key.toLowerCase();
      const isSensitive = sensitiveKeys.some(s => lowerKey.includes(s));

      if (isSensitive) {
        redacted[key] = '[REDACTED]';
      } else if (typeof value === 'string' && value.length > 1000) {
        // Truncate long strings
        redacted[key] = value.substring(0, 1000) + '... [truncated]';
      } else {
        redacted[key] = value;
      }
    }

    return redacted;
  }
}

/**
 * Create an audit logger instance
 */
export function createAuditLogger(options?: AuditLoggerOptions): GuardrailAuditLogger {
  return new GuardrailAuditLogger(options);
}
