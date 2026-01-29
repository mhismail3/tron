/**
 * @fileoverview Settings Type Definitions
 *
 * Comprehensive type definitions for all Tron configurable settings.
 * These types define the structure of ~/.tron/settings.json.
 */

// =============================================================================
// API Settings
// =============================================================================

/**
 * Anthropic API configuration
 */
export interface AnthropicApiSettings {
  /** OAuth authorization URL */
  authUrl: string;
  /** OAuth token exchange URL */
  tokenUrl: string;
  /** OAuth redirect URI (use Anthropic's callback page to avoid Cloudflare issues) */
  redirectUri: string;
  /** OAuth client ID */
  clientId: string;
  /** OAuth scopes */
  scopes: string[];
  /** System prompt prefix required for OAuth */
  systemPromptPrefix: string;
  /** Beta headers for OAuth requests */
  oauthBetaHeaders: string;
  /** Token expiry buffer in seconds (refresh before actual expiry) */
  tokenExpiryBufferSeconds: number;
}

/**
 * OpenAI Codex OAuth configuration (for ChatGPT subscription access)
 */
export interface OpenAICodexApiSettings {
  /** OAuth authorization URL */
  authUrl: string;
  /** OAuth token exchange URL */
  tokenUrl: string;
  /** OAuth client ID */
  clientId: string;
  /** OAuth scopes */
  scopes: string[];
  /** Base URL for Codex API (chatgpt.com backend) */
  baseUrl: string;
  /** Token expiry buffer in seconds (refresh before actual expiry) */
  tokenExpiryBufferSeconds: number;
  /** Default reasoning effort level */
  defaultReasoningEffort: 'low' | 'medium' | 'high' | 'xhigh';
}

/**
 * Google/Gemini OAuth configuration
 *
 * Supports two OAuth backends:
 * 1. Cloud Code Assist (production): cloudcode-pa.googleapis.com
 * 2. Antigravity (sandbox/free tier): daily-cloudcode-pa.sandbox.googleapis.com
 *
 * OAuth is ALWAYS preferred over API key when both are available.
 */
export interface GoogleApiSettings {
  /** OAuth authorization URL */
  authUrl: string;
  /** OAuth token exchange URL */
  tokenUrl: string;
  /** OAuth scopes */
  scopes: string[];
  /** OAuth redirect URI (local callback server) */
  redirectUri: string;
  /** Token expiry buffer in seconds (refresh before actual expiry) */
  tokenExpiryBufferSeconds: number;
  /** API endpoint for Gemini requests */
  apiEndpoint: string;
  /** API version path */
  apiVersion: string;
  /** Default OAuth endpoint type */
  defaultEndpoint: 'cloud-code-assist' | 'antigravity';
  // Note: clientId and clientSecret are loaded from ~/.tron/auth.json, not from settings
}

/**
 * API settings container
 */
export interface ApiSettings {
  anthropic: AnthropicApiSettings;
  openaiCodex?: OpenAICodexApiSettings;
  google?: GoogleApiSettings;
}

// =============================================================================
// Model Settings
// =============================================================================

/**
 * Model configuration
 */
export interface ModelSettings {
  /** Default model ID */
  default: string;
  /** Default max output tokens */
  defaultMaxTokens: number;
  /** Default thinking budget tokens */
  defaultThinkingBudget: number;
}

// =============================================================================
// Retry Settings
// =============================================================================

/**
 * Retry configuration for API calls
 */
export interface RetrySettings {
  /** Maximum number of retry attempts */
  maxRetries: number;
  /** Base delay between retries in milliseconds */
  baseDelayMs: number;
  /** Maximum delay between retries in milliseconds */
  maxDelayMs: number;
  /** Jitter factor to prevent thundering herd (0-1) */
  jitterFactor: number;
}

// =============================================================================
// Tool Settings
// =============================================================================

/**
 * Bash tool configuration
 */
