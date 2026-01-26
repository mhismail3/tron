/**
 * @fileoverview Guardrail Engine
 *
 * Central rule evaluation engine for the guardrail system.
 * Evaluates tool calls against registered rules and returns
 * block/warn/audit decisions.
 */

import * as os from 'os';
import * as path from 'path';
import { createLogger, categorizeError, LogErrorCategory, LogErrorCodes } from '../logging/index.js';
import type {
  GuardrailRule,
  PatternRule,
  PathRule,
  ResourceRule,
  ContextRule,
  CompositeRule,
  EvaluationContext,
  RuleEvaluationResult,
  GuardrailEvaluation,
  GuardrailEngineOptions,
} from './types.js';
import { DEFAULT_RULES, isCoreRule } from './builtin/default-rules.js';
import { GuardrailAuditLogger, createAuditLogger } from './audit/audit-logger.js';

const logger = createLogger('guardrails:engine');

// =============================================================================
// Guardrail Engine
// =============================================================================

/**
 * Main guardrail evaluation engine
 *
 * Evaluates tool calls against registered rules and returns
 * block/warn/audit decisions.
 */
export class GuardrailEngine {
  private rules: Map<string, GuardrailRule> = new Map();
  private auditLogger: GuardrailAuditLogger | null = null;
  private ruleOverrides: Record<string, { enabled?: boolean; [key: string]: unknown }>;

  constructor(options: GuardrailEngineOptions = {}) {
    this.ruleOverrides = options.ruleOverrides ?? {};

    // Initialize audit logger if enabled
    if (options.enableAudit !== false) {
      this.auditLogger = createAuditLogger({
        maxEntries: options.maxAuditEntries,
      });
    }

    // Register default rules
    for (const rule of DEFAULT_RULES) {
      this.registerRule(rule);
    }

    // Register custom rules
    if (options.customRules) {
      for (const rule of options.customRules) {
        this.registerRule(rule);
      }
    }

    logger.debug('GuardrailEngine initialized', {
      ruleCount: this.rules.size,
      auditEnabled: this.auditLogger !== null,
    });
  }

  /**
   * Register a rule
   */
  registerRule(rule: GuardrailRule): void {
    // Prevent registering core rules with custom tier (security measure)
    if (rule.tier === 'core' && !isCoreRule(rule.id)) {
      logger.warn('Attempted to register non-core rule as core', { ruleId: rule.id });
      return;
    }

    this.rules.set(rule.id, rule);
    logger.debug('Rule registered', { ruleId: rule.id, tier: rule.tier });
  }

  /**
   * Unregister a rule (cannot unregister core rules)
   */
  unregisterRule(ruleId: string): boolean {
    if (isCoreRule(ruleId)) {
      logger.warn('Cannot unregister core rule', { ruleId });
      return false;
    }

    return this.rules.delete(ruleId);
  }

  /**
   * Get a rule by ID
   */
  getRule(ruleId: string): GuardrailRule | undefined {
    return this.rules.get(ruleId);
  }

  /**
   * Get all registered rules
   */
  getRules(): GuardrailRule[] {
    return Array.from(this.rules.values());
  }

  /**
   * Check if a rule is enabled
   */
  isRuleEnabled(ruleId: string): boolean {
    const rule = this.rules.get(ruleId);
    if (!rule) return false;

    // Core rules are always enabled
    if (rule.tier === 'core') return true;

    // Check user overrides
    const override = this.ruleOverrides[ruleId];
    if (override?.enabled !== undefined) {
      return override.enabled;
    }

    return rule.enabled;
  }

  /**
   * Evaluate a tool call against all applicable rules
   */
  async evaluate(context: EvaluationContext): Promise<GuardrailEvaluation> {
    const startTime = Date.now();
    const triggeredRules: RuleEvaluationResult[] = [];
    const warnings: string[] = [];
    let blocked = false;
    let blockReason: string | undefined;

    // Get applicable rules sorted by priority
    const applicableRules = this.getApplicableRules(context.toolName);

    // Evaluate each rule
    for (const rule of applicableRules) {
      if (!this.isRuleEnabled(rule.id)) continue;

      const result = await this.evaluateRule(rule, context);

      if (result.triggered) {
        triggeredRules.push(result);

        if (result.severity === 'block') {
          blocked = true;
          blockReason = result.reason ?? `Blocked by rule: ${rule.name}`;
          // Continue evaluating for audit purposes
        } else if (result.severity === 'warn') {
          warnings.push(result.reason ?? `Warning from rule: ${rule.name}`);
        }
        // 'audit' severity just logs, no action
      }
    }

    const evaluation: GuardrailEvaluation = {
      blocked,
      blockReason,
      triggeredRules,
      hasWarnings: warnings.length > 0,
      warnings,
      timestamp: new Date().toISOString(),
      durationMs: Date.now() - startTime,
    };

    // Log to audit
    if (this.auditLogger) {
      this.auditLogger.log({
        sessionId: context.sessionId,
        toolName: context.toolName,
        toolCallId: context.toolCallId,
        toolArguments: context.toolArguments,
        evaluation,
      });
    }

    return evaluation;
  }

