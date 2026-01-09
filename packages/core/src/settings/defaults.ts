/**
 * @fileoverview Default Settings
 *
 * Default values for all Tron configurable settings.
 * These serve as the fallback when user settings are not specified.
 */

import type { TronSettings } from './types.js';

/**
 * Default dangerous command patterns for bash tool
 * These regex patterns match potentially destructive commands
 */
export const DEFAULT_DANGEROUS_PATTERNS = [
  '^rm\\s+(-rf?|--force)\\s+/\\s*$',
  '^rm\\s+-rf?\\s+/\\s*$',
  'rm\\s+-rf?\\s+/',
  '^sudo\\s+',
  '^chmod\\s+777\\s+/\\s*$',
  '^mkfs\\.',
  '^dd\\s+if=.*of=/dev/',
  '>\\s*/dev/sd[a-z]',
  '^:\\(\\)\\s*\\{\\s*:\\|\\s*:\\s*&\\s*\\}\\s*;\\s*:',  // Fork bomb
];

/**
 * Default binary file extensions to skip in grep
 */
export const DEFAULT_BINARY_EXTENSIONS = [
  '.png', '.jpg', '.jpeg', '.gif', '.bmp', '.ico', '.webp', '.svg',
  '.pdf', '.doc', '.docx', '.xls', '.xlsx', '.ppt', '.pptx',
  '.zip', '.tar', '.gz', '.rar', '.7z',
  '.exe', '.dll', '.so', '.dylib',
  '.woff', '.woff2', '.ttf', '.eot',
  '.mp3', '.mp4', '.avi', '.mov', '.wav',
  '.o', '.a', '.lib', '.obj',
  '.pyc', '.class', '.jar',
];

/**
 * Default directories to skip during search
 */
export const DEFAULT_SKIP_DIRECTORIES = [
  'node_modules',
  '__pycache__',
  'dist',
  'build',
  '.git',
  '.svn',
  '.hg',
  'vendor',
  'target',
];

/**
 * Complete default settings
 */
