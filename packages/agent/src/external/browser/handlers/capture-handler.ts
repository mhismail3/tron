/**
 * @fileoverview Capture Handler
 *
 * Handles browser capture actions:
 * - screenshot: Take a screenshot of the viewport
 * - snapshot: Get accessibility snapshot with element refs
 * - pdf: Generate PDF of the page
 *
 * Extracted from BrowserService for modularity.
 */

import type { BrowserSession, ActionResult, BrowserHandlerDeps } from './types.js';

// =============================================================================
// Types
// =============================================================================

/**
 * Dependencies for CaptureHandler
 */
export interface CaptureHandlerDeps extends BrowserHandlerDeps {
  /** Viewport dimensions for screenshot metadata */
  viewport: { width: number; height: number };
}

// =============================================================================
// CaptureHandler
// =============================================================================

/**
 * Handles browser capture actions.
 */
export class CaptureHandler {
  constructor(private deps: CaptureHandlerDeps) {}

  /**
   * Take a screenshot of the viewport.
   * Always captures viewport-only to ensure consistent dimensions.
   */
  async screenshot(session: BrowserSession): Promise<ActionResult> {
    try {
      const page = session.manager.getPage();
      const screenshot = await page.screenshot({
        type: 'png',
        fullPage: false,
      });

      return {
        success: true,
        data: {
          screenshot: screenshot.toString('base64'),
          format: 'png',
          width: this.deps.viewport.width,
          height: this.deps.viewport.height,
        },
      };
    } catch (error) {
      return {
        success: false,
        error: error instanceof Error ? error.message : 'Screenshot failed',
      };
    }
  }

  /**
   * Get accessibility snapshot with element references.
   * Uses agent-browser's enhanced snapshot method.
   */
  async snapshot(session: BrowserSession): Promise<ActionResult> {
    try {
      const page = session.manager.getPage();

      // Wait for page to be ready
      await page.waitForLoadState('domcontentloaded', { timeout: 5000 }).catch(() => {});
      await page.waitForTimeout(100);

      // Use agent-browser's getSnapshot method
      const enhancedSnapshot = await session.manager.getSnapshot({
        interactive: false,
        compact: true,
      });

      // Get the ref map from agent-browser
      const refMap = session.manager.getRefMap();

      // Update session's element refs
      session.elementRefs.clear();
      for (const ref of Object.keys(refMap)) {
        session.elementRefs.set(ref, ref);
      }

      session.lastSnapshot = enhancedSnapshot;

      return {
        success: true,
        data: {
          snapshot: enhancedSnapshot,
          elementRefs: Array.from(session.elementRefs.keys()).map((ref) => ({
            ref,
            selector: ref,
          })),
        },
      };
    } catch (error) {
      return {
        success: false,
        error: error instanceof Error ? error.message : 'Snapshot failed',
      };
    }
  }

  /**
   * Generate a PDF of the current page.
   */
  async pdf(
    session: BrowserSession,
    params: Record<string, unknown>
  ): Promise<ActionResult> {
    try {
      const page = session.manager.getPage();
      const path = params.path as string | undefined;

      if (path) {
        await page.pdf({ path });
        return { success: true, data: { path } };
      } else {
        const pdfBuffer = await page.pdf();
        return { success: true, data: { pdf: pdfBuffer.toString('base64') } };
      }
    } catch (error) {
      return {
        success: false,
        error: error instanceof Error ? error.message : 'PDF generation failed',
      };
    }
  }
}

// =============================================================================
// Factory
// =============================================================================

/**
 * Create a CaptureHandler instance.
 */
export function createCaptureHandler(deps: CaptureHandlerDeps): CaptureHandler {
  return new CaptureHandler(deps);
}
