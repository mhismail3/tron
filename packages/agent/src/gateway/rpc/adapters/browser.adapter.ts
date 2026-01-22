/**
 * @fileoverview Browser Adapter
 *
 * Adapts EventStoreOrchestrator browser methods to the BrowserRpcManager
 * interface expected by RpcContext.
 */

import type { AdapterDependencies, BrowserManagerAdapter } from '../types.js';

/**
 * Creates a BrowserManager adapter from EventStoreOrchestrator
 */
export function createBrowserAdapter(deps: AdapterDependencies): BrowserManagerAdapter {
  const { orchestrator } = deps;

  return {
    async startStream(params) {
      return orchestrator.startBrowserStream(params.sessionId);
    },
    async stopStream(params) {
      return orchestrator.stopBrowserStream(params.sessionId);
    },
    async getStatus(params) {
      return orchestrator.getBrowserStatus(params.sessionId);
    },
  };
}
