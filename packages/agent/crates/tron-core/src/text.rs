//! UTF-8–safe string truncation utilities.
//!
//! Rust `&str[..n]` panics when `n` falls inside a multi-byte character.
//! These helpers find the nearest char boundary so truncation is always safe.

/// Truncate a string to at most `max_bytes` bytes at a char boundary.
///
/// Returns the longest prefix of `s` whose byte length is ≤ `max_bytes`
/// and that does not split a multi-byte character.
///
/// # Examples
///
/// ```
/// use tron_core::text::truncate_str;
///
/// assert_eq!(truncate_str("hello", 3), "hel");
/// // Em dash '—' (3 bytes) at boundary snaps back:
/// assert_eq!(truncate_str("ab—cd", 3), "ab");
/// assert_eq!(truncate_str("ab—cd", 5), "ab—");
/// ```
#[inline]
pub fn truncate_str(s: &str, max_bytes: usize) -> &str {
    if s.len() <= max_bytes {
        return s;
    }
    // `floor_char_boundary` is nightly-only, so implement it ourselves.
    let mut end = max_bytes;
    // Walk backward to find a char boundary.
    while end > 0 && !s.is_char_boundary(end) {
        end -= 1;
    }
    &s[..end]
}

/// Truncate `s` and append a suffix (e.g. `"..."`) if the original exceeds `max_bytes`.
///
/// The returned string is at most `max_bytes` bytes long (including the suffix).
/// If the string fits, it is returned as-is with no allocation.
///
/// # Examples
///
/// ```
/// use tron_core::text::truncate_with_suffix;
///
/// assert_eq!(truncate_with_suffix("hello", 10, "..."), "hello".to_string());
/// assert_eq!(truncate_with_suffix("hello world", 8, "..."), "hello...");
/// ```
pub fn truncate_with_suffix(s: &str, max_bytes: usize, suffix: &str) -> String {
    if s.len() <= max_bytes {
        return s.to_owned();
    }
    let body_budget = max_bytes.saturating_sub(suffix.len());
    let prefix = truncate_str(s, body_budget);
    format!("{prefix}{suffix}")
}

