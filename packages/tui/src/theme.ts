/**
 * @fileoverview TRON TUI Theme Configuration
 *
 * Unified color theme based on forest green #123524.
 * Uses chalk for terminal color support with hex colors.
 * Theme values are loaded from settings for customization.
 *
 * PERFORMANCE: All UI settings are loaded once and cached.
 * Call preloadSettings() at app startup for best performance.
 */
import chalk from 'chalk';
import { getSettings, type UiSettings } from '@tron/core';

// =============================================================================
// Unified Settings Cache (single load, all UI settings)
// =============================================================================

/**
 * Single cached UI settings object - loads all settings at once
 * This avoids multiple separate getSettings() calls
 */
let cachedUiSettings: UiSettings | null = null;

function getUiSettings(): UiSettings {
  if (!cachedUiSettings) {
    cachedUiSettings = getSettings().ui;
  }
  return cachedUiSettings;
}

// Direct property accessors (no separate caches needed)
function getPalette() { return getUiSettings().palette; }
function getIcons() { return getUiSettings().icons; }
function getThinkingAnimation() { return getUiSettings().thinkingAnimation; }
function getInputSettings() { return getUiSettings().input; }
function getMenuSettings() { return getUiSettings().menu; }

// =============================================================================
// Base Color Palette
// =============================================================================

/**
 * Core color values derived from the primary forest green #123524
 * Now loads from settings for user customization
 */
export const palette = {
  // Primary forest green family
  get primary() { return getPalette().primary; },
  get primaryLight() { return getPalette().primaryLight; },
  get primaryBright() { return getPalette().primaryBright; },
  get primaryVivid() { return getPalette().primaryVivid; },

  // Extended green palette for variety
  get emerald() { return getPalette().emerald; },
  get mint() { return getPalette().mint; },
  get sage() { return getPalette().sage; },

  // Neutral tones with green undertones
  get dark() { return getPalette().dark; },
  get muted() { return getPalette().muted; },
  get subtle() { return getPalette().subtle; },

  // Text colors
  get textBright() { return getPalette().textBright; },
  get textPrimary() { return getPalette().textPrimary; },
  get textSecondary() { return getPalette().textSecondary; },
  get textMuted() { return getPalette().textMuted; },
  get textDim() { return getPalette().textDim; },

  // Status bar (uniform, 10% darker than accent)
  get statusBarText() { return getPalette().statusBarText; },

  // Semantic colors (kept distinct for UX clarity)
  get success() { return getPalette().success; },
  get warning() { return getPalette().warning; },
  get error() { return getPalette().error; },
  get info() { return getPalette().info; },
} as const;

// =============================================================================
// UI Icons - Elegant Unicode Characters
// =============================================================================


/**
 * Consistent icon system for different UI states and elements
 * Now loads from settings for user customization
 */
export const icons = {
  // Prompt/Input
  get prompt() { return getIcons().prompt; },

  // Message roles
  get user() { return getIcons().user; },
  get assistant() { return getIcons().assistant; },
  get system() { return getIcons().system; },

  // Tool execution states
  get toolRunning() { return getIcons().toolRunning; },
  get toolSuccess() { return getIcons().toolSuccess; },
  get toolError() { return getIcons().toolError; },

  // Status indicators
  get ready() { return getIcons().ready; },
  get thinking() { return getIcons().thinking; },
  get streaming() { return getIcons().streaming; },

  // List markers
  get bullet() { return getIcons().bullet; },
  get arrow() { return getIcons().arrow; },
  get check() { return getIcons().check; },

  // Bracketed paste indicators
  get pasteOpen() { return getIcons().pasteOpen; },
  get pasteClose() { return getIcons().pasteClose; },
} as const;

// =============================================================================
// Thinking Indicator Bars
// =============================================================================


/**
 * Bar characters for pulsing thinking animation
 * Now loads from settings for user customization
 */
export const thinkingBars = {
  get chars() { return getThinkingAnimation().chars; },
  get width() { return getThinkingAnimation().width; },
  get intervalMs() { return getThinkingAnimation().intervalMs; },
} as const;

// =============================================================================
// Semantic Theme Colors
// =============================================================================

/**
 * Semantic color assignments for UI elements
 */
