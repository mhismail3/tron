/**
 * @fileoverview Canvas Adapter
 *
 * Provides the canvas manager implementation for RPC operations.
 * Loads canvas artifacts from disk storage.
 */

import { loadCanvasArtifact, type CanvasRpcManager } from '@tron/core';

/**
 * Creates a CanvasManager adapter that loads canvas artifacts from disk.
 *
 * Note: This adapter does not require orchestrator dependencies as it
 * directly accesses the disk storage via @tron/core functions.
 */
export function createCanvasAdapter(): CanvasRpcManager {
  return {
    async getCanvas(canvasId: string) {
      const artifact = await loadCanvasArtifact(canvasId);

      if (!artifact) {
        return { found: false };
      }

      return {
        found: true,
        canvas: {
          canvasId: artifact.canvasId,
          sessionId: artifact.sessionId,
          title: artifact.title,
          ui: artifact.ui,
          state: artifact.state,
          savedAt: artifact.savedAt,
        },
      };
    },
  };
}
