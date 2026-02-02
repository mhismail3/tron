/**
 * @fileoverview Token expiration state management
 *
 * Provides a consistent interface for calculating and checking token expiration.
 * Eliminates duplicate expiration math across oauth.ts and openai-auth.ts.
 */

/**
 * Token expiration state with methods for checking expiry
 */
export interface TokenExpirationState {
  /** Absolute timestamp (ms) when token expires (with buffer already applied) */
  readonly expiresAtMs: number;

  /** Check if token is expired */
  isExpired(): boolean;

  /** Check if token needs refresh within the given buffer (ms) */
  needsRefresh(bufferMs: number): boolean;
}

/**
 * Create a token expiration state from expires_in response
 *
 * @param expiresInSec - Token lifetime in seconds (from OAuth response)
 * @param bufferSec - Safety buffer in seconds to subtract from expiry
 * @returns TokenExpirationState for checking expiration
 *
 * @example
 * ```typescript
 * // From OAuth token exchange response
 * const expiration = createTokenExpiration(data.expires_in, 300); // 5 min buffer
 *
 * // Check if expired
 * if (expiration.isExpired()) {
 *   await refreshToken();
 * }
 *
 * // Check with additional buffer
 * if (expiration.needsRefresh(60000)) { // 1 min additional buffer
 *   scheduleRefresh();
 * }
 * ```
 */
export function createTokenExpiration(
  expiresInSec: number,
  bufferSec: number
): TokenExpirationState {
  const expiresAtMs = Date.now() + (expiresInSec - bufferSec) * 1000;

  return {
    expiresAtMs,
    isExpired: () => Date.now() >= expiresAtMs,
    needsRefresh: (bufferMs) => Date.now() >= expiresAtMs - bufferMs,
  };
}
