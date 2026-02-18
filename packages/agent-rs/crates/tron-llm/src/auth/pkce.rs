//! PKCE (Proof Key for Code Exchange) generation.
//!
//! Used by all OAuth providers for secure authorization code flows.

use base64::Engine;
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use sha2::{Digest, Sha256};

/// A PKCE verifier/challenge pair.
#[derive(Clone, Debug)]
pub struct PkcePair {
    /// Random verifier string (base64url, no padding).
    pub verifier: String,
    /// SHA-256 challenge of the verifier (base64url, no padding).
    pub challenge: String,
}

/// Generate a new PKCE verifier/challenge pair.
///
/// The verifier is 32 cryptographically-secure random bytes encoded as
/// base64url (no padding). The challenge is the SHA-256 hash of the
/// verifier, also base64url-encoded.
pub fn generate_pkce() -> PkcePair {
    let random_bytes: [u8; 32] = rand::random();
    let verifier = URL_SAFE_NO_PAD.encode(random_bytes);

    let mut hasher = Sha256::new();
    hasher.update(verifier.as_bytes());
    let hash = hasher.finalize();
    let challenge = URL_SAFE_NO_PAD.encode(hash);

    PkcePair {
        verifier,
        challenge,
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn generate_produces_valid_pair() {
        let pair = generate_pkce();
        assert!(!pair.verifier.is_empty());
        assert!(!pair.challenge.is_empty());
    }

    #[test]
    fn verifier_is_base64url_no_padding() {
        let pair = generate_pkce();
        assert!(
            !pair.verifier.contains('+'),
            "verifier must not contain '+'",
        );
        assert!(
            !pair.verifier.contains('/'),
            "verifier must not contain '/'",
        );
        assert!(
            !pair.verifier.contains('='),
            "verifier must not contain '='",
        );
    }

    #[test]
    fn challenge_is_base64url_no_padding() {
        let pair = generate_pkce();
        assert!(
            !pair.challenge.contains('+'),
            "challenge must not contain '+'",
        );
        assert!(
            !pair.challenge.contains('/'),
            "challenge must not contain '/'",
        );
        assert!(
            !pair.challenge.contains('='),
            "challenge must not contain '='",
        );
    }

    #[test]
    fn challenge_matches_verifier_hash() {
        let pair = generate_pkce();
        let mut hasher = Sha256::new();
        hasher.update(pair.verifier.as_bytes());
        let hash = hasher.finalize();
        let expected = URL_SAFE_NO_PAD.encode(hash);
        assert_eq!(pair.challenge, expected);
    }

    #[test]
    fn each_call_produces_unique_pair() {
        let a = generate_pkce();
        let b = generate_pkce();
        assert_ne!(a.verifier, b.verifier);
        assert_ne!(a.challenge, b.challenge);
    }

    #[test]
    fn verifier_length_is_correct() {
        let pair = generate_pkce();
        // 32 bytes in base64url = ceil(32 * 4/3) = 43 characters (no padding)
        assert_eq!(pair.verifier.len(), 43);
    }

    #[test]
    fn challenge_length_is_correct() {
        let pair = generate_pkce();
        // SHA-256 = 32 bytes → 43 base64url characters
        assert_eq!(pair.challenge.len(), 43);
    }
}
