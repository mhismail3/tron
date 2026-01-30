/**
 * @fileoverview Transcription sidecar manager.
 *
 * Starts the local transcription sidecar when the Tron server boots.
 * Includes:
 * - Health and readiness checking
 * - Automatic restart via watchdog on crashes
 * - Structured log parsing from Python sidecar
 */
import { createLogger, categorizeError, LogErrorCategory } from '../logging/index.js';
import { getSettings } from '../settings/index.js';
import type { TranscriptionSettings } from '../settings/types.js';
import { spawn, type ChildProcessWithoutNullStreams } from 'node:child_process';
import { existsSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { setTimeout as delay } from 'node:timers/promises';

const logger = createLogger('transcription-sidecar');

/**
 * Get default transcription settings from the global settings.
 * Used for backwards compatibility when settings not explicitly provided.
 */
export function getDefaultTranscriptionSettings(): TranscriptionSettings {
  return getSettings().server.transcription;
}

// Health check constants
const HEALTH_TIMEOUT_MS = 2000;
const STARTUP_TIMEOUT_MS = 20000;
const HEALTH_RETRY_DELAY_MS = 300;

// Readiness constants (model warmup can take 30-120+ seconds)
const READINESS_TIMEOUT_MS = 180000; // 3 minutes for model loading
const READINESS_RETRY_DELAY_MS = 500;
const READINESS_INITIAL_DELAY_MS = 30000; // Wait 30s before starting readiness checks

// Watchdog constants
const WATCHDOG_INTERVAL_MS = 30000; // Check every 30s
const RESTART_BACKOFF_BASE_MS = 1000;
const RESTART_BACKOFF_MAX_MS = 60000;
export const MAX_RESTART_ATTEMPTS = 5;

let sidecarProcess: ChildProcessWithoutNullStreams | null = null;
let sidecarOwned = false;
let sidecarStarting = false;

/**
 * Set sidecar ownership state (for testing only).
 * @internal
 */
export function _setSidecarOwned(owned: boolean): void {
  sidecarOwned = owned;
}

/**
 * Get sidecar ownership state (for testing only).
 * @internal
 */
export function _getSidecarOwned(): boolean {
  return sidecarOwned;
}

// Watchdog instance (lazy initialized after class definition)
let watchdog: SidecarWatchdog | null = null;

function getWatchdog(): SidecarWatchdog {
  if (!watchdog) {
    watchdog = new SidecarWatchdog();
  }
  return watchdog;
}

/**
 * Structured log entry from Python sidecar.
 */
export interface SidecarLogEntry {
  timestamp: string;
  level: string;
  component: string;
  message: string;
  module?: string;
  function?: string;
  line?: number;
  data?: Record<string, unknown>;
  error?: {
    type?: string;
    message?: string;
    stack?: string;
  };
}

/**
 * Parse structured JSON logs from sidecar stdout/stderr.
 * Returns null if the line is not a valid structured log.
 */
export function parseSidecarLog(line: string): SidecarLogEntry | null {
  try {
    const parsed = JSON.parse(line);
    if (parsed.component === 'transcription-sidecar') {
      return parsed as SidecarLogEntry;
    }
  } catch {
    // Not JSON, treat as raw log
  }
  return null;
}

/**
 * Check if sidecar is healthy (responding to /health).
 * This is a liveness check - returns true if the server is running.
 */
export async function isSidecarHealthy(baseUrl: string): Promise<boolean> {
  const url = new URL('/health', baseUrl).toString();
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), HEALTH_TIMEOUT_MS);

  try {
    const response = await fetch(url, { signal: controller.signal });
    return response.ok;
  } catch {
    return false;
  } finally {
    clearTimeout(timeout);
  }
}

/**
 * Check if sidecar is ready (model loaded and ready for transcription).
 * This is a readiness check - returns true only after warmup completes.
 */
