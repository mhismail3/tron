/**
 * @fileoverview Default Guardrail Rules
 *
 * Built-in rules that provide baseline security for the agent.
 * Core rules cannot be disabled via configuration.
 */

import * as os from 'os';
import * as path from 'path';
import type {
  PatternRule,
  PathRule,
  ResourceRule,
  GuardrailRule,
} from '../types.js';

// =============================================================================
// Core Rules (Cannot be disabled)
// =============================================================================

/**
 * Core rule: Block destructive shell commands
 *
 * Protects against rm -rf /, fork bombs, dd to devices, etc.
 */
export const CORE_DESTRUCTIVE_COMMANDS: PatternRule = {
  id: 'core.destructive-commands',
  name: 'Destructive Commands',
  description: 'Blocks extremely dangerous shell commands that could destroy the system',
  type: 'pattern',
  severity: 'block',
  scope: 'global',
  tier: 'core',
  tools: ['Bash'],
  priority: 1000,
  enabled: true,
  tags: ['security', 'system-protection'],
  targetArgument: 'command',
  patterns: [
    // rm -rf / or rm -rf /* (with or without sudo)
    /^(sudo\s+)?rm\s+(-rf?|--force)\s+\/\s*$/i,
    /^(sudo\s+)?rm\s+-rf?\s+\/\s*$/i,
    /(sudo\s+)?rm\s+-rf?\s+\/\*/i,
    // Fork bomb
    /^:\(\)\s*\{\s*:\|\s*:\s*&\s*\}\s*;\s*:/,
    // dd to raw devices (with or without sudo)
    /(sudo\s+)?dd\s+if=.*of=\/dev\/[sh]d[a-z]/i,
    // Write to raw disk devices
    />\s*\/dev\/[sh]d[a-z]/i,
    // mkfs (filesystem formatting) - with or without sudo
    /^(sudo\s+)?mkfs\./i,
    // chmod 777 on root (with or without sudo)
    /^(sudo\s+)?chmod\s+777\s+\/\s*$/i,
    // Dangerous system modifications with sudo
    /^sudo\s+rm\s+-rf?\s+\/(usr|var|etc|boot|bin|sbin|lib)\b/i,
  ],
};

/**
 * Core rule: Prevent deletion of any files in ~/.tron
 *
 * The agent cannot delete any files from ~/.tron/ (via rm, trash, etc.)
 * but can write/edit most files except those protected by other rules.
 */
export const CORE_TRON_NO_DELETE: PatternRule = {
  id: 'core.tron-no-delete',
  name: 'Tron No Delete',
  description: 'Prevents deletion of any files in ~/.tron directory',
  type: 'pattern',
  severity: 'block',
  scope: 'global',
  tier: 'core',
  tools: ['Bash'],
  priority: 1000,
  enabled: true,
  tags: ['security', 'config-protection'],
  targetArgument: 'command',
  patterns: [
    // rm commands targeting ~/.tron or $HOME/.tron
    new RegExp(`rm\\s+.*${escapeRegExp(path.join(os.homedir(), '.tron'))}`, 'i'),
    /rm\s+.*~\/\.tron/i,
    /rm\s+.*\$HOME\/\.tron/i,
    // trash commands
    new RegExp(`trash\\s+.*${escapeRegExp(path.join(os.homedir(), '.tron'))}`, 'i'),
    /trash\s+.*~\/\.tron/i,
  ],
};

/**
 * Core rule: Protect ~/.tron/app directory (deployed server)
 *
 * The agent cannot write, edit, or delete any files in ~/.tron/app/.
 */
export const CORE_TRON_APP_PROTECTION: PathRule = {
  id: 'core.tron-app-protection',
  name: 'Tron App Protection',
  description: 'Protects the ~/.tron/app directory from agent modifications',
  type: 'path',
  severity: 'block',
  scope: 'global',
  tier: 'core',
  tools: ['Write', 'Edit', 'Bash'],
  priority: 1000,
  enabled: true,
  tags: ['security', 'config-protection'],
  pathArguments: ['file_path', 'path', 'command'],
  protectedPaths: [
    path.join(os.homedir(), '.tron', 'app'),
    path.join(os.homedir(), '.tron', 'app', '**'),
  ],
};

/**
 * Core rule: Protect ~/.tron/database directory (database files)
 *
 * The agent cannot write, edit, or delete any files in ~/.tron/database/.
 */
export const CORE_TRON_DB_PROTECTION: PathRule = {
  id: 'core.tron-db-protection',
  name: 'Tron DB Protection',
  description: 'Protects the ~/.tron/database directory from agent modifications',
  type: 'path',
  severity: 'block',
  scope: 'global',
  tier: 'core',
  tools: ['Write', 'Edit', 'Bash'],
  priority: 1000,
  enabled: true,
  tags: ['security', 'config-protection'],
  pathArguments: ['file_path', 'path', 'command'],
  protectedPaths: [
    path.join(os.homedir(), '.tron', 'database'),
    path.join(os.homedir(), '.tron', 'database', '**'),
  ],
};

