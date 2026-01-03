/**
 * @fileoverview TRON TUI Theme Configuration
 *
 * Unified color theme based on forest green #123524.
 * Uses chalk for terminal color support with hex colors.
 */
import chalk from 'chalk';

// =============================================================================
// Base Color Palette
// =============================================================================

/**
 * Core color values derived from the primary forest green #123524
 */
export const palette = {
  // Primary forest green family
  primary: '#123524',        // Base forest green
  primaryLight: '#1a4a32',   // Lighter forest green
  primaryBright: '#2d7a4e',  // Bright forest green for emphasis
  primaryVivid: '#34d399',   // Vivid green for highlights (emerald-400)

  // Extended green palette for variety
  emerald: '#10b981',        // Emerald for accents
  mint: '#6ee7b7',           // Mint for soft highlights
  sage: '#86efac',           // Sage for very light accents

  // Neutral tones with green undertones
  dark: '#0a1f15',           // Very dark green-black
  muted: '#1f3d2c',          // Muted forest
  subtle: '#2d5a40',         // Subtle green for borders

  // Text colors
  textBright: '#ecfdf5',     // Almost white with green tint
  textPrimary: '#d1fae5',    // Light green-white for main text
  textSecondary: '#a7f3d0',  // Softer green for secondary text
  textMuted: '#6b8f7a',      // Muted green-gray for less important text
  textDim: '#4a6b58',        // Dim green-gray

  // Status bar (uniform, 10% darker than accent)
  statusBarText: '#2eb888',  // ~10% darker emerald for status bar items

  // Semantic colors (kept distinct for UX clarity)
  success: '#22c55e',        // Green (fits theme)
  warning: '#f59e0b',        // Amber (kept for visibility)
  error: '#ef4444',          // Red (kept for safety)
  info: '#38bdf8',           // Sky blue (kept for distinction)
} as const;

// =============================================================================
// UI Icons - Elegant Unicode Characters
// =============================================================================

/**
 * Consistent icon system for different UI states and elements
 */
export const icons = {
  // Prompt/Input
  prompt: '›',               // User input prompt

  // Message roles
  user: '›',                 // User message prefix
  assistant: '◆',            // Assistant response (filled diamond)
  system: '◇',               // System message (outline diamond)

  // Tool execution states
  toolRunning: '⬡',          // Tool in progress (hexagon outline)
  toolSuccess: '⬢',          // Tool completed (filled hexagon)
  toolError: '◈',            // Tool error (diamond with center)

  // Status indicators
  ready: '◆',                // Ready state
  thinking: '◇',             // Thinking/processing
  streaming: '◆',            // Streaming response

  // List markers
  bullet: '•',               // Standard bullet
  arrow: '→',                // Arrow for navigation
  check: '✓',                // Success/completed

  // Bracketed paste indicators
  pasteOpen: '⌈',            // Opening bracket for paste
  pasteClose: '⌋',           // Closing bracket for paste
} as const;

// =============================================================================
// Thinking Indicator Bars
// =============================================================================

/**
 * Bar characters for pulsing thinking animation
 * Arranged from shortest to tallest for wave effect
 */
export const thinkingBars = {
  chars: ['▁', '▂', '▃', '▄', '▅'] as const,
  width: 4,                  // Number of bars to show
  intervalMs: 120,           // Animation speed
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
 * Threshold: more than 3 characters arriving at once
 */
export const PASTE_THRESHOLD = 3;
