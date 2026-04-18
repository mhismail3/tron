//! Text normalization and hashing for prompt-history dedup.

use sha2::{Digest, Sha256};
use unicode_normalization::UnicodeNormalization;

/// Normalize a prompt string for hashing.
///
/// Steps (in order):
/// 1. Trim leading/trailing ASCII whitespace.
/// 2. Normalize line endings CRLF/CR → LF.
/// 3. Apply Unicode NFC normalization.
///
/// Case is preserved: `"Hello"` and `"hello"` hash to different values.
pub fn normalize_for_hash(input: &str) -> String {
    let trimmed = input.trim();
    // CRLF and lone CR → LF
    let lf = trimmed.replace("\r\n", "\n").replace('\r', "\n");
    // NFC
    lf.nfc().collect()
}

/// Return the lowercase hex SHA-256 of the input bytes.
pub fn hash_hex(bytes: &[u8]) -> String {
    let mut hasher = Sha256::new();
    hasher.update(bytes);
    let digest = hasher.finalize();
    hex_lower(&digest)
}

fn hex_lower(bytes: &[u8]) -> String {
    const HEX: &[u8; 16] = b"0123456789abcdef";
    let mut out = String::with_capacity(bytes.len() * 2);
    for b in bytes {
        out.push(HEX[(b >> 4) as usize] as char);
        out.push(HEX[(b & 0x0f) as usize] as char);
    }
    out
}

/// Return `true` if the prompt is empty after trimming whitespace.
pub fn is_blank(input: &str) -> bool {
    input.trim().is_empty()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn trims_whitespace() {
        assert_eq!(normalize_for_hash("  hello  "), "hello");
        assert_eq!(normalize_for_hash("\n\thello\n\n"), "hello");
    }

    #[test]
    fn normalizes_crlf_to_lf() {
        assert_eq!(normalize_for_hash("a\r\nb"), "a\nb");
        assert_eq!(normalize_for_hash("a\rb"), "a\nb");
    }

    #[test]
    fn nfc_collapses_composed_and_decomposed() {
        // "café" in NFC (precomposed é) vs NFD (e + combining acute).
        let nfc = "caf\u{00e9}";
        let nfd = "cafe\u{0301}";
        assert_eq!(normalize_for_hash(nfc), normalize_for_hash(nfd));
    }

    #[test]
    fn case_sensitive_dedup() {
        let a = hash_hex(normalize_for_hash("Hello").as_bytes());
        let b = hash_hex(normalize_for_hash("hello").as_bytes());
        assert_ne!(a, b);
    }

    #[test]
    fn deterministic_hash() {
        let a = hash_hex(b"hello");
        let b = hash_hex(b"hello");
        assert_eq!(a, b);
        assert_eq!(a.len(), 64);
    }

    #[test]
    fn is_blank_cases() {
        assert!(is_blank(""));
        assert!(is_blank("   "));
        assert!(is_blank("\n\t\r "));
        assert!(!is_blank("a"));
        assert!(!is_blank("  a  "));
    }
}