export const DEFAULT_SETTINGS: TronSettings = {
  version: '0.1.0',
  name: 'tron',

  // API Configuration
  api: {
    anthropic: {
      authUrl: 'https://claude.ai/oauth/authorize',
      tokenUrl: 'https://console.anthropic.com/v1/oauth/token',
      // Use Anthropic's code callback page - displays code for user to copy/paste
      // This avoids Cloudflare blocking issues with local callback servers
      redirectUri: 'https://console.anthropic.com/oauth/code/callback',
      clientId: '9d1c250a-e61b-44d9-88ed-5944d1962f5e', // Claude CLI OAuth client ID
      // Required scopes: org:create_api_key is needed for OAuth to work with Claude Max subscriptions
      scopes: ['org:create_api_key', 'user:profile', 'user:inference'],
      systemPromptPrefix: "You are Claude Code, Anthropic's official CLI for Claude.",
      oauthBetaHeaders: 'oauth-2025-04-20,interleaved-thinking-2025-05-14,fine-grained-tool-streaming-2025-05-14',
      tokenExpiryBufferSeconds: 300,
    },
    // OpenAI Codex OAuth configuration (for ChatGPT Plus/Pro subscription access)
    // Based on: https://github.com/badlogic/pi-mono/blob/main/packages/ai/src/utils/oauth/openai-codex.ts
    openaiCodex: {
      authUrl: 'https://auth.openai.com/oauth/authorize',
      tokenUrl: 'https://auth.openai.com/oauth/token',
      clientId: 'app_EMoamEEZ73f0CkXaXp7hrann', // pi-mono client ID
      scopes: ['openid', 'profile', 'email', 'offline_access'],
      baseUrl: 'https://chatgpt.com/backend-api',
      tokenExpiryBufferSeconds: 300,
      defaultReasoningEffort: 'medium',
    },
  },

  // Model Configuration
  models: {
    default: 'claude-opus-4-5-20251101',
    defaultMaxTokens: 16384,  // Claude Opus 4.5 supports up to 64K; 16K is a safe default
    defaultThinkingBudget: 2048,
  },

  // Retry Configuration
  retry: {
    maxRetries: 5,
    baseDelayMs: 1000,
    maxDelayMs: 60000,
    jitterFactor: 0.2,
  },

  // Tool Configuration
  tools: {
    bash: {
      defaultTimeoutMs: 120000,  // 2 minutes
      maxTimeoutMs: 600000,      // 10 minutes
      maxOutputLength: 30000,
      dangerousPatterns: DEFAULT_DANGEROUS_PATTERNS,
    },
    read: {
      defaultLimitLines: 2000,
      maxLineLength: 2000,
    },
    find: {
      defaultMaxResults: 100,
      defaultMaxDepth: 10,
    },
    grep: {
      defaultMaxResults: 100,
      maxFileSizeBytes: 10 * 1024 * 1024,  // 10MB
      binaryExtensions: DEFAULT_BINARY_EXTENSIONS,
      skipDirectories: DEFAULT_SKIP_DIRECTORIES,
    },
  },

  // Context Configuration
  context: {
    compactor: {
      maxTokens: 25000,
      compactionThreshold: 0.85,
      targetTokens: 10000,
      preserveRecentCount: 2,
      charsPerToken: 4,
    },
    memory: {
      maxEntries: 1000,
    },
  },

  // Hook Configuration
  hooks: {
    defaultTimeoutMs: 5000,
    discoveryTimeoutMs: 10000,
    projectDir: '.agent/hooks',
    userDir: '.config/tron/hooks',
    extensions: ['.ts', '.js', '.mjs', '.sh'],
  },

  // Server Configuration
  server: {
    wsPort: 8080,
    healthPort: 8081,
    host: '0.0.0.0',
    heartbeatIntervalMs: 30000,
    sessionTimeoutMs: 1800000,  // 30 minutes
    maxConcurrentSessions: 10,
    sessionsDir: 'sessions',
    memoryDbPath: 'memory.db',
    defaultModel: 'claude-sonnet-4-20250514',
    defaultProvider: 'anthropic',
    transcription: {
      enabled: true,
      manageSidecar: true,
      baseUrl: 'http://127.0.0.1:8787',
      timeoutMs: 180000,
      cleanupMode: 'basic',
      maxBytes: 25 * 1024 * 1024,
    },
  },

  // Tmux Configuration
  tmux: {
    commandTimeoutMs: 30000,
    pollingIntervalMs: 500,
  },

  // Session Configuration
  session: {
    worktreeTimeoutMs: 30000,
  },

  // UI Configuration
  ui: {
    theme: 'forest_green',
    palette: {
      primary: '#123524',
      primaryLight: '#1a4a32',
      primaryBright: '#2d7a4e',
      primaryVivid: '#34d399',
      emerald: '#10b981',
      mint: '#6ee7b7',
      sage: '#86efac',
      dark: '#0a1f15',
      muted: '#1f3d2c',
      subtle: '#2d5a40',
      textBright: '#ecfdf5',
      textPrimary: '#d1fae5',
      textSecondary: '#a7f3d0',
      textMuted: '#6b8f7a',
      textDim: '#4a6b58',
      statusBarText: '#2eb888',
      success: '#22c55e',
      warning: '#f59e0b',
      error: '#ef4444',
      info: '#38bdf8',
    },
    icons: {
      prompt: '\u203a',        // ›
      user: '\u203a',          // ›
      assistant: '\u25c6',     // ◆
      system: '\u25c7',        // ◇
      toolRunning: '\u25c7',   // ◇
      toolSuccess: '\u25c6',   // ◆
      toolError: '\u25c8',     // ◈
      ready: '\u25c6',         // ◆
      thinking: '\u25c7',      // ◇
      streaming: '\u25c6',     // ◆
      bullet: '\u2022',        // •
      arrow: '\u2192',         // →
      check: '\u2713',         // ✓
      pasteOpen: '\u2308',     // ⌈
      pasteClose: '\u230b',    // ⌋
    },
    thinkingAnimation: {
      chars: ['\u2581', '\u2582', '\u2583', '\u2584', '\u2585'],  // ▁▂▃▄▅
      width: 4,
      intervalMs: 120,
    },
    input: {
      pasteThreshold: 3,
      maxHistory: 100,
      defaultTerminalWidth: 80,
      narrowThreshold: 50,
      narrowVisibleLines: 10,
      normalVisibleLines: 20,
    },
    menu: {
      maxVisibleCommands: 5,
    },
  },
};

/**
 * Get a specific default value by path
 * @param path - Dot-separated path to the setting
 * @returns The default value or undefined if not found
 */
export function getDefault<T>(path: string): T | undefined {
  const parts = path.split('.');
  let current: unknown = DEFAULT_SETTINGS;

  for (const part of parts) {
    if (current && typeof current === 'object' && part in current) {
      current = (current as Record<string, unknown>)[part];
    } else {
      return undefined;
    }
  }

  return current as T;
}