export const theme = {
  // Branding
  logo: palette.primaryVivid,
  logoAccent: palette.emerald,

  // Borders
  border: palette.subtle,
  borderFocus: palette.primaryBright,
  borderAccent: palette.emerald,

  // Status indicators
  statusReady: palette.emerald,
  statusThinking: palette.mint,
  statusProcessing: palette.primaryVivid,
  statusRunning: palette.info,
  statusError: palette.error,
  statusHook: palette.sage,
  statusInit: palette.textMuted,

  // Message roles
  roleUser: palette.primaryVivid,
  roleAssistant: palette.emerald,
  roleSystem: palette.textMuted,
  roleTool: palette.mint,

  // Input
  promptPrefix: palette.emerald,
  placeholder: palette.textDim,
  cursor: palette.primaryVivid,
  selection: palette.primaryLight,

  // UI elements
  label: palette.textMuted,
  value: palette.textSecondary,
  accent: palette.primaryVivid,
  highlight: palette.mint,
  dim: palette.textDim,

  // Menu/commands
  menuBorder: palette.emerald,
  menuHeader: palette.primaryVivid,
  menuSelected: palette.emerald,
  menuItem: palette.textSecondary,

  // Tool execution
  toolRunning: palette.mint,
  toolSuccess: palette.emerald,
  toolError: palette.error,
  toolName: palette.primaryVivid,
  toolMeta: palette.textMuted,

  // Spinner
  spinner: palette.emerald,

  // Streaming
  streamingCursor: palette.emerald,

  // Status bar (uniform color for all items)
  statusBar: palette.statusBarText,

  // Bracketed paste
  pasteIndicator: palette.emerald,
  pasteText: palette.textMuted,
} as const;

// =============================================================================
// Chalk Styled Functions
// =============================================================================

/**
 * Pre-configured chalk styles for consistent theming
 */
export const styled = {
  // Logo and branding
  logo: chalk.hex(theme.logo),
  logoAccent: chalk.hex(theme.logoAccent),
  logoBold: chalk.hex(theme.logo).bold,

  // Borders (for chalk-based borders)
  border: chalk.hex(theme.border),

  // Status
  ready: chalk.hex(theme.statusReady),
  thinking: chalk.hex(theme.statusThinking),
  processing: chalk.hex(theme.statusProcessing),
  running: chalk.hex(theme.statusRunning),
  error: chalk.hex(theme.statusError),

  // Roles
  user: chalk.hex(theme.roleUser),
  assistant: chalk.hex(theme.roleAssistant),
  system: chalk.hex(theme.roleSystem),
  tool: chalk.hex(theme.roleTool),

  // Text styles
  label: chalk.hex(theme.label),
  value: chalk.hex(theme.value),
  accent: chalk.hex(theme.accent),
  highlight: chalk.hex(theme.highlight),
  dim: chalk.hex(theme.dim),
  muted: chalk.hex(palette.textMuted),

  // Input styling
  placeholder: chalk.hex(theme.placeholder),
  cursor: chalk.inverse,
  selection: chalk.bgHex(theme.selection).hex(palette.textBright),

  // Menu
  menuHeader: chalk.hex(theme.menuHeader).bold,
  menuSelected: chalk.hex(theme.menuSelected),
  menuItem: chalk.hex(theme.menuItem),

  // Tool
  toolName: chalk.hex(theme.toolName),
  toolMeta: chalk.hex(theme.toolMeta),

  // Spinner
  spinner: chalk.hex(theme.spinner),

  // Status bar
  statusBar: chalk.hex(theme.statusBar),

  // Paste indicators
  pasteIndicator: chalk.hex(theme.pasteIndicator),
  pasteText: chalk.hex(theme.pasteText),
} as const;

// =============================================================================
// Ink Color Props
// =============================================================================

/**
 * Color values for Ink's Text component color prop.
 * Note: Ink supports hex colors directly in the color prop.
 */
