/**
 * @fileoverview Transcription sidecar manager.
 *
 * Starts the local transcription sidecar when the Tron server boots.
 */
import { createLogger } from '../logging/index.js';
import { getSettings } from '../settings/index.js';
import { spawn, type ChildProcessWithoutNullStreams } from 'node:child_process';
import { existsSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { setTimeout as delay } from 'node:timers/promises';

const logger = createLogger('transcription-sidecar');

const HEALTH_TIMEOUT_MS = 2000;
const STARTUP_TIMEOUT_MS = 20000;
const HEALTH_RETRY_DELAY_MS = 300;

let sidecarProcess: ChildProcessWithoutNullStreams | null = null;
let sidecarOwned = false;
let sidecarStarting = false;

export async function ensureTranscriptionSidecar(): Promise<void> {
  const settings = getSettings().server.transcription;
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
  }
}

export async function stopTranscriptionSidecar(): Promise<void> {
  if (!sidecarProcess || !sidecarOwned) {
    return;
  }

  const processToStop = sidecarProcess;
  sidecarProcess = null;
  sidecarOwned = false;
  sidecarStarting = false;

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

async function isSidecarHealthy(baseUrl: string): Promise<boolean> {
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
    logger.error('Failed to create transcription venv', error instanceof Error ? error : new Error(String(error)));
    return null;
  }

  logger.info('Installing transcription dependencies');
  try {
    await runCommand(venvPython, ['-m', 'pip', 'install', '-r', 'requirements.txt'], sidecarDir, 'pip');
  } catch (error) {
    logger.error('Failed to install transcription dependencies', error instanceof Error ? error : new Error(String(error)));
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

function logSidecarOutput(chunk: Buffer, level: 'debug' | 'info' | 'warn', label?: string): void {
  const prefix = label ? `[${label}] ` : '';
  const lines = chunk.toString('utf-8').split(/\r?\n/).filter(Boolean);
  for (const line of lines) {
    if (level === 'debug') {
      logger.debug(`${prefix}${line}`);
    } else if (level === 'info') {
      logger.info(`${prefix}${line}`);
    } else {
      logger.warn(`${prefix}${line}`);
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