export async function isSidecarReady(baseUrl: string): Promise<boolean> {
  const url = new URL('/ready', baseUrl).toString();
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), HEALTH_TIMEOUT_MS);

  try {
    const response = await fetch(url, { signal: controller.signal });
    return response.ok;
  } catch {
    return false;
  } finally {
    clearTimeout(timeout);
  }
}

/**
 * Wait for sidecar to become healthy (responding to /health).
 */
async function waitForHealthy(baseUrl: string, timeoutMs: number): Promise<boolean> {
  const start = Date.now();
  while (Date.now() - start < timeoutMs) {
    if (await isSidecarHealthy(baseUrl)) {
      return true;
    }
    await delay(HEALTH_RETRY_DELAY_MS);
  }
  return false;
}

/**
 * Wait for sidecar to become ready (model loaded).
 * This may take 30-120+ seconds on first startup while model downloads/loads.
 * Includes an initial delay to reduce log noise during expected warmup period.
 */
export async function waitForReady(baseUrl: string, timeoutMs: number): Promise<boolean> {
  // Wait before starting readiness checks to reduce log noise during warmup
  logger.debug('Waiting for model warmup before starting readiness checks', {
    initialDelayMs: READINESS_INITIAL_DELAY_MS,
  });
  await delay(READINESS_INITIAL_DELAY_MS);

  const start = Date.now();
  const adjustedTimeout = timeoutMs - READINESS_INITIAL_DELAY_MS;

  while (Date.now() - start < adjustedTimeout) {
    if (await isSidecarReady(baseUrl)) {
      logger.info('Transcription model warmup complete');
      return true;
    }
    await delay(READINESS_RETRY_DELAY_MS);
  }
  return false;
}

/**
 * Watchdog that monitors sidecar health and triggers restart on failure.
 */
export class SidecarWatchdog {
  private intervalId: ReturnType<typeof setInterval> | null = null;
  private restartAttempts = 0;
  private lastRestartTime = 0;
  private running = false;

  /**
   * Check if the watchdog is currently running.
   */
  isRunning(): boolean {
    return this.running;
  }

  /**
   * Start monitoring the sidecar health.
   * @param baseUrl - The sidecar base URL to monitor
   * @param restartFn - Function to call to restart the sidecar
   */
  start(baseUrl: string, restartFn: () => Promise<void>): void {
    if (this.running) {
      return;
    }
    this.running = true;

    logger.info('Sidecar watchdog started', {
      baseUrl,
      intervalMs: WATCHDOG_INTERVAL_MS,
      maxRestartAttempts: MAX_RESTART_ATTEMPTS,
    });

    this.intervalId = setInterval(async () => {
      if (!sidecarOwned) {
        return;
      }

      const healthy = await isSidecarHealthy(baseUrl);

      if (!healthy) {
        logger.warn('Sidecar health check failed', {
          baseUrl,
          restartAttempts: this.restartAttempts,
          maxAttempts: MAX_RESTART_ATTEMPTS,
        });
        await this.attemptRestart(restartFn);
      } else {
        if (this.restartAttempts > 0) {
          logger.info('Sidecar recovered, resetting restart counter', {
            previousAttempts: this.restartAttempts,
          });
        }
        this.restartAttempts = 0;
      }
    }, WATCHDOG_INTERVAL_MS);
  }

  /**
   * Stop the watchdog.
   */
  stop(): void {
    if (this.intervalId) {
      clearInterval(this.intervalId);
      this.intervalId = null;
    }
    this.running = false;
    logger.debug('Sidecar watchdog stopped');
  }

