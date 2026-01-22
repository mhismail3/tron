/**
 * @fileoverview tmux Session Manager
 *
 * Provides tmux integration for spawning and managing agent sessions
 * in isolated terminal environments. Enables parallel agent execution
 * and persistent session management.
 *
 * @example
 * ```typescript
 * const tmux = new TmuxManager({ prefix: 'agent' });
 *
 * const sessionName = await tmux.spawn('build', ['-v']);
 * await tmux.attach(sessionName);
 * await tmux.kill(sessionName);
 * ```
 */
import { spawn, exec } from 'child_process';
import { promisify } from 'util';
import { createLogger } from '../logging/logger.js';

const execAsync = promisify(exec);
const logger = createLogger('tmux');

// =============================================================================
// Types
// =============================================================================

export interface TmuxManagerConfig {
  /** Prefix for session names (default: 'agent') */
  prefix?: string;
  /** Shell to use (default: process.env.SHELL || '/bin/bash') */
  shell?: string;
  /** Default working directory */
  cwd?: string;
  /** Environment variables to pass to sessions */
  env?: Record<string, string>;
  /** tmux socket path (for custom socket) */
  socketPath?: string;
}

export interface TmuxSession {
  /** Session name */
  name: string;
  /** Session ID (numeric) */
  id: string;
  /** Number of windows */
  windows: number;
  /** Whether session is attached */
  attached: boolean;
  /** Creation timestamp */
  created: Date;
  /** Last activity timestamp */
  activity: Date;
  /** Working directory */
  cwd?: string;
}

export interface TmuxWindow {
  /** Window index */
  index: number;
  /** Window name */
  name: string;
  /** Number of panes */
  panes: number;
  /** Whether window is active */
  active: boolean;
  /** Current layout */
  layout?: string;
}

export interface TmuxPane {
  /** Pane index */
  index: number;
  /** Pane title */
  title: string;
  /** Whether pane is active */
  active: boolean;
  /** Current working directory */
  cwd?: string;
  /** Current command running */
  currentCommand?: string;
  /** Pane width */
  width: number;
  /** Pane height */
  height: number;
}

export interface SpawnOptions {
  /** Window name */
  windowName?: string;
  /** Working directory */
  cwd?: string;
  /** Environment variables */
  env?: Record<string, string>;
  /** Start in detached mode (default: true) */
  detached?: boolean;
  /** Initial command to run */
  command?: string;
  /** Shell arguments */
  shellArgs?: string[];
}

export interface SendKeysOptions {
  /** Target pane (format: session:window.pane) */
  target?: string;
  /** Whether to send Enter after keys */
  enter?: boolean;
  /** Literal mode (don't interpret special keys) */
  literal?: boolean;
}

// =============================================================================
// tmux Manager Implementation
// =============================================================================

export class TmuxManager {
  private config: Required<TmuxManagerConfig>;
  private sessionCounter = 0;

  constructor(config: TmuxManagerConfig = {}) {
    this.config = {
      prefix: 'agent',
      shell: process.env.SHELL || '/bin/bash',
      cwd: process.cwd(),
      env: {},
      socketPath: '',
      ...config,
    };
  }

  /**
   * Check if tmux is available
   */
  async isAvailable(): Promise<boolean> {
    try {
      await execAsync('which tmux');
      return true;
    } catch {
      return false;
    }
  }

  /**
   * Check if tmux server is running
   */
  async isServerRunning(): Promise<boolean> {
    try {
      await this.exec(['has-session']);
      return true;
    } catch {
      return false;
    }
  }

  /**
   * Generate a unique session name
   */
  private generateSessionName(skillName: string): string {
    this.sessionCounter++;
    const timestamp = Date.now().toString(36).slice(-4);
    return `${this.config.prefix}-${skillName}-${timestamp}`;
  }

  /**
   * Spawn a new tmux session for an agent skill
   */
  async spawn(
    skillName: string,
    args: string[] = [],
    options: SpawnOptions = {}
  ): Promise<string> {
    const sessionName = this.generateSessionName(skillName);
    const cwd = options.cwd || this.config.cwd;

    logger.debug('Spawning tmux session', { sessionName, skillName, cwd });

    const tmuxArgs = [
      'new-session',
      '-d',
      '-s', sessionName,
      '-c', cwd,
    ];

    // Add window name
    if (options.windowName) {
      tmuxArgs.push('-n', options.windowName);
    }

    // Add environment variables
    const env = { ...this.config.env, ...options.env };
    for (const [key, value] of Object.entries(env)) {
      tmuxArgs.push('-e', `${key}=${value}`);
    }

    // Add initial command if provided
    if (options.command) {
      tmuxArgs.push(options.command);
      if (args.length > 0) {
        tmuxArgs.push(...args);
      }
    }

    await this.exec(tmuxArgs);

    logger.info('tmux session created', { sessionName, skillName });
    return sessionName;
  }