  /**
   * Get the audit logger (for stats/debugging)
   */
  getAuditLogger(): GuardrailAuditLogger | null {
    return this.auditLogger;
  }

  // ===========================================================================
  // Private Methods
  // ===========================================================================

  /**
   * Get rules applicable to a specific tool, sorted by priority
   */
  private getApplicableRules(toolName: string): GuardrailRule[] {
    const applicable: GuardrailRule[] = [];

    for (const rule of this.rules.values()) {
      // Rule applies to all tools if no tools specified
      if (!rule.tools || rule.tools.length === 0 || rule.tools.includes(toolName)) {
        applicable.push(rule);
      }
    }

    // Sort by priority (higher first)
    return applicable.sort((a, b) => (b.priority ?? 0) - (a.priority ?? 0));
  }

  /**
   * Evaluate a single rule against the context
   */
  private async evaluateRule(
    rule: GuardrailRule,
    context: EvaluationContext
  ): Promise<RuleEvaluationResult> {
    try {
      switch (rule.type) {
        case 'pattern':
          return this.evaluatePatternRule(rule, context);
        case 'path':
          return this.evaluatePathRule(rule, context);
        case 'resource':
          return this.evaluateResourceRule(rule, context);
        case 'context':
          return this.evaluateContextRule(rule, context);
        case 'composite':
          return this.evaluateCompositeRule(rule, context);
        default: {
          // This should never happen due to exhaustive type checking
          const _exhaustive: never = rule;
          return { ruleId: (_exhaustive as GuardrailRule).id, triggered: false };
        }
      }
    } catch (error) {
      const structured = categorizeError(error, { ruleId: rule.id, ruleType: rule.type });
      logger.error('Rule evaluation error', {
        ruleId: rule.id,
        code: LogErrorCodes.GUARD_BLOCKED,
        category: LogErrorCategory.GUARDRAIL,
        error: structured.message,
        retryable: structured.retryable,
      });
      return { ruleId: rule.id, triggered: false };
    }
  }

  /**
   * Evaluate a pattern rule
   */
  private evaluatePatternRule(
    rule: PatternRule,
    context: EvaluationContext
  ): RuleEvaluationResult {
    const value = context.toolArguments[rule.targetArgument];
    if (typeof value !== 'string') {
      return { ruleId: rule.id, triggered: false };
    }

    for (const pattern of rule.patterns) {
      if (pattern.test(value)) {
        return {
          ruleId: rule.id,
          triggered: true,
          severity: rule.severity,
          reason: `${rule.name}: Potentially destructive command pattern detected`,
          details: { matchedPattern: pattern.source },
        };
      }
    }

    return { ruleId: rule.id, triggered: false };
  }

  /**
   * Evaluate a path rule
   */
  private evaluatePathRule(
    rule: PathRule,
    context: EvaluationContext
  ): RuleEvaluationResult {
    const homedir = os.homedir();

    for (const argName of rule.pathArguments) {
      const value = context.toolArguments[argName];
      if (typeof value !== 'string') continue;

      // For bash commands, extract paths from the command
      if (argName === 'command') {
        // Check if command writes to protected paths
        if (this.checkBashCommandForPaths(value, rule, homedir)) {
          return {
            ruleId: rule.id,
            triggered: true,
            severity: rule.severity,
            reason: `${rule.name}: Command would modify protected path`,
            details: { command: value.substring(0, 200) },
          };
        }
        continue;
      }

      // Check path traversal
      if (rule.blockTraversal && value.includes('..')) {
        return {
          ruleId: rule.id,
          triggered: true,
          severity: rule.severity,
          reason: `${rule.name}: Path traversal not allowed`,
          details: { path: value },
        };
      }

      // Check hidden paths
      if (rule.blockHidden) {
        const basename = path.basename(value);
        if (basename.startsWith('.')) {
          return {
            ruleId: rule.id,
            triggered: true,
            severity: rule.severity,
            reason: `${rule.name}: Hidden paths not allowed`,
            details: { path: value },
          };
        }
      }

      // Check protected paths
      const normalizedValue = path.normalize(value);
      const absoluteValue = path.isAbsolute(normalizedValue)
        ? normalizedValue
        : path.resolve(context.sessionState?.workingDirectory ?? process.cwd(), normalizedValue);

      for (const protectedPath of rule.protectedPaths) {
        const expandedProtected = protectedPath.replace('~', homedir);
        const normalizedProtected = path.normalize(expandedProtected);

        // Check if path is within protected path
        if (this.isPathWithin(absoluteValue, normalizedProtected)) {
          return {
            ruleId: rule.id,
            triggered: true,
            severity: rule.severity,
            reason: `${rule.name}: Cannot modify protected path`,
            details: { path: value, protectedPath: protectedPath },
          };
        }
      }
    }

    return { ruleId: rule.id, triggered: false };
  }