  /**
   * Attempt to restart the sidecar with exponential backoff.
   */
  private async attemptRestart(restartFn: () => Promise<void>): Promise<void> {
    if (this.restartAttempts >= MAX_RESTART_ATTEMPTS) {
      logger.error('Max sidecar restart attempts reached, giving up', {
        attempts: this.restartAttempts,
        maxAttempts: MAX_RESTART_ATTEMPTS,
      });
      return;
    }

    const backoffMs = Math.min(
      RESTART_BACKOFF_BASE_MS * Math.pow(2, this.restartAttempts),
      RESTART_BACKOFF_MAX_MS
    );

    const timeSince = Date.now() - this.lastRestartTime;
    if (timeSince < backoffMs) {
      const waitMs = backoffMs - timeSince;
      logger.debug('Waiting for backoff before restart', {
        backoffMs,
        waitMs,
        attempt: this.restartAttempts + 1,
      });
      await delay(waitMs);
    }

    this.restartAttempts++;
    this.lastRestartTime = Date.now();

    logger.info('Attempting sidecar restart', {
      attempt: this.restartAttempts,
      maxAttempts: MAX_RESTART_ATTEMPTS,
      backoffMs,
    });

    try {
      // Kill existing process if any
      if (sidecarProcess) {
        logger.debug('Killing existing sidecar process');
        sidecarProcess.kill('SIGTERM');
        await waitForExit(sidecarProcess, 5000);
        sidecarProcess = null;
        // Note: Don't set sidecarOwned = false here, as that would cause
        // the watchdog to skip subsequent health checks if restart fails.
        // The 'exit' handler on the child process will set it to false,
        // but restartFn will set it back to true when starting the new process.
      }

      await restartFn();

      logger.info('Sidecar restart successful', {
        attempt: this.restartAttempts,
      });
    } catch (error) {
      // Restart failed - mark as not owned so watchdog can try again
      // on next interval (if we haven't exhausted attempts)
      sidecarOwned = true; // Keep true so watchdog continues monitoring
      logger.error('Sidecar restart failed', {
        attempt: this.restartAttempts,
        err: error instanceof Error ? error : new Error(String(error)),
      });
    }
  }

  /**
   * Reset the restart counter (for testing).
   */
  resetCounter(): void {
    this.restartAttempts = 0;
    this.lastRestartTime = 0;
  }
}

export async function ensureTranscriptionSidecar(): Promise<void> {
  const settings = getDefaultTranscriptionSettings();
  if (!settings.enabled || !settings.manageSidecar) {
    return;
  }

  if (!isLoopbackUrl(settings.baseUrl)) {
    logger.info('Skipping transcription sidecar auto-start (non-local baseUrl)', {
      baseUrl: settings.baseUrl,
    });
    return;
  }

  if (await isSidecarHealthy(settings.baseUrl)) {
    logger.debug('Transcription sidecar already running');
    return;
  }

  if (sidecarStarting || sidecarOwned) {
    return;
  }

  const repoRoot = findRepoRoot(process.env.TRON_REPO_ROOT ?? process.cwd());
  if (!repoRoot) {
    logger.error('Unable to locate transcription sidecar. Set TRON_REPO_ROOT to the repo path.');
    return;
  }

  const sidecarDir = path.join(repoRoot, 'services', 'transcribe');
  const pythonBin = await ensureVenvPython(sidecarDir);
  if (!pythonBin) {
    return;
  }

  startSidecarProcess(pythonBin, repoRoot);

  const ready = await waitForHealthy(settings.baseUrl, STARTUP_TIMEOUT_MS);
  if (!ready) {
    logger.error('Transcription sidecar did not become healthy before timeout');
    return;
  }

  logger.info('Transcription sidecar started');

  // Start watchdog to monitor health and auto-restart
  getWatchdog().start(settings.baseUrl, async () => {
    const newRepoRoot = findRepoRoot(process.env.TRON_REPO_ROOT ?? process.cwd());
    if (!newRepoRoot) {
      throw new Error('Unable to locate repo root for sidecar restart');
    }
    const newSidecarDir = path.join(newRepoRoot, 'services', 'transcribe');
    const newPythonBin = await ensureVenvPython(newSidecarDir);
    if (!newPythonBin) {
      throw new Error('Unable to find Python for sidecar restart');
    }
    startSidecarProcess(newPythonBin, newRepoRoot);
    await waitForHealthy(settings.baseUrl, STARTUP_TIMEOUT_MS);
  });

  // Wait for model readiness in background (non-blocking)
  // This allows the server to start while model loads
  waitForReady(settings.baseUrl, READINESS_TIMEOUT_MS)
    .then((modelReady) => {
      if (!modelReady) {
        logger.warn('Model warmup timed out - first transcription request may be slow');
      }
    })
    .catch((error) => {
      // This shouldn't happen since waitForReady catches all errors internally,
      // but handle it defensively to prevent unhandled rejection
      logger.error('Error waiting for model readiness', {
        err: error instanceof Error ? error : new Error(String(error)),
      });
    });
}