  /**
   * Attach to an existing session
   */
  async attach(sessionName: string): Promise<void> {
    logger.debug('Attaching to session', { sessionName });

    // Use spawn for interactive attach (not exec)
    return new Promise((resolve, reject) => {
      const args = this.buildArgs(['attach-session', '-t', sessionName]);
      const proc = spawn('tmux', args, {
        stdio: 'inherit',
        env: process.env,
      });

      proc.on('close', (code) => {
        if (code === 0) {
          resolve();
        } else {
          reject(new Error(`tmux attach exited with code ${code}`));
        }
      });

      proc.on('error', reject);
    });
  }

  /**
   * Detach from current session
   */
  async detach(): Promise<void> {
    await this.exec(['detach-client']);
  }

  /**
   * Kill a session
   */
  async kill(sessionName: string): Promise<boolean> {
    try {
      await this.exec(['kill-session', '-t', sessionName]);
      logger.info('tmux session killed', { sessionName });
      return true;
    } catch (error) {
      logger.warn('Failed to kill session', { sessionName, error });
      return false;
    }
  }

  /**
   * List all agent sessions
   */
  async list(): Promise<TmuxSession[]> {
    try {
      const format = [
        '#{session_name}',
        '#{session_id}',
        '#{session_windows}',
        '#{session_attached}',
        '#{session_created}',
        '#{session_activity}',
        '#{pane_current_path}',
      ].join('|');

      const { stdout } = await this.exec([
        'list-sessions',
        '-F', format,
      ]);

      const sessions: TmuxSession[] = [];
      const lines = stdout.trim().split('\n').filter(Boolean);

      for (const line of lines) {
        const parts = line.split('|');
        if (parts.length < 6) continue;
        const [name, id, windows, attached, created, activity, cwd] = parts;

        // Filter by prefix
        if (!name?.startsWith(this.config.prefix)) continue;

        sessions.push({
          name: name!,
          id: id!,
          windows: parseInt(windows!, 10),
          attached: attached === '1',
          created: new Date(parseInt(created!, 10) * 1000),
          activity: new Date(parseInt(activity!, 10) * 1000),
          cwd: cwd,
        });
      }

      return sessions;
    } catch {
      return [];
    }
  }

  /**
   * Check if a session exists
   */
  async exists(sessionName: string): Promise<boolean> {
    try {
      await this.exec(['has-session', '-t', sessionName]);
      return true;
    } catch {
      return false;
    }
  }

  /**
   * Send keys to a session
   */
  async sendKeys(
    sessionName: string,
    keys: string,
    options: SendKeysOptions = {}
  ): Promise<void> {
    const target = options.target || sessionName;
    const args = ['send-keys', '-t', target];

    if (options.literal) {
      args.push('-l');
    }

    args.push(keys);

    if (options.enter !== false) {
      args.push('Enter');
    }

    await this.exec(args);
  }

  /**
   * Send a command to a session
   */
  async sendCommand(sessionName: string, command: string): Promise<void> {
    await this.sendKeys(sessionName, command, { enter: true });
  }

  /**
   * Capture pane content
   */
  async capturePane(
    sessionName: string,
    options: { start?: number; end?: number; target?: string } = {}
  ): Promise<string> {
    const target = options.target || sessionName;
    const args = ['capture-pane', '-t', target, '-p'];

    if (options.start !== undefined) {
      args.push('-S', options.start.toString());
    }

    if (options.end !== undefined) {
      args.push('-E', options.end.toString());
    }

    const { stdout } = await this.exec(args);
    return stdout;
  }

  /**
   * Create a new window in a session
   */
  async newWindow(
    sessionName: string,
    options: { name?: string; command?: string; cwd?: string } = {}
  ): Promise<number> {
    const args = ['new-window', '-t', sessionName];

    if (options.name) {
      args.push('-n', options.name);
    }

    if (options.cwd) {
      args.push('-c', options.cwd);
    }

    if (options.command) {
      args.push(options.command);
    }

    await this.exec(args);

    // Get the new window index
    const windows = await this.listWindows(sessionName);
    return windows.length > 0 ? windows[windows.length - 1]!.index : 0;
  }

  /**
   * List windows in a session
   */
  async listWindows(sessionName: string): Promise<TmuxWindow[]> {
    const format = [
      '#{window_index}',
      '#{window_name}',
      '#{window_panes}',
      '#{window_active}',
      '#{window_layout}',
    ].join('|');

    try {
      const { stdout } = await this.exec([
        'list-windows',
        '-t', sessionName,
        '-F', format,
      ]);

      return stdout.trim().split('\n').filter(Boolean).map(line => {
        const [index, name, panes, active, layout] = line.split('|');
        return {
          index: parseInt(index!, 10),
          name: name!,
          panes: parseInt(panes!, 10),
          active: active === '1',
          layout,
        };
      });
    } catch {
      return [];
    }
  }

