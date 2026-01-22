/**
 * @fileoverview Artifacts Module
 *
 * Provides persistence for various artifacts (canvases, etc.)
 */

export {
  type CanvasArtifact,
  getCanvasArtifactsDir,
  ensureCanvasArtifactsDir,
  saveCanvasArtifact,
  loadCanvasArtifact,
  canvasArtifactExists,
  deleteCanvasArtifact,
  listCanvasArtifacts,
  deleteOldCanvasArtifacts,
} from './canvas-store.js';