/**
 * Core rule: Protect ~/.tron/auth.json (OAuth tokens)
 *
 * The agent cannot write, edit, or delete ~/.tron/auth.json.
 */
export const CORE_TRON_AUTH_PROTECTION: PathRule = {
  id: 'core.tron-auth-protection',
  name: 'Tron Auth Protection',
  description: 'Protects the ~/.tron/auth.json file from agent modifications',
  type: 'path',
  severity: 'block',
  scope: 'global',
  tier: 'core',
  tools: ['Write', 'Edit', 'Bash'],
  priority: 1000,
  enabled: true,
  tags: ['security', 'config-protection'],
  pathArguments: ['file_path', 'path', 'command'],
  protectedPaths: [
    path.join(os.homedir(), '.tron', 'auth.json'),
  ],
};

/**
 * Cloud storage base path (macOS CloudStorage directory)
 */
const CLOUD_STORAGE_DIR = path.join(os.homedir(), 'Library', 'CloudStorage');
const SYNOLOGY_DRIVE_DIR = path.join(CLOUD_STORAGE_DIR, 'SynologyDrive-SynologyDrive');

/**
 * Core rule: Protect Synology Drive cloud storage
 *
 * The agent cannot write, edit, or delete any files in Synology Drive.
 */
export const CORE_SYNOLOGY_DRIVE_PROTECTION: PathRule = {
  id: 'core.synology-drive-protection',
  name: 'Synology Drive Protection',
  description: 'Protects Synology Drive cloud storage from agent modifications',
  type: 'path',
  severity: 'block',
  scope: 'global',
  tier: 'core',
  tools: ['Write', 'Edit', 'Bash'],
  priority: 1000,
  enabled: true,
  tags: ['security', 'cloud-storage-protection'],
  pathArguments: ['file_path', 'path', 'command'],
  protectedPaths: [
    SYNOLOGY_DRIVE_DIR,
    `${SYNOLOGY_DRIVE_DIR}/**`,
  ],
};

/**
 * Helper to escape special regex characters in a string
 */
function escapeRegExp(str: string): string {
  return str.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

// =============================================================================
// Standard Rules (Can be disabled via config)
// =============================================================================

/**
 * Standard rule: Block path traversal in filesystem operations
 */
export const PATH_TRAVERSAL: PathRule = {
  id: 'path.traversal',
  name: 'Path Traversal',
  description: 'Blocks path traversal sequences (..) in file paths',
  type: 'path',
  severity: 'block',
  scope: 'tool',
  tier: 'standard',
  tools: ['Write', 'Edit', 'Read'],
  priority: 800,
  enabled: true,
  tags: ['security', 'filesystem'],
  pathArguments: ['file_path', 'path'],
  protectedPaths: [],
  blockTraversal: true,
};

/**
 * Standard rule: Block hidden directory creation
 */
export const PATH_HIDDEN_MKDIR: PathRule = {
  id: 'path.hidden-mkdir',
  name: 'Hidden Directory Creation',
  description: 'Blocks creation of hidden directories via mkdir',
  type: 'path',
  severity: 'block',
  scope: 'tool',
  tier: 'standard',
  tools: ['Bash'],
  priority: 700,
  enabled: true,
  tags: ['filesystem'],
  pathArguments: ['command'],
  protectedPaths: [],
  blockHidden: true,
};

/**
 * Standard rule: Enforce bash timeout limits
 */
export const BASH_TIMEOUT: ResourceRule = {
  id: 'bash.timeout',
  name: 'Bash Timeout Limit',
  description: 'Enforces maximum timeout for bash commands (10 minutes)',
  type: 'resource',
  severity: 'block',
  scope: 'tool',
  tier: 'standard',
  tools: ['Bash'],
  priority: 500,
  enabled: true,
  tags: ['resource-limits'],
  targetArgument: 'timeout',
  maxValue: 600000, // 10 minutes
};

// =============================================================================
// Rule Registry
// =============================================================================

/**
 * All default rules
 */
export const DEFAULT_RULES: GuardrailRule[] = [
  // Core rules (immutable)
  CORE_DESTRUCTIVE_COMMANDS,
  CORE_TRON_NO_DELETE,
  CORE_TRON_APP_PROTECTION,
  CORE_TRON_DB_PROTECTION,
  CORE_TRON_AUTH_PROTECTION,
  CORE_SYNOLOGY_DRIVE_PROTECTION,
  // Standard rules (can be disabled)
  PATH_TRAVERSAL,
  PATH_HIDDEN_MKDIR,
  BASH_TIMEOUT,
];

/**
 * Core rule IDs (cannot be disabled)
 */
export const CORE_RULE_IDS = [
  'core.destructive-commands',
  'core.tron-no-delete',
  'core.tron-app-protection',
  'core.tron-db-protection',
  'core.tron-auth-protection',
  'core.synology-drive-protection',
];

/**
 * Check if a rule ID is a core rule
 */
export function isCoreRule(ruleId: string): boolean {
  return CORE_RULE_IDS.includes(ruleId);
}