  /**
   * List panes in a window
   */
  async listPanes(sessionName: string, windowIndex?: number): Promise<TmuxPane[]> {
    const target = windowIndex !== undefined
      ? `${sessionName}:${windowIndex}`
      : sessionName;

    const format = [
      '#{pane_index}',
      '#{pane_title}',
      '#{pane_active}',
      '#{pane_current_path}',
      '#{pane_current_command}',
      '#{pane_width}',
      '#{pane_height}',
    ].join('|');

    try {
      const { stdout } = await this.exec([
        'list-panes',
        '-t', target,
        '-F', format,
      ]);

      return stdout.trim().split('\n').filter(Boolean).map(line => {
        const [index, title, active, cwd, cmd, width, height] = line.split('|');
        return {
          index: parseInt(index!, 10),
          title: title!,
          active: active === '1',
          cwd,
          currentCommand: cmd,
          width: parseInt(width!, 10),
          height: parseInt(height!, 10),
        };
      });
    } catch {
      return [];
    }
  }

  /**
   * Split a pane
   */
  async splitPane(
    sessionName: string,
    options: {
      horizontal?: boolean;
      percentage?: number;
      command?: string;
      cwd?: string;
    } = {}
  ): Promise<void> {
    const args = ['split-window', '-t', sessionName];

    if (options.horizontal) {
      args.push('-h');
    } else {
      args.push('-v');
    }

    if (options.percentage) {
      args.push('-p', options.percentage.toString());
    }

    if (options.cwd) {
      args.push('-c', options.cwd);
    }

    if (options.command) {
      args.push(options.command);
    }

    await this.exec(args);
  }

  /**
   * Select a window
   */
  async selectWindow(sessionName: string, windowIndex: number): Promise<void> {
    await this.exec(['select-window', '-t', `${sessionName}:${windowIndex}`]);
  }

  /**
   * Select a pane
   */
  async selectPane(sessionName: string, paneIndex: number): Promise<void> {
    await this.exec(['select-pane', '-t', `${sessionName}.${paneIndex}`]);
  }

  /**
   * Rename a session
   */
  async renameSession(oldName: string, newName: string): Promise<void> {
    await this.exec(['rename-session', '-t', oldName, newName]);
  }

  /**
   * Kill all agent sessions
   */
  async killAll(): Promise<number> {
    const sessions = await this.list();
    let killed = 0;

    for (const session of sessions) {
      if (await this.kill(session.name)) {
        killed++;
      }
    }

    logger.info('Killed all agent sessions', { count: killed });
    return killed;
  }

  /**
   * Wait for a pane to contain specific text
   */
  async waitForText(
    sessionName: string,
    pattern: string | RegExp,
    options: { timeout?: number; interval?: number } = {}
  ): Promise<boolean> {
    const timeout = options.timeout ?? 30000;
    const interval = options.interval ?? 500;
    const start = Date.now();

    const regex = typeof pattern === 'string' ? new RegExp(pattern) : pattern;

    while (Date.now() - start < timeout) {
      const content = await this.capturePane(sessionName);
      if (regex.test(content)) {
        return true;
      }
      await new Promise(resolve => setTimeout(resolve, interval));
    }

    return false;
  }

  /**
   * Get session info
   */
  async getSession(sessionName: string): Promise<TmuxSession | null> {
    const sessions = await this.list();
    return sessions.find(s => s.name === sessionName) ?? null;
  }

  // ===========================================================================
  // Private Helpers
  // ===========================================================================

  /**
   * Build tmux arguments with socket path if configured
   */
  private buildArgs(args: string[]): string[] {
    if (this.config.socketPath) {
      return ['-S', this.config.socketPath, ...args];
    }
    return args;
  }

  /**
   * Execute a tmux command
   */
  private async exec(args: string[]): Promise<{ stdout: string; stderr: string }> {
    const fullArgs = this.buildArgs(args);
    const cmd = `tmux ${fullArgs.map(a => `'${a}'`).join(' ')}`;

    logger.debug('Executing tmux command', { args: fullArgs });

    try {
      return await execAsync(cmd);
    } catch (error) {
      logger.error('tmux command failed', { args: fullArgs, error });
      throw error;
    }
  }
}

// =============================================================================
// Factory Function
// =============================================================================

export function createTmuxManager(config?: TmuxManagerConfig): TmuxManager {
  return new TmuxManager(config);
}