  /**
   * Check if a bash command would write to protected paths
   */
  private checkBashCommandForPaths(command: string, rule: PathRule, homedir: string): boolean {
    // Simple heuristic: look for common write operations to protected paths
    const writePatterns = [
      // echo/cat redirect
      />>\s*([^\s;|&]+)/g,
      />\s*([^\s;|&]+)/g,
      // tee
      /tee\s+(?:-a\s+)?([^\s;|&]+)/g,
      // cp/mv destination
      /(?:cp|mv)\s+[^\s]+\s+([^\s;|&]+)/g,
      // rm
      /rm\s+(?:-rf?\s+)?([^\s;|&]+)/g,
    ];

    for (const protectedPath of rule.protectedPaths) {
      const expandedProtected = protectedPath.replace('~', homedir).replace(/\*\*$/, '');
      const normalizedProtected = path.normalize(expandedProtected);

      for (const pattern of writePatterns) {
        pattern.lastIndex = 0;
        let match;
        while ((match = pattern.exec(command)) !== null) {
          const targetPath = match[1];
          if (!targetPath) continue;

          // Expand ~ in the target path
          const expandedTarget = targetPath.replace(/^~/, homedir);
          const normalizedTarget = path.isAbsolute(expandedTarget)
            ? path.normalize(expandedTarget)
            : expandedTarget;

          // Check if target is within protected path
          if (normalizedTarget.startsWith(normalizedProtected)) {
            return true;
          }

          // Also check literal ~/.tron
          if (
            targetPath.includes('.tron') ||
            expandedTarget.includes('.tron')
          ) {
            return true;
          }
        }
      }
    }

    return false;
  }

  /**
   * Check if a path is within a protected path
   */
  private isPathWithin(testPath: string, protectedPath: string): boolean {
    // Handle glob patterns (e.g., ~/.tron/**)
    let effectiveProtected = protectedPath;
    if (protectedPath.endsWith('**')) {
      effectiveProtected = protectedPath.slice(0, -2);
    }

    const normalized = path.normalize(testPath);
    const normalizedProtected = path.normalize(effectiveProtected);

    // Check if path starts with protected path
    return (
      normalized === normalizedProtected ||
      normalized.startsWith(normalizedProtected + path.sep)
    );
  }

  /**
   * Evaluate a resource rule
   */
  private evaluateResourceRule(
    rule: ResourceRule,
    context: EvaluationContext
  ): RuleEvaluationResult {
    const value = context.toolArguments[rule.targetArgument];
    if (typeof value !== 'number') {
      return { ruleId: rule.id, triggered: false };
    }

    if (rule.maxValue !== undefined && value > rule.maxValue) {
      return {
        ruleId: rule.id,
        triggered: true,
        severity: rule.severity,
        reason: `${rule.name}: Value ${value} exceeds maximum ${rule.maxValue}`,
        details: { value, maxValue: rule.maxValue },
      };
    }

    if (rule.minValue !== undefined && value < rule.minValue) {
      return {
        ruleId: rule.id,
        triggered: true,
        severity: rule.severity,
        reason: `${rule.name}: Value ${value} below minimum ${rule.minValue}`,
        details: { value, minValue: rule.minValue },
      };
    }

    return { ruleId: rule.id, triggered: false };
  }

  /**
   * Evaluate a context rule
   */
  private evaluateContextRule(
    rule: ContextRule,
    context: EvaluationContext
  ): RuleEvaluationResult {
    const triggered = rule.condition(context);

    if (triggered) {
      return {
        ruleId: rule.id,
        triggered: true,
        severity: rule.severity,
        reason: rule.blockMessage,
      };
    }

    return { ruleId: rule.id, triggered: false };
  }

  /**
   * Evaluate a composite rule
   */
  private async evaluateCompositeRule(
    rule: CompositeRule,
    context: EvaluationContext
  ): Promise<RuleEvaluationResult> {
    const childResults: RuleEvaluationResult[] = [];

    for (const childId of rule.childRules) {
      const childRule = this.rules.get(childId);
      if (!childRule) continue;

      const result = await this.evaluateRule(childRule, context);
      childResults.push(result);
    }

    let triggered: boolean;
    switch (rule.operator) {
      case 'AND':
        triggered = childResults.every(r => r.triggered);
        break;
      case 'OR':
        triggered = childResults.some(r => r.triggered);
        break;
      case 'NOT': {
        const firstResult = childResults[0];
        triggered = firstResult !== undefined && !firstResult.triggered;
        break;
      }
      default:
        triggered = false;
    }

    if (triggered) {
      return {
        ruleId: rule.id,
        triggered: true,
        severity: rule.severity,
        reason: `Composite rule ${rule.name} triggered`,
        details: { childResults },
      };
    }

    return { ruleId: rule.id, triggered: false };
  }
}

/**
 * Create a guardrail engine instance
 */
export function createGuardrailEngine(options?: GuardrailEngineOptions): GuardrailEngine {
  return new GuardrailEngine(options);
}