export const inkColors = {
  // Branding
  logo: theme.logo,
  logoAccent: theme.logoAccent,

  // Borders
  border: theme.border,
  borderFocus: theme.borderFocus,
  borderAccent: theme.borderAccent,

  // Status
  statusReady: theme.statusReady,
  statusThinking: theme.statusThinking,
  statusProcessing: theme.statusProcessing,
  statusRunning: theme.statusRunning,
  statusError: theme.statusError,
  statusHook: theme.statusHook,
  statusInit: theme.statusInit,

  // Roles
  roleUser: theme.roleUser,
  roleAssistant: theme.roleAssistant,
  roleSystem: theme.roleSystem,
  roleTool: theme.roleTool,

  // Input
  promptPrefix: theme.promptPrefix,
  placeholder: theme.placeholder,

  // UI
  label: theme.label,
  value: theme.value,
  accent: theme.accent,
  highlight: theme.highlight,
  dim: theme.dim,
  mint: palette.mint,

  // Menu
  menuBorder: theme.menuBorder,
  menuHeader: theme.menuHeader,
  menuSelected: theme.menuSelected,
  menuItem: theme.menuItem,

  // Tool
  toolRunning: theme.toolRunning,
  toolSuccess: theme.toolSuccess,
  toolError: theme.toolError,
  toolName: theme.toolName,
  toolMeta: theme.toolMeta,

  // Spinner
  spinner: theme.spinner,

  // Streaming
  streamingCursor: theme.streamingCursor,

  // Status bar
  statusBar: theme.statusBar,

  // Paste indicators
  pasteIndicator: theme.pasteIndicator,
  pasteText: theme.pasteText,

  // Semantic (keep these standard for clarity)
  success: palette.success,
  warning: palette.warning,
  error: palette.error,
  info: palette.info,
} as const;

// =============================================================================
// Helper Functions
// =============================================================================

/**
 * Get status color based on status string
 */
export function getStatusColor(status: string): string {
  const statusLower = status.toLowerCase();
  if (statusLower.includes('ready')) return inkColors.statusReady;
  if (statusLower.includes('think')) return inkColors.statusThinking;
  if (statusLower.includes('process')) return inkColors.statusProcessing;
  if (statusLower.includes('running') || statusLower.includes('run')) return inkColors.statusRunning;
  if (statusLower.includes('error')) return inkColors.statusError;
  if (statusLower.includes('hook')) return inkColors.statusHook;
  if (statusLower.includes('init')) return inkColors.statusInit;
  return inkColors.accent;
}

/**
 * Get role color based on message role
 */
export function getRoleColor(role: string): string {
  switch (role) {
    case 'user': return inkColors.roleUser;
    case 'assistant': return inkColors.roleAssistant;
    case 'system': return inkColors.roleSystem;
    case 'tool': return inkColors.roleTool;
    default: return inkColors.value;
  }
}

/**
 * Format pasted content as a bracketed indicator
 * Returns the formatted string (already styled)
 */
export function formatPastedContent(content: string): string {
  const charCount = content.length;
  const lineCount = content.split('\n').length;

  // Format: [text: XXX chars, Y lines] or just [text: XXX chars]
  if (lineCount > 1) {
    return styled.pasteIndicator(`[text: ${charCount.toLocaleString()} chars, ${lineCount} lines]`);
  }
  return styled.pasteIndicator(`[text: ${charCount.toLocaleString()} chars]`);
}

/**
 * Format a file/image paste indicator
 */
export function formatFilePaste(filename: string, type: 'image' | 'file' = 'file'): string {
  return styled.pasteIndicator(`[${type}: ${filename}]`);
}


/**
 * Check if input looks like a paste (multiple chars at once)
 * Threshold loaded from settings for customization
 */
export function getPasteThreshold(): number {
  return getInputSettings().pasteThreshold;
}

/**
 * @deprecated Use getPasteThreshold() instead. This constant is kept for backwards compatibility.
 */
export const PASTE_THRESHOLD = 3;

/**
 * Get max history entries for prompt input
 */
export function getMaxHistory(): number {
  return getInputSettings().maxHistory;
}

/**
 * Get default terminal width fallback
 */
export function getDefaultTerminalWidth(): number {
  return getInputSettings().defaultTerminalWidth;
}

/**
 * Get narrow mode threshold
 */
export function getNarrowThreshold(): number {
  return getInputSettings().narrowThreshold;
}

/**
 * Get visible lines for narrow mode
 */
export function getNarrowVisibleLines(): number {
  return getInputSettings().narrowVisibleLines;
}

/**
 * Get visible lines for normal mode
 */
export function getNormalVisibleLines(): number {
  return getInputSettings().normalVisibleLines;
}


/**
 * Get maximum visible commands in slash menu
 */
export function getMaxVisibleCommands(): number {
  return getMenuSettings().maxVisibleCommands;
}
