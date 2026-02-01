/**
 * @fileoverview Device domain - Device registration
 *
 * Handles device registration and unregistration for push notifications.
 *
 * @migration Re-exports from rpc/handlers during transition
 */

// Re-export handlers
export {
  handleDeviceRegister,
  handleDeviceUnregister,
  getDeviceHandlers,
} from '../../../../rpc/handlers/device.handler.js';

// Note: Device types are not in a separate type file
// They are defined inline in the handler
