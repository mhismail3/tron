/**
 * @fileoverview PKCE (Proof Key for Code Exchange) utilities
 *
 * Shared PKCE generation for all OAuth providers.
 */

import crypto from 'crypto';

/**
 * PKCE challenge/verifier pair
 */
export interface PKCEPair {
  verifier: string;
  challenge: string;
}

/**
 * Generate a cryptographically secure PKCE verifier and challenge
 *
 * The verifier is a random string, and the challenge is its SHA256 hash
 * encoded as base64url (no padding).
 */
export function generatePKCE(): PKCEPair {
  // Generate 32 bytes of random data for the verifier
  const randomBytes = crypto.randomBytes(32);
  const verifier = randomBytes.toString('base64url');

  // Create SHA256 hash of verifier
  const hash = crypto.createHash('sha256').update(verifier).digest();
  const challenge = hash.toString('base64url');

  return { verifier, challenge };
}