export interface BashToolSettings {
  /** Default command timeout in milliseconds */
  defaultTimeoutMs: number;
  /** Maximum allowed timeout in milliseconds */
  maxTimeoutMs: number;
  /** Maximum output length in characters */
  maxOutputLength: number;
  /** Dangerous command patterns (regex strings) */
  dangerousPatterns: string[];
}

/**
 * Read tool configuration
 */
export interface ReadToolSettings {
  /** Default number of lines to read */
  defaultLimitLines: number;
  /** Maximum line length before truncation */
  maxLineLength: number;
  /** Maximum output size in tokens (default: 20,000) */
  maxOutputTokens: number;
}

/**
 * Find tool configuration
 */
export interface FindToolSettings {
  /** Default maximum results */
  defaultMaxResults: number;
  /** Default maximum directory depth */
  defaultMaxDepth: number;
}

/**
 * Grep tool configuration
 */
export interface GrepToolSettings {
  /** Default maximum results */
  defaultMaxResults: number;
  /** Maximum file size to search in bytes */
  maxFileSizeBytes: number;
  /** Binary file extensions to skip */
  binaryExtensions: string[];
  /** Directories to skip during search */
  skipDirectories: string[];
  /** Maximum output size in tokens (default: 15,000) */
  maxOutputTokens: number;
}

/**
 * AstGrep tool configuration
 */
export interface AstGrepToolSettings {
  /** Default result limit (default: 50) */
  defaultLimit: number;
  /** Maximum result limit (default: 200) */
  maxLimit: number;
  /** Default context lines (default: 0) */
  defaultContext: number;
  /** Maximum output size in tokens (default: 15,000) */
  maxOutputTokens: number;
  /** Binary name to use (default: 'sg', falls back to 'ast-grep') */
  binaryPath: string;
  /** Directories to skip during search */
  skipDirectories: string[];
  /** Require user confirmation before applying replacements */
  requireConfirmationForReplace: boolean;
  /** Default timeout in milliseconds (default: 60,000) */
  defaultTimeoutMs: number;
}

/**
 * All tool settings
 */
export interface ToolSettings {
  bash: BashToolSettings;
  read: ReadToolSettings;
  find: FindToolSettings;
  grep: GrepToolSettings;
  astGrep: AstGrepToolSettings;
}

// =============================================================================
// Context Settings
// =============================================================================

/**
 * Context compactor configuration
 */
export interface CompactorSettings {
  /** Maximum tokens before compaction is triggered */
  maxTokens: number;
  /** Threshold ratio to trigger compaction (0-1) */
  compactionThreshold: number;
  /** Target token count after compaction */
  targetTokens: number;
  /** Number of recent message pairs to preserve */
  preserveRecentCount: number;
  /** Characters per token estimate */
  charsPerToken: number;
}

/**
 * Memory store configuration
 */
export interface MemorySettings {
  /** Maximum entries in memory cache */
  maxEntries: number;
}

/**
 * Context settings container
 */
export interface ContextSettings {
  compactor: CompactorSettings;
  memory: MemorySettings;
}

// =============================================================================
// Hook Settings
// =============================================================================

/**
 * Hook system configuration
 */
export interface HookSettings {
  /** Default hook execution timeout in milliseconds */
  defaultTimeoutMs: number;
  /** Hook discovery timeout in milliseconds */
  discoveryTimeoutMs: number;
  /** Project-level hooks directory (relative to project root) */
  projectDir: string;
  /** User-level hooks directory (relative to home) */
  userDir: string;
  /** Supported hook file extensions */
  extensions: string[];
}

// =============================================================================
// Server Settings
// =============================================================================

/**
 * Server configuration
 */
