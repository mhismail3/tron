/**
 * @fileoverview Tool Denial Configuration
 *
 * Defines the denial-based tool access control system for subagents.
 * Subagents inherit all parent tools by default, minus any specified denials.
 *
 * Design philosophy:
 * - Deny by default is safer than allow by default for restrictions
 * - Granular pattern matching enables fine-grained security policies
 * - Inheritance from parent ensures consistent tool availability
 */

/**
 * Pattern-based denial rule for a specific tool parameter.
 * If any pattern matches, the tool call is denied.
 */
export interface ParameterDenialPattern {
  /** Parameter name to check (e.g., 'command', 'file_path') */
  parameter: string;

  /**
   * Regex patterns - tool call denied if any pattern matches.
   * Patterns are case-insensitive by default.
   * @example ['rm\\s+-rf', 'sudo\\s+', '/etc/passwd']
   */
  patterns: string[];
}

/**
 * Granular denial rule for a specific tool.
 * Allows denying specific parameter patterns without blocking the entire tool.
 */
export interface ToolDenialRule {
  /** Tool name this rule applies to (e.g., 'Bash', 'Read', 'Write') */
  tool: string;

  /**
   * Parameter patterns that trigger denial.
   * Tool call is denied if ANY pattern in ANY parameter rule matches.
   */
  denyPatterns: ParameterDenialPattern[];

  /**
   * Optional custom message to return when this rule triggers a denial.
   * Useful for explaining why a specific action was blocked.
   */
  message?: string;
}

/**
 * Tool denial configuration for subagents.
 *
 * @example
 * // Deny all tools (text generation only)
 * { denyAll: true }
 *
 * @example
 * // Deny specific tools entirely
 * { tools: ['Bash', 'Write', 'SpawnSubagent'] }
 *
 * @example
 * // Granular denial with patterns
 * {
 *   tools: ['SpawnSubagent'],  // No nested subagents
 *   rules: [
 *     {
 *       tool: 'Bash',
 *       denyPatterns: [
 *         { parameter: 'command', patterns: ['rm\\s+-rf', 'sudo\\s+', 'chmod\\s+777'] }
 *       ],
 *       message: 'Dangerous shell commands are not allowed'
 *     },
 *     {
 *       tool: 'Read',
 *       denyPatterns: [
 *         { parameter: 'file_path', patterns: ['\\.env$', '\\.ssh/', '/etc/shadow'] }
 *       ],
 *       message: 'Sensitive files cannot be read'
 *     }
 *   ]
 * }
 */
export interface ToolDenialConfig {
  /**
   * Deny all tools - subagent can only do text generation.
   * When true, all other settings are ignored.
   * Use this for summarization, analysis, or other text-only tasks.
   */
  denyAll?: boolean;

  /**
   * Tools to deny entirely by name.
   * These tools will not be available to the subagent at all.
   */
  tools?: string[];

  /**
   * Granular denial rules with parameter pattern matching.
   * These rules are checked at tool execution time.
   * Applied in addition to `tools` denials.
   */
  rules?: ToolDenialRule[];
}

/**
 * Result of checking a tool call against denial rules.
 */
export interface ToolDenialCheckResult {
  /** Whether the tool call is denied */
  denied: boolean;
  /** Reason for denial (if denied) */
  reason?: string;
  /** Which rule triggered the denial (if denied) */
  matchedRule?: ToolDenialRule | { type: 'denyAll' | 'toolName'; tool?: string };
}

/**
 * Check if a tool call should be denied based on denial config.
 *
 * @param toolName - Name of the tool being called
 * @param args - Arguments being passed to the tool
 * @param config - Denial configuration to check against
 * @returns Result indicating if the call is denied and why
 */
export function checkToolDenial(
  toolName: string,
  args: Record<string, unknown>,
  config: ToolDenialConfig | undefined
): ToolDenialCheckResult {
  // No denial config = allowed
  if (!config) {
    return { denied: false };
  }

  // denyAll = deny everything
  if (config.denyAll) {
    return {
      denied: true,
      reason: 'All tools are denied for this subagent',
      matchedRule: { type: 'denyAll' },
    };
  }

  // Check if tool is in denied tools list
  if (config.tools?.includes(toolName)) {
    return {
      denied: true,
      reason: `Tool '${toolName}' is not available for this subagent`,
      matchedRule: { type: 'toolName', tool: toolName },
    };
  }

  // Check granular rules
  if (config.rules) {
    for (const rule of config.rules) {
      if (rule.tool !== toolName) continue;

      for (const patternConfig of rule.denyPatterns) {
        const paramValue = args[patternConfig.parameter];
        if (paramValue === undefined) continue;

        const valueStr = String(paramValue);

        for (const pattern of patternConfig.patterns) {
          try {
            const regex = new RegExp(pattern, 'i');
            if (regex.test(valueStr)) {
              return {
                denied: true,
                reason: rule.message ??
                  `Parameter '${patternConfig.parameter}' matches denied pattern`,
                matchedRule: rule,
              };
            }
          } catch {
            // Invalid regex - skip this pattern
            continue;
          }
        }
      }
    }
  }

  return { denied: false };
}

/**
 * Filter a list of tools based on denial config.
 * Returns tools that are NOT in the denied list.
 * Note: This only handles full tool denial, not pattern-based rules
 * (pattern rules are checked at execution time).
 *
 * @param tools - Array of tool instances with 'name' property
 * @param config - Denial configuration
 * @returns Filtered array of tools
 */
export function filterToolsByDenial<T extends { name: string }>(
  tools: T[],
  config: ToolDenialConfig | undefined
): T[] {
  // No config = all tools allowed
  if (!config) {
    return tools;
  }

  // denyAll = no tools
  if (config.denyAll) {
    return [];
  }

  // Filter out denied tools
  if (config.tools && config.tools.length > 0) {
    return tools.filter(tool => !config.tools!.includes(tool.name));
  }

  // No tool-level denials, return all
  // (pattern rules are checked at execution time)
  return tools;
}

/**
 * Merge parent denial config with additional child denials.
 * The result includes all denials from both configs.
 *
 * @param parentConfig - Parent's denial config (inherited)
 * @param childConfig - Additional denials for the child
 * @returns Merged denial config
 */
export function mergeToolDenials(
  parentConfig: ToolDenialConfig | undefined,
  childConfig: ToolDenialConfig | undefined
): ToolDenialConfig | undefined {
  // No configs = no denials
  if (!parentConfig && !childConfig) {
    return undefined;
  }

  // One config only
  if (!parentConfig) return childConfig;
  if (!childConfig) return parentConfig;

  // If either has denyAll, result is denyAll
  if (parentConfig.denyAll || childConfig.denyAll) {
    return { denyAll: true };
  }

  // Merge tools arrays (union)
  const mergedTools = new Set<string>([
    ...(parentConfig.tools ?? []),
    ...(childConfig.tools ?? []),
  ]);

  // Merge rules arrays (concatenate)
  const mergedRules = [
    ...(parentConfig.rules ?? []),
    ...(childConfig.rules ?? []),
  ];

  return {
    tools: mergedTools.size > 0 ? Array.from(mergedTools) : undefined,
    rules: mergedRules.length > 0 ? mergedRules : undefined,
  };
}