/// Extract the first sentence from a description.
///
/// Returns everything up to and including the first `.` that is followed
/// by a space, newline, or end-of-string. Falls back to the first line
/// (up to `\n`), then to the full string.
pub fn first_sentence(s: &str) -> &str {
    for (i, _) in s.match_indices('.') {
        // Skip periods that are part of an ellipsis ("..." — preceded by '.')
        if i > 0 && s.as_bytes()[i - 1] == b'.' {
            continue;
        }
        let after = i + 1;
        if after >= s.len() {
            return &s[..after]; // period at end of string
        }
        let next = s.as_bytes()[after];
        if next == b' ' || next == b'\n' {
            return &s[..after];
        }
    }
    // No sentence boundary found — return first line
    s.split('\n').next().unwrap_or(s)
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    // ── truncate_str ─────────────────────────────────────────────────────

    #[test]
    fn ascii_within_limit() {
        assert_eq!(truncate_str("hello", 10), "hello");
    }

    #[test]
    fn ascii_exact_limit() {
        assert_eq!(truncate_str("hello", 5), "hello");
    }

    #[test]
    fn ascii_truncated() {
        assert_eq!(truncate_str("hello world", 5), "hello");
    }

    #[test]
    fn empty_string() {
        assert_eq!(truncate_str("", 5), "");
    }

    #[test]
    fn zero_max() {
        assert_eq!(truncate_str("hello", 0), "");
    }

    #[test]
    fn em_dash_boundary_inside() {
        // '—' (U+2014) is 3 bytes: 0xE2 0x80 0x94, at bytes 2..5
        let s = "ab—cd"; // bytes: a(0) b(1) —(2,3,4) c(5) d(6)
        // Cutting at byte 3 lands inside '—', must snap back to byte 2
        assert_eq!(truncate_str(s, 3), "ab");
        assert_eq!(truncate_str(s, 4), "ab");
    }

    #[test]
    fn em_dash_boundary_exact() {
        let s = "ab—cd";
        // byte 5 is exactly after '—'
        assert_eq!(truncate_str(s, 5), "ab—");
    }

    #[test]
    fn emoji_4_byte() {
        // '🦀' (U+1F980) is 4 bytes
        let s = "hi🦀bye";
        // 'h'(0) 'i'(1) 🦀(2,3,4,5) 'b'(6) 'y'(7) 'e'(8)
        assert_eq!(truncate_str(s, 2), "hi");
        assert_eq!(truncate_str(s, 3), "hi"); // inside emoji
        assert_eq!(truncate_str(s, 5), "hi"); // still inside emoji
        assert_eq!(truncate_str(s, 6), "hi🦀");
    }

    #[test]
    fn two_byte_char() {
        // 'é' (U+00E9) is 2 bytes: 0xC3 0xA9
        let s = "café";
        // c(0) a(1) f(2) é(3,4)
        assert_eq!(truncate_str(s, 3), "caf");
        assert_eq!(truncate_str(s, 4), "caf"); // inside 'é'
        assert_eq!(truncate_str(s, 5), "café");
    }

    #[test]
    fn all_multibyte() {
        let s = "———"; // 9 bytes total
        assert_eq!(truncate_str(s, 0), "");
        assert_eq!(truncate_str(s, 1), "");
        assert_eq!(truncate_str(s, 2), "");
        assert_eq!(truncate_str(s, 3), "—");
        assert_eq!(truncate_str(s, 5), "—");
        assert_eq!(truncate_str(s, 6), "——");
        assert_eq!(truncate_str(s, 9), "———");
    }

    // ── truncate_with_suffix ─────────────────────────────────────────────

    #[test]
    fn suffix_fits() {
        assert_eq!(truncate_with_suffix("hello", 10, "..."), "hello");
    }

    #[test]
    fn suffix_truncates_ascii() {
        assert_eq!(truncate_with_suffix("hello world", 8, "..."), "hello...");
    }

    #[test]
    fn suffix_truncates_at_multibyte_boundary() {
        // "databases—quiet" → truncate with "..." at byte ~12
        // 'databases' = 9 bytes, '—' = bytes 9..12
        let s = "databases—quiet work";
        // max_bytes=15, suffix="..." → body_budget=12
        // byte 12 is right after '—', so we get "databases—..."
        let result = truncate_with_suffix(s, 15, "...");
        assert_eq!(result, "databases—...");
    }

    #[test]
    fn suffix_truncates_inside_multibyte() {
        let s = "databases—quiet work";
        // max_bytes=14, suffix="..." → body_budget=11
        // byte 11 is inside '—' (bytes 9..12), snaps to 9
        let result = truncate_with_suffix(s, 14, "...");
        assert_eq!(result, "databases...");
    }

    #[test]
    fn suffix_very_short_max() {
        // max_bytes=2, suffix="..." → body_budget=0
        assert_eq!(truncate_with_suffix("hello", 2, "..."), "...");
    }

    #[test]
    fn suffix_exact_fit() {
        assert_eq!(truncate_with_suffix("abc", 3, "..."), "abc");
    }

    #[test]
    fn suffix_one_over() {
        // "abcd" is 4 bytes, max=3, suffix="." → body_budget=2
        assert_eq!(truncate_with_suffix("abcd", 3, "."), "ab.");
    }

    // ── first_sentence ────────────────────────────────────────────────────

    #[test]
    fn first_sentence_normal() {
        assert_eq!(first_sentence("Execute a command. More details here."), "Execute a command.");
    }

    #[test]
    fn first_sentence_period_at_end() {
        assert_eq!(first_sentence("Execute a command."), "Execute a command.");
    }

    #[test]
    fn first_sentence_newline_after_period() {
        assert_eq!(first_sentence("Search the web.\n\nMore info."), "Search the web.");
    }

    #[test]
    fn first_sentence_no_period() {
        assert_eq!(first_sentence("No period here"), "No period here");
    }

    #[test]
    fn first_sentence_no_period_multiline() {
        assert_eq!(first_sentence("First line\nSecond line"), "First line");
    }

    #[test]
    fn first_sentence_empty() {
        assert_eq!(first_sentence(""), "");
    }

    #[test]
    fn first_sentence_url_dots() {
        assert_eq!(
            first_sentence("Fetch from api.example.com for data. More info."),
            "Fetch from api.example.com for data."
        );
    }

    #[test]
    fn first_sentence_abbreviation_mid_word() {
        assert_eq!(first_sentence("Uses v2.0 protocol. Details."), "Uses v2.0 protocol.");
    }

    #[test]
    fn first_sentence_ellipsis() {
        assert_eq!(first_sentence("Wait... then proceed. Done."), "Wait... then proceed.");
    }

    #[test]
    fn first_sentence_multibyte() {
        assert_eq!(first_sentence("Héllo wörld. More."), "Héllo wörld.");
    }
}
