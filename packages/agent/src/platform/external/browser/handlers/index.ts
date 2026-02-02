/**
 * @fileoverview Browser Handlers
 *
 * Modular handlers for browser actions, extracted from BrowserService.
 *
 * Handler Groups:
 * - NavigationHandler: navigate, goBack, goForward, reload
 * - InputHandler: click, fill, type, select, hover, pressKey
 * - CaptureHandler: screenshot, snapshot, pdf
 * - QueryHandler: getText, getAttribute
 * - StateHandler: wait, scroll
 */

export * from './types.js';
export * from './navigation-handler.js';
export * from './input-handler.js';
export * from './capture-handler.js';
export * from './query-handler.js';
export * from './state-handler.js';