export interface ServerSettings {
  /** WebSocket server port */
  wsPort: number;
  /** Health check server port */
  healthPort: number;
  /** Server host binding */
  host: string;
  /** WebSocket heartbeat interval in milliseconds */
  heartbeatIntervalMs: number;
  /** Session inactivity timeout in milliseconds */
  sessionTimeoutMs: number;
  /** Maximum concurrent sessions */
  maxConcurrentSessions: number;
  /** Sessions storage directory (relative to ~/.tron) */
  sessionsDir: string;
  /** Memory database path (relative to ~/.tron) */
  memoryDbPath: string;
  /** Default model for server sessions */
  defaultModel: string;
  /** Default provider */
  defaultProvider: string;
  /** Audio transcription settings */
  transcription: TranscriptionSettings;
}

/**
 * Audio transcription configuration
 */
export interface TranscriptionSettings {
  /** Enable transcription support */
  enabled: boolean;
  /** Auto-start local transcription sidecar */
  manageSidecar: boolean;
  /** Base URL for transcription sidecar */
  baseUrl: string;
  /** Request timeout in milliseconds */
  timeoutMs: number;
  /** Cleanup mode to apply to transcriptions */
  cleanupMode: 'none' | 'basic' | 'llm';
  /** Maximum audio payload size in bytes */
  maxBytes: number;
}

// =============================================================================
// Tmux Settings
// =============================================================================

/**
 * Tmux integration configuration
 */
export interface TmuxSettings {
  /** Command execution timeout in milliseconds */
  commandTimeoutMs: number;
  /** Polling interval in milliseconds */
  pollingIntervalMs: number;
}

// =============================================================================
// Session Settings
// =============================================================================

/**
 * Session configuration
 */
export interface SessionSettings {
  /** Git worktree command timeout in milliseconds */
  worktreeTimeoutMs: number;
}

// =============================================================================
// UI Theme Settings
// =============================================================================

/**
 * Color palette for the UI
 */
export interface PaletteSettings {
  /** Primary forest green */
  primary: string;
  /** Lighter forest green */
  primaryLight: string;
  /** Bright forest green for emphasis */
  primaryBright: string;
  /** Vivid green for highlights */
  primaryVivid: string;
  /** Emerald for accents */
  emerald: string;
  /** Mint for soft highlights */
  mint: string;
  /** Sage for very light accents */
  sage: string;
  /** Very dark green-black */
  dark: string;
  /** Muted forest */
  muted: string;
  /** Subtle green for borders */
  subtle: string;
  /** Almost white with green tint */
  textBright: string;
  /** Light green-white for main text */
  textPrimary: string;
  /** Softer green for secondary text */
  textSecondary: string;
  /** Muted green-gray for less important text */
  textMuted: string;
  /** Dim green-gray */
  textDim: string;
  /** Status bar text color */
  statusBarText: string;
  /** Success color */
  success: string;
  /** Warning color */
  warning: string;
  /** Error color */
  error: string;
  /** Info color */
  info: string;
}

/**
 * UI icon characters
 */
export interface IconSettings {
  /** User input prompt */
  prompt: string;
  /** User message prefix */
  user: string;
  /** Assistant response */
  assistant: string;
  /** System message */
  system: string;
  /** Tool in progress */
  toolRunning: string;
  /** Tool completed */
  toolSuccess: string;
  /** Tool error */
  toolError: string;
  /** Ready state */
  ready: string;
  /** Thinking/processing */
  thinking: string;
  /** Streaming response */
  streaming: string;
  /** Standard bullet */
  bullet: string;
  /** Arrow for navigation */
  arrow: string;
  /** Success/completed */
  check: string;
  /** Opening bracket for paste */
  pasteOpen: string;
  /** Closing bracket for paste */
  pasteClose: string;
}

/**
 * Thinking animation configuration
 */
export interface ThinkingAnimationSettings {
  /** Animation bar characters */
  chars: string[];
  /** Number of bars to display */
  width: number;
  /** Animation frame interval in milliseconds */
  intervalMs: number;
}

/**
 * Input configuration
 */
export interface InputSettings {
  /** Characters threshold to detect paste */
  pasteThreshold: number;
  /** Maximum prompt history entries */
  maxHistory: number;
  /** Default terminal width fallback */
  defaultTerminalWidth: number;
  /** Terminal width threshold for narrow mode */
  narrowThreshold: number;
  /** Maximum visible lines in narrow mode */
  narrowVisibleLines: number;
  /** Maximum visible lines in normal mode */
  normalVisibleLines: number;
}

