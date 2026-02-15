use std::path::Path;

use chacha20poly1305::aead::{Aead, KeyInit, OsRng};
use chacha20poly1305::{ChaCha20Poly1305, Nonce};

const NONCE_LEN: usize = 12;

/// Encrypt a plaintext string using ChaCha20-Poly1305 AEAD.
/// Returns base64-encoded nonce + ciphertext.
pub fn encrypt(plaintext: &str, key: &[u8; 32]) -> Result<String, SecretError> {
    let cipher = ChaCha20Poly1305::new(key.into());
    let mut nonce_bytes = [0u8; NONCE_LEN];
    chacha20poly1305::aead::rand_core::RngCore::fill_bytes(&mut OsRng, &mut nonce_bytes);
    let nonce = Nonce::from_slice(&nonce_bytes);

    let ciphertext = cipher
        .encrypt(nonce, plaintext.as_bytes())
        .map_err(|_| SecretError::EncryptionFailed)?;

    let mut combined = Vec::with_capacity(NONCE_LEN + ciphertext.len());
    combined.extend_from_slice(&nonce_bytes);
    combined.extend_from_slice(&ciphertext);

    Ok(base64::Engine::encode(
        &base64::engine::general_purpose::STANDARD,
        &combined,
    ))
}

/// Decrypt a base64-encoded nonce + ciphertext.
pub fn decrypt(encoded: &str, key: &[u8; 32]) -> Result<String, SecretError> {
    let combined = base64::Engine::decode(
        &base64::engine::general_purpose::STANDARD,
        encoded,
    )
    .map_err(|_| SecretError::InvalidEncoding)?;

    if combined.len() < NONCE_LEN {
        return Err(SecretError::InvalidEncoding);
    }

    let (nonce_bytes, ciphertext) = combined.split_at(NONCE_LEN);
    let nonce = Nonce::from_slice(nonce_bytes);
    let cipher = ChaCha20Poly1305::new(key.into());

    let plaintext = cipher
        .decrypt(nonce, ciphertext)
        .map_err(|_| SecretError::DecryptionFailed)?;

    String::from_utf8(plaintext).map_err(|_| SecretError::InvalidUtf8)
}

/// Generate a random 256-bit key.
pub fn generate_key() -> [u8; 32] {
    let mut key = [0u8; 32];
    chacha20poly1305::aead::rand_core::RngCore::fill_bytes(&mut OsRng, &mut key);
    key
}

/// Load or create the secret key file.
pub fn load_or_create_key(path: &Path) -> Result<[u8; 32], SecretError> {
    if path.exists() {
        let encoded = std::fs::read_to_string(path)
            .map_err(|e| SecretError::IoError(e.to_string()))?;
        let bytes = base64::Engine::decode(
            &base64::engine::general_purpose::STANDARD,
            encoded.trim(),
        )
        .map_err(|_| SecretError::InvalidEncoding)?;
        if bytes.len() != 32 {
            return Err(SecretError::InvalidKeyLength);
        }
        let mut key = [0u8; 32];
        key.copy_from_slice(&bytes);
        Ok(key)
    } else {
        let key = generate_key();
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent)
                .map_err(|e| SecretError::IoError(e.to_string()))?;
        }
        let encoded = base64::Engine::encode(
            &base64::engine::general_purpose::STANDARD,
            key,
        );
        std::fs::write(path, &encoded)
            .map_err(|e| SecretError::IoError(e.to_string()))?;

        // Set file permissions to 0600 on Unix
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600))
                .map_err(|e| SecretError::IoError(e.to_string()))?;
        }

        Ok(key)
    }
}

/// Constant-time comparison for auth validation.
pub fn constant_time_eq(a: &[u8], b: &[u8]) -> bool {
    if a.len() != b.len() {
        return false;
    }
    let mut result: u8 = 0;
    for (x, y) in a.iter().zip(b.iter()) {
        result |= x ^ y;
    }
    result == 0
}

#[derive(Debug, thiserror::Error)]
pub enum SecretError {
    #[error("encryption failed")]
    EncryptionFailed,
    #[error("decryption failed")]
    DecryptionFailed,
    #[error("invalid encoding")]
    InvalidEncoding,
    #[error("invalid UTF-8")]
    InvalidUtf8,
    #[error("invalid key length")]
    InvalidKeyLength,
    #[error("IO error: {0}")]
    IoError(String),
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn encrypt_decrypt_roundtrip() {
        let key = generate_key();
        let plaintext = "sk-ant-api-secret-12345";
        let encrypted = encrypt(plaintext, &key).unwrap();
        let decrypted = decrypt(&encrypted, &key).unwrap();
        assert_eq!(decrypted, plaintext);
    }

    #[test]
    fn different_nonces_different_ciphertext() {
        let key = generate_key();
        let plaintext = "same-input";
        let a = encrypt(plaintext, &key).unwrap();
        let b = encrypt(plaintext, &key).unwrap();
        assert_ne!(a, b); // Random nonces → different output
        // But both decrypt to the same thing
        assert_eq!(decrypt(&a, &key).unwrap(), plaintext);
        assert_eq!(decrypt(&b, &key).unwrap(), plaintext);
    }

    #[test]
    fn wrong_key_fails() {
        let key1 = generate_key();
        let key2 = generate_key();
        let encrypted = encrypt("secret", &key1).unwrap();
        assert!(decrypt(&encrypted, &key2).is_err());
    }

    #[test]
    fn tampered_ciphertext_fails() {
        let key = generate_key();
        let encrypted = encrypt("secret", &key).unwrap();
        let mut bytes = base64::Engine::decode(
            &base64::engine::general_purpose::STANDARD,
            &encrypted,
        )
        .unwrap();
        // Flip a bit
        if let Some(b) = bytes.last_mut() {
            *b ^= 0x01;
        }
        let tampered = base64::Engine::encode(
            &base64::engine::general_purpose::STANDARD,
            &bytes,
        );
        assert!(decrypt(&tampered, &key).is_err());
    }

    #[test]
    fn constant_time_eq_works() {
        assert!(constant_time_eq(b"hello", b"hello"));
        assert!(!constant_time_eq(b"hello", b"world"));
        assert!(!constant_time_eq(b"hello", b"hell"));
    }

    #[test]
    fn load_or_create_key_creates_new() {
        let dir = std::env::temp_dir().join(format!("tron-test-keys-{}", uuid::Uuid::now_v7()));
        let path = dir.join("secret_key");
        assert!(!path.exists());

        let key = load_or_create_key(&path).unwrap();
        assert!(path.exists());

        // Loading again gives the same key
        let key2 = load_or_create_key(&path).unwrap();
        assert_eq!(key, key2);
    }

    #[test]
    fn empty_plaintext() {
        let key = generate_key();
        let encrypted = encrypt("", &key).unwrap();
        let decrypted = decrypt(&encrypted, &key).unwrap();
        assert_eq!(decrypted, "");
    }

    #[test]
    fn large_plaintext() {
        let key = generate_key();
        let plaintext = "x".repeat(100_000);
        let encrypted = encrypt(&plaintext, &key).unwrap();
        let decrypted = decrypt(&encrypted, &key).unwrap();
        assert_eq!(decrypted, plaintext);
    }
}
