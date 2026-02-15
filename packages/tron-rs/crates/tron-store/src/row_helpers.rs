use crate::error::StoreError;

/// Get a required column value from a row, returning CorruptRow on failure.
pub fn get<T: rusqlite::types::FromSql>(
    row: &rusqlite::Row<'_>,
    idx: usize,
    table: &'static str,
    column: &'static str,
) -> Result<T, StoreError> {
    row.get(idx).map_err(|e| StoreError::CorruptRow {
        table,
        column,
        detail: e.to_string(),
    })
}

/// Get an optional column value.
pub fn get_opt<T: rusqlite::types::FromSql>(
    row: &rusqlite::Row<'_>,
    idx: usize,
    table: &'static str,
    column: &'static str,
) -> Result<Option<T>, StoreError> {
    row.get(idx).map_err(|e| StoreError::CorruptRow {
        table,
        column,
        detail: e.to_string(),
    })
}

/// Parse a JSON string column, returning CorruptRow on parse failure.
pub fn parse_json(
    raw: &str,
    table: &'static str,
    column: &'static str,
) -> Result<serde_json::Value, StoreError> {
    serde_json::from_str(raw).map_err(|e| StoreError::CorruptRow {
        table,
        column,
        detail: format!("invalid JSON: {e}"),
    })
}

/// Parse a string into an enum, returning CorruptRow on failure.
pub fn parse_enum<T: std::str::FromStr>(
    raw: &str,
    table: &'static str,
    column: &'static str,
) -> Result<T, StoreError> {
    raw.parse().map_err(|_| StoreError::CorruptRow {
        table,
        column,
        detail: format!("unknown variant: {raw}"),
    })
}

/// Escape LIKE special characters for safe pattern matching.
pub fn escape_like(s: &str) -> String {
    s.replace('\\', "\\\\")
        .replace('%', "\\%")
        .replace('_', "\\_")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn escape_like_special_chars() {
        assert_eq!(escape_like("hello"), "hello");
        assert_eq!(escape_like("100%"), "100\\%");
        assert_eq!(escape_like("foo_bar"), "foo\\_bar");
        assert_eq!(escape_like("back\\slash"), "back\\\\slash");
        assert_eq!(escape_like("%_\\"), "\\%\\_\\\\");
    }

    #[test]
    fn parse_enum_success() {
        let result: Result<super::super::sessions::SessionStatus, _> =
            parse_enum("active", "sessions", "status");
        assert!(result.is_ok());
    }

    #[test]
    fn parse_enum_failure() {
        let result: Result<super::super::sessions::SessionStatus, _> =
            parse_enum("INVALID", "sessions", "status");
        assert!(matches!(result, Err(StoreError::CorruptRow { table: "sessions", column: "status", .. })));
    }

    #[test]
    fn parse_json_success() {
        let result = parse_json(r#"{"key": "value"}"#, "events", "payload");
        assert!(result.is_ok());
        assert_eq!(result.unwrap()["key"], "value");
    }

    #[test]
    fn parse_json_failure() {
        let result = parse_json("not valid json", "events", "payload");
        assert!(matches!(result, Err(StoreError::CorruptRow { table: "events", column: "payload", .. })));
    }
}
