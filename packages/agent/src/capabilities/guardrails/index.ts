/**
 * @fileoverview Guardrails Module
 *
 * Unified guardrail system for Tron. Provides:
 * - Rule-based safety checks before tool execution
 * - Tiered immutability (core rules cannot be disabled)
 * - Audit logging of all guardrail decisions
 * - Configurable rules via ~/.tron/settings.json
 *
 * ## Usage
 *
 * ```typescript
 * import { createGuardrailEngine } from '../index.js';
 *
 * const engine = createGuardrailEngine({
 *   enableAudit: true,
 *   ruleOverrides: {
 *     'bash.sudo': { enabled: false }, // Disable sudo blocking
 *   },
 * });
 *
 * // Evaluate a tool call
 * const evaluation = await engine.evaluate({
 *   toolName: 'Bash',
 *   toolArguments: { command: 'rm -rf /' },
 *   sessionState: { isPlanMode: false },
 * });
 *
 * if (evaluation.blocked) {
 *   console.log('Blocked:', evaluation.blockReason);
 * }
 * ```
 *
 * ## Rule Tiers
 *
 * - **Core**: Cannot be disabled (e.g., rm -rf /, ~/.tron protection)
 * - **Standard**: Can be disabled via settings.json
 * - **Custom**: User-defined rules
 *
 * ## Protected Paths
 *
 * The entire ~/.tron/ directory is core-protected:
 * - db/ (database files)
 * - rules/ (markdown rules)
 * - mods/ (extensions)
 * - settings.json (config)
 * - auth.json (OAuth tokens)
 */

// Types
export type {
  GuardrailSeverity,
  GuardrailScope,
  GuardrailTier,
  GuardrailRuleBase,
  PatternRule,
  PathRule,
  ResourceRule,
  ContextRule,
  CompositeRule,
  GuardrailRule,
  SessionState,
  EvaluationContext,
  RuleEvaluationResult,
  GuardrailEvaluation,
  AuditEntry,
  GuardrailEngineOptions,
} from './types.js';

// Engine
export { GuardrailEngine, createGuardrailEngine } from './engine.js';

// Audit logger
export {
  GuardrailAuditLogger,
  createAuditLogger,
  type AuditLoggerOptions,
} from './audit/audit-logger.js';

// Default rules
export {
  DEFAULT_RULES,
  CORE_RULE_IDS,
  isCoreRule,
  CORE_DESTRUCTIVE_COMMANDS,
  CORE_TRON_NO_DELETE,
  CORE_TRON_APP_PROTECTION,
  CORE_TRON_DB_PROTECTION,
  CORE_TRON_AUTH_PROTECTION,
  PATH_TRAVERSAL,
  PATH_HIDDEN_MKDIR,
  BASH_TIMEOUT,
  SESSION_PLAN_MODE,
} from './builtin/default-rules.js';