/**
 * Menu configuration
 */
export interface MenuSettings {
  /** Maximum visible commands in slash menu */
  maxVisibleCommands: number;
}

/**
 * UI settings container
 */
export interface UiSettings {
  /** Theme name (reserved for future use) */
  theme: string;
  /** Color palette */
  palette: PaletteSettings;
  /** Icon characters */
  icons: IconSettings;
  /** Thinking animation */
  thinkingAnimation: ThinkingAnimationSettings;
  /** Input configuration */
  input: InputSettings;
  /** Menu configuration */
  menu: MenuSettings;
}

// =============================================================================
// Guardrail Settings
// =============================================================================

/**
 * Guardrail severity levels
 */
export type GuardrailSeverity = 'block' | 'warn' | 'audit';

/**
 * Guardrail scope - where the rule applies
 */
export type GuardrailScope = 'global' | 'tool' | 'session' | 'directory';

/**
 * Guardrail tier - determines if rule can be disabled
 */
export type GuardrailTier = 'core' | 'standard' | 'custom';

/**
 * Custom guardrail rule defined by user
 */
export interface CustomGuardrailRule {
  /** Unique identifier for the rule */
  id: string;
  /** Rule type */
  type: 'pattern' | 'path' | 'resource' | 'context';
  /** Cannot be 'core' - users can only create standard/custom rules */
  tier: 'standard' | 'custom';
  /** Severity when rule is triggered */
  severity: GuardrailSeverity;
  /** Tools this rule applies to (empty = all tools) */
  tools?: string[];
  /** Priority - higher = evaluated first */
  priority?: number;
  /** Tags for categorization */
  tags?: string[];
  /** For pattern rules: argument to match against */
  targetArgument?: string;
  /** For pattern rules: regex patterns to match */
  patterns?: string[];
  /** For path rules: paths to protect (glob patterns) */
  protectedPaths?: string[];
  /** For resource rules: max value (e.g., timeout) */
  maxValue?: number;
}

/**
 * Audit logging configuration
 */
export interface GuardrailAuditSettings {
  /** Enable audit logging */
  enabled?: boolean;
  /** Maximum audit log entries to keep */
  maxEntries?: number;
}

/**
 * Guardrail settings
 */
export interface GuardrailSettings {
  /** Override standard rules by ID */
  rules?: {
    [ruleId: string]: {
      enabled?: boolean;
      [key: string]: unknown;
    };
  };
  /** Additional custom rules */
  customRules?: CustomGuardrailRule[];
  /** Audit logging options */
  audit?: GuardrailAuditSettings;
}

// =============================================================================
// Root Settings
// =============================================================================

/**
 * Complete Tron settings structure
 */
export interface TronSettings {
  /** Settings schema version */
  version: string;
  /** Application name */
  name: string;
  /** API configuration */
  api: ApiSettings;
  /** Model configuration */
  models: ModelSettings;
  /** Retry configuration */
  retry: RetrySettings;
  /** Tool configuration */
  tools: ToolSettings;
  /** Context configuration */
  context: ContextSettings;
  /** Hook configuration */
  hooks: HookSettings;
  /** Server configuration */
  server: ServerSettings;
  /** Tmux configuration */
  tmux: TmuxSettings;
  /** Session configuration */
  session: SessionSettings;
  /** UI configuration */
  ui: UiSettings;
  /** Guardrail configuration (optional - uses defaults if not specified) */
  guardrails?: GuardrailSettings;
}

/**
 * Deep partial type for settings overrides
 */
export type DeepPartial<T> = {
  [P in keyof T]?: T[P] extends object ? DeepPartial<T[P]> : T[P];
};

/**
 * User settings override (partial version of TronSettings)
 */
export type UserSettings = DeepPartial<TronSettings>;