export async function stopTranscriptionSidecar(): Promise<void> {
  // Stop watchdog first
  getWatchdog().stop();

  if (!sidecarProcess || !sidecarOwned) {
    return;
  }

  const processToStop = sidecarProcess;
  sidecarProcess = null;
  sidecarOwned = false;
  sidecarStarting = false;

  logger.info('Stopping transcription sidecar');
  processToStop.kill('SIGTERM');
  await waitForExit(processToStop, 5000);
}

function startSidecarProcess(pythonBin: string, repoRoot: string): void {
  sidecarStarting = true;
  sidecarOwned = true;

  const transcribeBaseDir =
    process.env.TRON_TRANSCRIBE_BASE_DIR ?? path.join(os.homedir(), '.tron', 'mods', 'transcribe');
  const hfCacheDir = path.join(transcribeBaseDir, 'models', 'hf');

  const env = {
    ...process.env,
    PYTHONPATH: repoRoot,
    ...(process.env.HUGGINGFACE_HUB_CACHE || process.env.HF_HOME
      ? {}
      : { HUGGINGFACE_HUB_CACHE: hfCacheDir }),
  };

  const child = spawn(pythonBin, ['-m', 'services.transcribe.app'], {
    cwd: repoRoot,
    env,
    stdio: ['pipe', 'pipe', 'pipe'],
  });

  sidecarProcess = child;

  child.stdout.on('data', (chunk) => logSidecarOutput(chunk, 'info'));
  child.stderr.on('data', (chunk) => logSidecarOutput(chunk, 'warn'));

  child.on('error', (error) => {
    logger.error('Transcription sidecar failed to start', error);
  });

  child.on('exit', (code, signal) => {
    logger.warn('Transcription sidecar exited', { code, signal });
    sidecarProcess = null;
    sidecarOwned = false;
    sidecarStarting = false;
  });

  sidecarStarting = false;
}

async function ensureVenvPython(sidecarDir: string): Promise<string | null> {
  const venvDir = path.join(sidecarDir, '.venv');
  const venvPython = path.join(venvDir, 'bin', 'python');
  if (existsSync(venvPython)) {
    return venvPython;
  }

  const systemPython = await resolveSystemPython();
  if (!systemPython) {
    logger.error('Python interpreter not found. Install python3.11 or python3.12, or set TRON_PYTHON.');
    return null;
  }
  logger.info('Using Python interpreter for transcription venv', { python: systemPython });

  logger.info('Creating transcription venv', { venvDir });
  try {
    await runCommand(systemPython, ['-m', 'venv', venvDir], sidecarDir, 'venv');
  } catch (error) {
    const structured = categorizeError(error, { venvDir, operation: 'createVenv' });
    logger.error('Failed to create transcription venv', {
      code: structured.code,
      category: LogErrorCategory.NETWORK,
      error: structured.message,
      retryable: structured.retryable,
    });
    return null;
  }

  logger.info('Installing transcription dependencies');
  try {
    await runCommand(venvPython, ['-m', 'pip', 'install', '-r', 'requirements.txt'], sidecarDir, 'pip');
  } catch (error) {
    const structured = categorizeError(error, { venvDir, operation: 'installDependencies' });
    logger.error('Failed to install transcription dependencies', {
      code: structured.code,
      category: LogErrorCategory.NETWORK,
      error: structured.message,
      retryable: structured.retryable,
    });
    return null;
  }

  return venvPython;
}

