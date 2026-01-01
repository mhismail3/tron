/**
 * @fileoverview TUI Debug Logger
 *
 * Provides comprehensive trace logging for debugging the TUI.
 * When enabled, outputs detailed information about:
 * - Session lifecycle (init, end)
 * - Message flow (user, assistant, tool)
 * - Tool execution (start, result, timing)
 * - Memory operations (ledger, handoffs)
 * - Context loading
 * - Provider API calls
 * - Errors and warnings
 */

import * as fs from 'fs';
import * as path from 'path';
import * as os from 'os';

// =============================================================================
// Types
// =============================================================================

export interface DebugLogEntry {
  timestamp: string;
  level: 'TRACE' | 'DEBUG' | 'INFO' | 'WARN' | 'ERROR';
  category: string;
  message: string;
  data?: Record<string, unknown>;
  duration?: number;
}

export interface DebugConfig {
  enabled: boolean;
  logToFile?: boolean;
  logToStderr?: boolean;
  logFilePath?: string;
  minLevel?: DebugLogEntry['level'];
}

// =============================================================================
// Constants
// =============================================================================

const LEVEL_PRIORITY: Record<DebugLogEntry['level'], number> = {
  TRACE: 0,
  DEBUG: 1,
  INFO: 2,
  WARN: 3,
  ERROR: 4,
};

const LEVEL_COLORS: Record<DebugLogEntry['level'], string> = {
  TRACE: '\x1b[90m',  // Gray
  DEBUG: '\x1b[36m',  // Cyan
  INFO: '\x1b[32m',   // Green
  WARN: '\x1b[33m',   // Yellow
  ERROR: '\x1b[31m',  // Red
};

const RESET = '\x1b[0m';
const DIM = '\x1b[2m';
const BOLD = '\x1b[1m';

// =============================================================================
// Debug Logger Class
// =============================================================================

class DebugLogger {
  private config: DebugConfig = { enabled: false };
  private fileStream: fs.WriteStream | null = null;
  private sessionId: string | null = null;
  private operationTimers: Map<string, number> = new Map();

  /**
   * Initialize the debug logger
   */
  initialize(config: DebugConfig): void {
    this.config = { ...config };

    if (this.config.enabled && this.config.logToFile) {
      const logPath = this.config.logFilePath ?? this.getDefaultLogPath();
      const logDir = path.dirname(logPath);

      // Ensure directory exists
      if (!fs.existsSync(logDir)) {
        fs.mkdirSync(logDir, { recursive: true });
      }

      this.fileStream = fs.createWriteStream(logPath, { flags: 'a' });
      this.info('debug', 'Debug logging initialized', { logPath });
    }

    if (this.config.enabled) {
      this.info('debug', 'Debug mode enabled', {
        logToFile: this.config.logToFile,
        logToStderr: this.config.logToStderr,
        minLevel: this.config.minLevel ?? 'TRACE',
      });
    }
  }

  /**
   * Set the current session ID for log correlation
   */
  setSessionId(sessionId: string): void {
    this.sessionId = sessionId;
  }

  /**
   * Start timing an operation
   */
  startTimer(operationId: string): void {
    this.operationTimers.set(operationId, Date.now());
  }

  /**
   * End timing and return duration
   */
  endTimer(operationId: string): number | undefined {
    const start = this.operationTimers.get(operationId);
    if (start) {
      this.operationTimers.delete(operationId);
      return Date.now() - start;
    }
    return undefined;
  }

  // ===========================================================================
  // Log Level Methods
  // ===========================================================================

  trace(category: string, message: string, data?: Record<string, unknown>): void {
    this.log('TRACE', category, message, data);
  }

  debug(category: string, message: string, data?: Record<string, unknown>): void {
    this.log('DEBUG', category, message, data);
  }

  info(category: string, message: string, data?: Record<string, unknown>): void {
    this.log('INFO', category, message, data);
  }

  warn(category: string, message: string, data?: Record<string, unknown>): void {
    this.log('WARN', category, message, data);
  }

  error(category: string, message: string, data?: Record<string, unknown>): void {
    this.log('ERROR', category, message, data);
  }

  // ===========================================================================
  // Specialized Log Methods
  // ===========================================================================

  /**
   * Log session lifecycle event
   */
  session(event: 'init' | 'ready' | 'end', data?: Record<string, unknown>): void {
    this.info('session', `Session ${event}`, { sessionId: this.sessionId, ...data });
  }

