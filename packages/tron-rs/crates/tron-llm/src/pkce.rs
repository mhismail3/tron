//! PKCE (Proof Key for Code Exchange) utilities.
//!
//! Shared PKCE generation for all OAuth providers.
//! Implements S256 code challenge method per RFC 7636.

use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use base64::Engine;
use rand::RngCore;
use sha2::{Digest, Sha256};

/// PKCE verifier/challenge pair.
#[derive(Debug, Clone)]
pub struct PkcePair {
    /// The code verifier (random base64url string, 43 chars).
    pub verifier: String,
    /// The S256 code challenge (SHA-256 of verifier, base64url encoded).
    pub challenge: String,
}

/// Generate a cryptographically secure PKCE verifier and S256 challenge.
///
/// The verifier is 32 random bytes, base64url-encoded (no padding).
/// The challenge is SHA-256(verifier), base64url-encoded (no padding).
pub fn generate_pkce() -> PkcePair {
    let mut bytes = [0u8; 32];
    rand::thread_rng().fill_bytes(&mut bytes);
    let verifier = URL_SAFE_NO_PAD.encode(bytes);

    let hash = Sha256::digest(verifier.as_bytes());
    let challenge = URL_SAFE_NO_PAD.encode(hash);

    PkcePair {
        verifier,
        challenge,
    }
}

/// Build the authorization URL for Anthropic OAuth with PKCE.
///
/// Returns the full URL to open in the user's browser.
pub fn build_auth_url(challenge: &str) -> String {
    use tron_core::security::ANTHROPIC_OAUTH;

    let scopes = ANTHROPIC_OAUTH.scopes.join(" ");

    format!(
        "{}?code=true&client_id={}&redirect_uri={}&response_type=code&scope={}&code_challenge={}&code_challenge_method=S256&state={}",
        ANTHROPIC_OAUTH.auth_url,
        ANTHROPIC_OAUTH.client_id,
        urlencoded(ANTHROPIC_OAUTH.redirect_uri),
        urlencoded(&scopes),
        challenge,
        challenge, // Use challenge as state for verification
    )
}

/// Exchange an authorization code for tokens using the PKCE verifier.
pub async fn exchange_code(
    code: &str,
    verifier: &str,
    state: Option<&str>,
) -> Result<super::auth::TokenResponse, super::auth::AuthError> {
    use tron_core::security::ANTHROPIC_OAUTH;

    let client = reqwest::Client::new();

    let mut form = vec![
        ("grant_type", "authorization_code"),
        ("client_id", ANTHROPIC_OAUTH.client_id),
        ("code", code),
        ("redirect_uri", ANTHROPIC_OAUTH.redirect_uri),
        ("code_verifier", verifier),
    ];

    // State is optional but used with Anthropic's callback page
    let state_owned;
    if let Some(s) = state {
        state_owned = s.to_string();
        form.push(("state", &state_owned));
    }

    let resp = client
        .post(ANTHROPIC_OAUTH.token_url)
        .form(&form)
        .send()
        .await
        .map_err(|e| super::auth::AuthError::NetworkError(e.to_string()))?;

    if !resp.status().is_success() {
        let body = resp.text().await.unwrap_or_default();
        return Err(super::auth::AuthError::RefreshFailed(body));
    }

    resp.json()
        .await
        .map_err(|e| super::auth::AuthError::ParseError(e.to_string()))
}

/// Minimal percent-encoding for URL query parameters.
fn urlencoded(s: &str) -> String {
    s.replace(' ', "%20")
        .replace(':', "%3A")
        .replace('/', "%2F")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn generate_pkce_pair() {
        let pair = generate_pkce();

        // Verifier should be 43 chars (32 bytes → base64url no padding)
        assert_eq!(pair.verifier.len(), 43);

        // Challenge should be 43 chars (32 bytes SHA-256 → base64url no padding)
        assert_eq!(pair.challenge.len(), 43);

        // Verifier and challenge must be different
        assert_ne!(pair.verifier, pair.challenge);
    }

    #[test]
    fn pkce_is_deterministic_for_same_verifier() {
        // Given a known verifier, the challenge is deterministic
        let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk";
        let hash = Sha256::digest(verifier.as_bytes());
        let challenge = URL_SAFE_NO_PAD.encode(hash);

        // Re-hash should produce the same result
        let hash2 = Sha256::digest(verifier.as_bytes());
        let challenge2 = URL_SAFE_NO_PAD.encode(hash2);
        assert_eq!(challenge, challenge2);
    }

    #[test]
    fn each_pkce_pair_is_unique() {
        let pair1 = generate_pkce();
        let pair2 = generate_pkce();
        assert_ne!(pair1.verifier, pair2.verifier);
        assert_ne!(pair1.challenge, pair2.challenge);
    }

    #[test]
    fn challenge_is_sha256_of_verifier() {
        let pair = generate_pkce();

        // Manually compute the challenge
        let hash = Sha256::digest(pair.verifier.as_bytes());
        let expected_challenge = URL_SAFE_NO_PAD.encode(hash);

        assert_eq!(pair.challenge, expected_challenge);
    }

    #[test]
    fn build_auth_url_contains_required_params() {
        let pair = generate_pkce();
        let url = build_auth_url(&pair.challenge);

        assert!(url.starts_with("https://claude.ai/oauth/authorize?"));
        assert!(url.contains("code_challenge_method=S256"));
        assert!(url.contains(&format!("code_challenge={}", pair.challenge)));
        assert!(url.contains("client_id=9d1c250a-e61b-44d9-88ed-5944d1962f5e"));
        assert!(url.contains("response_type=code"));
        assert!(url.contains("code=true"));
        // State should equal challenge
        assert!(url.contains(&format!("state={}", pair.challenge)));
    }

    #[test]
    fn urlencoded_basic() {
        assert_eq!(urlencoded("hello world"), "hello%20world");
        assert_eq!(urlencoded("https://example.com"), "https%3A%2F%2Fexample.com");
    }
}
