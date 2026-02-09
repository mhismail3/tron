/**
 * @fileoverview Canvas Artifact Store
 *
 * Persists rendered UI canvases to disk for session resumption.
 * Stores canvases in ~/.tron/artifacts/canvases/{canvasId}.json
 *
 * This is the server-side storage - iOS clients fetch via RPC.
 */

import * as fs from 'fs';
import * as fsAsync from 'fs/promises';
import * as path from 'path';
import { getTronDataDir } from '@infrastructure/settings/index.js';
import { createLogger, categorizeError, LogErrorCategory } from '@infrastructure/logging/index.js';

const logger = createLogger('canvas-store');

// =============================================================================
// Types
// =============================================================================

/**
 * Persisted canvas artifact data
 */
export interface CanvasArtifact {
  /** Unique canvas identifier */
  canvasId: string;
  /** Session that created this canvas */
  sessionId: string;
  /** Optional title for the canvas */
  title?: string;
  /** Complete UI component tree */
  ui: Record<string, unknown>;
  /** Initial state bindings */
  state?: Record<string, unknown>;
  /** ISO timestamp when saved */
  savedAt: string;
}

// =============================================================================
// Canvas Store
// =============================================================================

/**
 * Get the path to the canvas artifacts directory
 */
export function getCanvasArtifactsDir(): string {
  const tronDir = getTronDataDir();
  return path.join(tronDir, 'artifacts', 'canvases');
}

/**
 * Ensure the canvas artifacts directory exists
 */
export function ensureCanvasArtifactsDir(): void {
  const dir = getCanvasArtifactsDir();
  if (!fs.existsSync(dir)) {
    fs.mkdirSync(dir, { recursive: true });
    logger.debug('Created canvas artifacts directory', { path: dir });
  }
}

/**
 * Save a canvas artifact to disk
 */
export async function saveCanvasArtifact(artifact: CanvasArtifact): Promise<void> {
  ensureCanvasArtifactsDir();

  const filePath = path.join(getCanvasArtifactsDir(), `${artifact.canvasId}.json`);

  try {
    const content = JSON.stringify(artifact, null, 2);
    await fsAsync.writeFile(filePath, content, 'utf-8');
    logger.info('Saved canvas artifact', {
      canvasId: artifact.canvasId,
      sessionId: artifact.sessionId,
      path: filePath,
    });
  } catch (error) {
    const structured = categorizeError(error, { canvasId: artifact.canvasId, operation: 'saveCanvasArtifact' });
    logger.error('Failed to save canvas artifact', {
      canvasId: artifact.canvasId,
      code: structured.code,
      category: LogErrorCategory.DATABASE,
      error: structured.message,
      retryable: structured.retryable,
    });
    throw error;
  }
}

/**
 * Load a canvas artifact from disk
 */
export async function loadCanvasArtifact(canvasId: string): Promise<CanvasArtifact | null> {
  const filePath = path.join(getCanvasArtifactsDir(), `${canvasId}.json`);

  try {
    const content = await fsAsync.readFile(filePath, 'utf-8');
    const artifact = JSON.parse(content) as CanvasArtifact;
    logger.debug('Loaded canvas artifact', { canvasId });
    return artifact;
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === 'ENOENT') {
      logger.debug('Canvas artifact not found', { canvasId });
      return null;
    }
    const structured = categorizeError(error, { canvasId, operation: 'loadCanvasArtifact' });
    logger.error('Failed to load canvas artifact', {
      canvasId,
      code: structured.code,
      category: LogErrorCategory.DATABASE,
      error: structured.message,
      retryable: structured.retryable,
    });
    return null;
  }
}

/**
 * Check if a canvas artifact exists
 */
export function canvasArtifactExists(canvasId: string): boolean {
  const filePath = path.join(getCanvasArtifactsDir(), `${canvasId}.json`);
  return fs.existsSync(filePath);
}

/**
 * Delete a canvas artifact
 */
export async function deleteCanvasArtifact(canvasId: string): Promise<boolean> {
  const filePath = path.join(getCanvasArtifactsDir(), `${canvasId}.json`);

  try {
    await fsAsync.unlink(filePath);
    logger.debug('Deleted canvas artifact', { canvasId });
    return true;
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === 'ENOENT') {
      return false;
    }
    const structured = categorizeError(error, { canvasId, operation: 'deleteCanvasArtifact' });
    logger.error('Failed to delete canvas artifact', {
      canvasId,
      code: structured.code,
      category: LogErrorCategory.DATABASE,
      error: structured.message,
      retryable: structured.retryable,
    });
    return false;
  }
}

/**
 * List all canvas artifacts
 */
export async function listCanvasArtifacts(): Promise<string[]> {
  const dir = getCanvasArtifactsDir();

  try {
    if (!fs.existsSync(dir)) {
      return [];
    }

    const files = await fsAsync.readdir(dir);
    return files
      .filter(f => f.endsWith('.json'))
      .map(f => f.replace('.json', ''));
  } catch (error) {
    const structured = categorizeError(error, { operation: 'listCanvasArtifacts' });
    logger.error('Failed to list canvas artifacts', {
      code: structured.code,
      category: LogErrorCategory.DATABASE,
      error: structured.message,
      retryable: structured.retryable,
    });
    return [];
  }
}

/**
 * Delete canvas artifacts older than a given date
 */
export async function deleteOldCanvasArtifacts(olderThan: Date): Promise<number> {
  const dir = getCanvasArtifactsDir();

  try {
    if (!fs.existsSync(dir)) {
      return 0;
    }

    const files = await fsAsync.readdir(dir);
    let deletedCount = 0;

    for (const file of files) {
      if (!file.endsWith('.json')) continue;

      const filePath = path.join(dir, file);
      try {
        const content = await fsAsync.readFile(filePath, 'utf-8');
        const artifact = JSON.parse(content) as CanvasArtifact;
        const savedDate = new Date(artifact.savedAt);

        if (savedDate < olderThan) {
          await fsAsync.unlink(filePath);
          deletedCount++;
        }
      } catch {
        // Skip files that can't be parsed
      }
    }

    if (deletedCount > 0) {
      logger.info('Cleaned up old canvas artifacts', { deletedCount });
    }

    return deletedCount;
  } catch (error) {
    const structured = categorizeError(error, { operation: 'deleteOldCanvasArtifacts' });
    logger.error('Failed to clean up canvas artifacts', {
      code: structured.code,
      category: LogErrorCategory.DATABASE,
      error: structured.message,
      retryable: structured.retryable,
    });
    return 0;
  }
}
