/**
 * @fileoverview RPC Module Exports
 *
 * Re-exports RPC client and event mapping utilities.
 */

export { RpcClient, type RpcClientOptions, type RequestOptions } from './client.js';
export {
  mapEventToActions,
  createEventDispatcher,
  finalizeStreamingMessage,
} from './event-mapper.js';
