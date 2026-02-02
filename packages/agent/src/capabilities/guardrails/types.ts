/**
 * @fileoverview Guardrail Type Definitions
 *
 * Core types for the unified guardrail system. Rules define safety constraints
 * that are evaluated before tool execution.
 */

import type {
  GuardrailSeverity,
  GuardrailScope,
  GuardrailTier,
} from '@infrastructure/settings/types.js';

// Re-export settings types for convenience
export type { GuardrailSeverity, GuardrailScope, GuardrailTier };

// =============================================================================
// Rule Types
// =============================================================================

/**
 * Base interface for all guardrail rules
 */
export interface GuardrailRuleBase {
  /** Unique identifier (e.g., 'core.destructive-commands', 'bash.sudo') */
  id: string;
  /** Human-readable name */
  name: string;
  /** Description of what this rule protects against */
  description: string;
  /** Severity when rule is triggered */
  severity: GuardrailSeverity;
  /** Where this rule applies */
  scope: GuardrailScope;
  /** Core rules cannot be disabled */
  tier: GuardrailTier;
  /** Tools this rule applies to (empty = all tools) */
  tools?: string[];
  /** Higher priority rules are evaluated first */
  priority?: number;
  /** Whether rule is enabled (ignored for core tier) */
  enabled: boolean;
  /** Tags for categorization */
  tags?: string[];
}

/**
 * Pattern rule - matches regex patterns against tool arguments
 */
export interface PatternRule extends GuardrailRuleBase {
  type: 'pattern';
  /** Which argument to check (e.g., 'command' for Bash) */
  targetArgument: string;
  /** Regex patterns to match */
  patterns: RegExp[];
}

/**
 * Path rule - protects filesystem paths
 */
export interface PathRule extends GuardrailRuleBase {
  type: 'path';
  /** Which arguments contain paths to check */
  pathArguments: string[];
  /** Protected path patterns (glob-style) */
  protectedPaths: string[];
  /** Block path traversal (.. sequences) */
  blockTraversal?: boolean;
  /** Block hidden paths (starting with .) */
  blockHidden?: boolean;
}

/**
 * Resource rule - enforces limits on tool arguments
 */
export interface ResourceRule extends GuardrailRuleBase {
  type: 'resource';
  /** Which argument to check */
  targetArgument: string;
  /** Maximum allowed value */
  maxValue?: number;
  /** Minimum allowed value */
  minValue?: number;
}

/**
 * Context rule - checks session state
 */
export interface ContextRule extends GuardrailRuleBase {
  type: 'context';
  /** Condition function that checks context state */
  condition: (context: EvaluationContext) => boolean;
  /** Message to show when blocked */
  blockMessage: string;
}

/**
 * Composite rule - combines multiple rules with AND/OR/NOT
 */
export interface CompositeRule extends GuardrailRuleBase {
  type: 'composite';
  /** How to combine child rules */
  operator: 'AND' | 'OR' | 'NOT';
  /** Child rule IDs to combine */
  childRules: string[];
}

/**
 * Union of all rule types
 */
export type GuardrailRule =
  | PatternRule
  | PathRule
  | ResourceRule
  | ContextRule
  | CompositeRule;

// =============================================================================
// Evaluation Types
// =============================================================================

/**
 * Session state for context-aware rules
 */
export interface SessionState {
  /** Current working directory */
  workingDirectory?: string;
  /** Additional session data */
  [key: string]: unknown;
}

/**
 * Context passed to rule evaluation
 */
export interface EvaluationContext {
  /** Tool being invoked */
  toolName: string;
  /** Arguments passed to the tool */
  toolArguments: Record<string, unknown>;
  /** Current session state */
  sessionState?: SessionState;
  /** Session ID for audit logging */
  sessionId?: string;
  /** Tool call ID */
  toolCallId?: string;
}

/**
 * Result of evaluating a single rule
 */
export interface RuleEvaluationResult {
  /** Rule that was evaluated */
  ruleId: string;
  /** Whether the rule was triggered */
  triggered: boolean;
  /** Severity of the triggered rule */
  severity?: GuardrailSeverity;
  /** Reason for triggering (for user display) */
  reason?: string;
  /** Detailed information for audit log */
  details?: Record<string, unknown>;
}

/**
 * Final result of evaluating all rules
 */
export interface GuardrailEvaluation {
  /** Whether the tool should be blocked */
  blocked: boolean;
  /** Reason for blocking (if blocked) */
  blockReason?: string;
  /** All rules that were triggered */
  triggeredRules: RuleEvaluationResult[];
  /** Whether there were any warnings */
  hasWarnings: boolean;
  /** Warning messages */
  warnings: string[];
  /** Evaluation timestamp */
  timestamp: string;
  /** Duration in milliseconds */
  durationMs: number;
}

// =============================================================================
// Audit Types
// =============================================================================

/**
 * Audit log entry
 */
export interface AuditEntry {
  /** Unique entry ID */
  id: string;
  /** Timestamp */
  timestamp: string;
  /** Session ID */
  sessionId?: string;
  /** Tool being invoked */
  toolName: string;
  /** Tool call ID */
  toolCallId?: string;
  /** Evaluation result */
  evaluation: GuardrailEvaluation;
  /** Tool arguments (may be redacted) */
  toolArguments?: Record<string, unknown>;
}

// =============================================================================
// Engine Configuration
// =============================================================================

/**
 * Options for creating the guardrail engine
 */
export interface GuardrailEngineOptions {
  /** Enable audit logging */
  enableAudit?: boolean;
  /** Maximum audit entries to keep in memory */
  maxAuditEntries?: number;
  /** User settings overrides */
  ruleOverrides?: Record<string, { enabled?: boolean; [key: string]: unknown }>;
  /** Custom rules to add */
  customRules?: GuardrailRule[];
}