  /**
   * Log message event
   */
  message(direction: 'in' | 'out', role: string, preview: string, data?: Record<string, unknown>): void {
    const arrow = direction === 'in' ? '→' : '←';
    this.debug('message', `${arrow} ${role}: ${preview.slice(0, 100)}${preview.length > 100 ? '...' : ''}`, data);
  }

  /**
   * Log tool execution
   */
  tool(event: 'start' | 'end' | 'error', name: string, data?: Record<string, unknown>): void {
    const operationId = `tool:${name}:${Date.now()}`;

    if (event === 'start') {
      this.startTimer(operationId);
      this.debug('tool', `⚙ ${name} started`, data);
    } else if (event === 'end') {
      const duration = this.endTimer(operationId);
      this.debug('tool', `✓ ${name} completed`, { ...data, durationMs: duration });
    } else {
      this.error('tool', `✗ ${name} failed`, data);
    }
  }

  /**
   * Log memory operation
   */
  memory(operation: string, data?: Record<string, unknown>): void {
    this.trace('memory', operation, data);
  }

  /**
   * Log context loading
   */
  context(event: string, data?: Record<string, unknown>): void {
    this.trace('context', event, data);
  }

  /**
   * Log provider API call
   */
  provider(event: string, data?: Record<string, unknown>): void {
    this.trace('provider', event, data);
  }

  /**
   * Log agent event
   */
  agent(event: string, data?: Record<string, unknown>): void {
    this.trace('agent', event, data);
  }

  // ===========================================================================
  // Core Logging
  // ===========================================================================

  private log(
    level: DebugLogEntry['level'],
    category: string,
    message: string,
    data?: Record<string, unknown>
  ): void {
    if (!this.config.enabled) return;

    const minLevel = this.config.minLevel ?? 'TRACE';
    if (LEVEL_PRIORITY[level] < LEVEL_PRIORITY[minLevel]) return;

    const entry: DebugLogEntry = {
      timestamp: new Date().toISOString(),
      level,
      category,
      message,
      data,
    };

    // Output to stderr (visible in terminal)
    if (this.config.logToStderr !== false) {
      this.writeToStderr(entry);
    }

    // Output to file
    if (this.fileStream) {
      this.writeToFile(entry);
    }
  }

  private writeToStderr(entry: DebugLogEntry): void {
    const color = LEVEL_COLORS[entry.level];
    const timePart = entry.timestamp.split('T')[1] ?? '00:00:00';
    const time = timePart.split('.')[0] ?? '00:00:00';

    let line = `${DIM}[${time}]${RESET} ${color}${entry.level.padEnd(5)}${RESET} `;
    line += `${BOLD}${entry.category}${RESET}: ${entry.message}`;

    if (entry.data && Object.keys(entry.data).length > 0) {
      const dataStr = JSON.stringify(entry.data, null, 0);
      if (dataStr.length < 200) {
        line += ` ${DIM}${dataStr}${RESET}`;
      } else {
        line += `\n  ${DIM}${JSON.stringify(entry.data, null, 2).replace(/\n/g, '\n  ')}${RESET}`;
      }
    }

    process.stderr.write(line + '\n');
  }

  private writeToFile(entry: DebugLogEntry): void {
    const line = JSON.stringify({
      ...entry,
      sessionId: this.sessionId,
    }) + '\n';
    this.fileStream?.write(line);
  }

  private getDefaultLogPath(): string {
    const tronDir = path.join(os.homedir(), '.tron');
    const date = new Date().toISOString().split('T')[0];
    return path.join(tronDir, 'logs', `tui-debug-${date}.log`);
  }

  /**
   * Cleanup on exit
   */
  close(): void {
    if (this.fileStream) {
      this.fileStream.end();
      this.fileStream = null;
    }
  }
}

// =============================================================================
// Singleton Instance
// =============================================================================

export const debugLog = new DebugLogger();

/**
 * Initialize debug logging
 */
export function initializeDebug(enabled: boolean): void {
  debugLog.initialize({
    enabled,
    logToFile: enabled,
    logToStderr: enabled,
    minLevel: 'TRACE',
  });
}

/**
 * Check if debug mode is enabled
 */
export function isDebugEnabled(): boolean {
  return debugLog['config'].enabled;
}
