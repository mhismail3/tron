//! Element reference normalization for agent-browser.

use std::sync::LazyLock;

use regex::Regex;

static ELEMENT_REF: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"^e\d+$").expect("element ref regex"));

/// Normalize a selector for agent-browser.
///
/// Bare element refs (`e1`, `e42`) get prefixed with `@`.
/// CSS selectors (`#btn`, `.class`, `div > span`) pass through unchanged.
/// Already-prefixed refs (`@e1`) pass through unchanged.
pub fn normalize_selector(selector: &str) -> String {
    let trimmed = selector.trim();
    if ELEMENT_REF.is_match(trimmed) {
        format!("@{trimmed}")
    } else {
        trimmed.to_string()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // --- Bare element refs should be prefixed ---
    #[test]
    fn normalize_e1() {
        assert_eq!(normalize_selector("e1"), "@e1");
    }
    #[test]
    fn normalize_e0() {
        assert_eq!(normalize_selector("e0"), "@e0");
    }
    #[test]
    fn normalize_e42() {
        assert_eq!(normalize_selector("e42"), "@e42");
    }
    #[test]
    fn normalize_e999() {
        assert_eq!(normalize_selector("e999"), "@e999");
    }
    #[test]
    fn normalize_e12345() {
        assert_eq!(normalize_selector("e12345"), "@e12345");
    }

    // --- Already-prefixed refs should pass through ---
    #[test]
    fn normalize_at_e1() {
        assert_eq!(normalize_selector("@e1"), "@e1");
    }
    #[test]
    fn normalize_at_e42() {
        assert_eq!(normalize_selector("@e42"), "@e42");
    }

    // --- CSS selectors should pass through ---
    #[test]
    fn normalize_id_selector() {
        assert_eq!(normalize_selector("#btn"), "#btn");
    }
    #[test]
    fn normalize_class_selector() {
        assert_eq!(normalize_selector(".class"), ".class");
    }
    #[test]
    fn normalize_compound() {
        assert_eq!(normalize_selector("button.submit"), "button.submit");
    }
    #[test]
    fn normalize_attribute() {
        assert_eq!(normalize_selector("[data-id]"), "[data-id]");
    }
    #[test]
    fn normalize_combinator() {
        assert_eq!(normalize_selector("div > span"), "div > span");
    }
    #[test]
    fn normalize_pseudo() {
        assert_eq!(normalize_selector("a:hover"), "a:hover");
    }
    #[test]
    fn normalize_nth_child() {
        assert_eq!(normalize_selector("li:nth-child(2)"), "li:nth-child(2)");
    }

    // --- Similar-looking strings that are NOT element refs ---
    #[test]
    fn normalize_element_word() {
        assert_eq!(normalize_selector("element"), "element");
    }
    #[test]
    fn normalize_email() {
        assert_eq!(normalize_selector("email"), "email");
    }
    #[test]
    fn normalize_bare_e() {
        assert_eq!(normalize_selector("e"), "e");
    }
    #[test]
    fn normalize_uppercase_e1() {
        assert_eq!(normalize_selector("E1"), "E1");
    }
    #[test]
    fn normalize_e1_with_suffix() {
        assert_eq!(normalize_selector("e1-btn"), "e1-btn");
    }
    #[test]
    fn normalize_prefix_e1() {
        assert_eq!(normalize_selector("ae1"), "ae1");
    }

    // --- Whitespace handling ---
    #[test]
    fn normalize_whitespace_trimmed() {
        assert_eq!(normalize_selector("  e1  "), "@e1");
    }
    #[test]
    fn normalize_tab_trimmed() {
        assert_eq!(normalize_selector("\te1\t"), "@e1");
    }
    #[test]
    fn normalize_css_whitespace() {
        assert_eq!(normalize_selector("  #btn  "), "#btn");
    }

    // --- Edge cases ---
    #[test]
    fn normalize_empty() {
        assert_eq!(normalize_selector(""), "");
    }
    #[test]
    fn normalize_whitespace_only() {
        assert_eq!(normalize_selector("   "), "");
    }
}