async function resolveSystemPython(): Promise<string | null> {
  // Prefer Python 3.11/3.12 for ML package compatibility (onnxruntime, etc.)
  // Python 3.13+ often lacks wheels for ML dependencies
  const candidates = [
    process.env.TRON_PYTHON,
    'python3.11',
    'python3.12',
    'python3.10',
    'python3',
    'python',
  ].filter(Boolean) as string[];
  for (const candidate of candidates) {
    if (await canExecute(candidate)) {
      return candidate;
    }
  }
  return null;
}

async function canExecute(command: string): Promise<boolean> {
  return new Promise((resolve) => {
    const child = spawn(command, ['--version'], { stdio: 'ignore' });
    child.on('error', () => resolve(false));
    child.on('exit', (code) => resolve(code === 0));
  });
}

async function runCommand(command: string, args: string[], cwd: string, label: string): Promise<void> {
  return new Promise((resolve, reject) => {
    const child = spawn(command, args, {
      cwd,
      env: process.env,
      stdio: ['ignore', 'pipe', 'pipe'],
    });

    child.stdout.on('data', (chunk) => logSidecarOutput(chunk, 'debug', label));
    child.stderr.on('data', (chunk) => logSidecarOutput(chunk, 'warn', label));

    child.on('error', reject);
    child.on('exit', (code) => {
      if (code === 0) {
        resolve();
      } else {
        reject(new Error(`${label} exited with code ${code ?? 'unknown'}`));
      }
    });
  });
}

/**
 * Log sidecar output, parsing structured JSON logs when available.
 */
function logSidecarOutput(chunk: Buffer, defaultLevel: 'debug' | 'info' | 'warn', label?: string): void {
  const prefix = label ? `[${label}] ` : '';
  const lines = chunk.toString('utf-8').split(/\r?\n/).filter(Boolean);

  for (const line of lines) {
    const structured = parseSidecarLog(line);

    if (structured) {
      // Structured log from sidecar - use appropriate level
      const logFn =
        structured.level === 'error'
          ? logger.error
          : structured.level === 'warn' || structured.level === 'warning'
            ? logger.warn
            : structured.level === 'debug'
              ? logger.debug
              : logger.info;

      const metadata: Record<string, unknown> = {
        sidecar: true,
        ...(structured.module && { module: structured.module }),
        ...(structured.function && { function: structured.function }),
        ...structured.data,
      };

      if (structured.error) {
        metadata.err = new Error(structured.error.message ?? 'Unknown error');
        metadata.errorType = structured.error.type;
      }

      logFn.call(logger, structured.message, metadata);
    } else {
      // Raw log line - use default level
      if (defaultLevel === 'debug') {
        logger.debug(`${prefix}${line}`, { sidecar: true });
      } else if (defaultLevel === 'info') {
        logger.info(`${prefix}${line}`, { sidecar: true });
      } else {
        logger.warn(`${prefix}${line}`, { sidecar: true });
      }
    }
  }
}

function findRepoRoot(start: string): string | null {
  let current = path.resolve(start);
  while (true) {
    const marker = path.join(current, 'services', 'transcribe', 'app.py');
    if (existsSync(marker)) {
      return current;
    }
    const parent = path.dirname(current);
    if (parent === current) {
      return null;
    }
    current = parent;
  }
}

function isLoopbackUrl(baseUrl: string): boolean {
  try {
    const parsed = new URL(baseUrl);
    const host = parsed.hostname;
    return host === '127.0.0.1' || host === 'localhost' || host === '::1';
  } catch {
    return false;
  }
}

async function waitForExit(processToStop: ChildProcessWithoutNullStreams, timeoutMs: number): Promise<void> {
  const exitPromise = new Promise<void>((resolve) => {
    processToStop.on('exit', () => resolve());
  });

  await Promise.race([exitPromise, delay(timeoutMs)]);

  if (processToStop.exitCode == null) {
    processToStop.kill('SIGKILL');
  }
}
