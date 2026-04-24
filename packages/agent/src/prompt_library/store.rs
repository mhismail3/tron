//! SQLite-backed store for prompt history and snippets.
//!
//! All functions take a `&ConnectionPool` and are safe to call from sync
//! contexts (inside `tokio::task::spawn_blocking` for async callers).

use base64::Engine;
use chrono::Utc;
use rusqlite::{OptionalExtension, params};

use crate::events::sqlite::contention::{
    BusyRetryPolicy, RetryError, is_rusqlite_busy, retry_on_busy,
};
use crate::events::{ConnectionPool, EventStoreError, Result};
use crate::prompt_library::normalize::{hash_hex, is_blank, normalize_for_hash};
use crate::prompt_library::types::{HistoryItem, HistoryPage, RecordOutcome, Snippet};

/// Maximum rows returned by `list_history` in a single page.
pub const MAX_LIST_LIMIT: u32 = 200;
/// Default page size when caller doesn't specify.
pub const DEFAULT_LIST_LIMIT: u32 = 50;
/// Maximum `name` length for a snippet (matches DB CHECK).
pub const SNIPPET_NAME_MAX: usize = 100;

// ─── history: record ────────────────────────────────────────────────────────

/// Record a prompt send. Inserts a new row if unseen, otherwise bumps
/// `last_used_at` and `use_count`. Blank/whitespace input is skipped.
pub fn record_prompt(pool: &ConnectionPool, text: &str) -> Result<RecordOutcome> {
    if is_blank(text) {
        return Ok(RecordOutcome::Skipped);
    }

    let trimmed_display = text.trim().to_string();
    let normalized = normalize_for_hash(text);
    let text_hash = hash_hex(normalized.as_bytes());
    let now = Utc::now().to_rfc3339();
    let char_count = trimmed_display.chars().count() as i64;
    let new_id = uuid::Uuid::now_v7().to_string();

    // Retry on SQLite BUSY/LOCKED — record_prompt is called fire-and-forget
    // from spawn_blocking and must tolerate brief contention.
    let (id, use_count, inserted): (String, i64, bool) = match retry_on_busy(
        "prompt_library.record_prompt",
        BusyRetryPolicy::sqlite_write(),
        || -> std::result::Result<(String, i64, bool), rusqlite::Error> {
            let conn = pool.get().map_err(|_| {
                rusqlite::Error::SqliteFailure(
                    rusqlite::ffi::Error::new(rusqlite::ffi::SQLITE_BUSY),
                    Some("pool exhausted".into()),
                )
            })?;
            conn.query_row(
                "INSERT INTO prompt_history
                    (id, text, text_hash, first_used_at, last_used_at, use_count, char_count)
                 VALUES (?1, ?2, ?3, ?4, ?4, 1, ?5)
                 ON CONFLICT(text_hash) DO UPDATE SET
                    last_used_at = excluded.last_used_at,
                    use_count    = prompt_history.use_count + 1
                 RETURNING id, use_count, (first_used_at = last_used_at) AS is_new",
                params![new_id, trimmed_display, text_hash, now, char_count],
                |row| {
                    Ok((
                        row.get::<_, String>(0)?,
                        row.get::<_, i64>(1)?,
                        row.get::<_, bool>(2)?,
                    ))
                },
            )
        },
        is_rusqlite_busy,
    ) {
        Ok(v) => v,
        Err(RetryError::Inner(e)) => return Err(EventStoreError::Sqlite(e)),
        Err(RetryError::BusyTimeout(bt)) => {
            return Err(EventStoreError::Busy {
                operation: "prompt_library.record_prompt",
                attempts: bt.attempts,
            });
        }
    };

    Ok(if inserted {
        RecordOutcome::Inserted { id }
    } else {
        RecordOutcome::Updated { id, use_count }
    })
}

/// Record a prompt and, when the insert grows the population past a cap,
/// prune inline.
///
/// Mirrors [`record_prompt`] for the insert/dedup path. Additionally, when
/// the outcome is [`RecordOutcome::Inserted`] AND at least one retention
/// axis is enabled (`max_entries` or `max_age_days`), invokes
/// [`prune_history`] in the same call so the row count stays bounded
/// amortized across inserts.
///
/// Updates and skipped (blank) inputs do not trigger pruning — the
/// population only grows on inserts, so dedups cannot cross the threshold.
///
/// Prune failures are propagated to the caller so fire-and-forget call
/// sites can log (and swallow) uniformly with insert failures. The insert
/// always commits before the prune runs; a failing prune does not unwind
/// the insert.
pub fn record_prompt_and_prune(
    pool: &ConnectionPool,
    text: &str,
    max_entries: Option<u32>,
    max_age_days: Option<u32>,
) -> Result<RecordOutcome> {
    let outcome = record_prompt(pool, text)?;

    if matches!(outcome, RecordOutcome::Inserted { .. }) {
        let cap_active = max_entries.is_some_and(|n| n > 0);
        let age_active = max_age_days.is_some_and(|n| n > 0);
        if cap_active || age_active {
            let _ = prune_history(pool, max_age_days, max_entries)?;
        }
    }

    Ok(outcome)
}

// ─── history: list ──────────────────────────────────────────────────────────

/// Paginated list of history items, newest first. Optional case-sensitive
/// substring search over `text`.
pub fn list_history(
    pool: &ConnectionPool,
    limit: u32,
    cursor: Option<String>,
    query: Option<String>,
) -> Result<HistoryPage> {
    let effective_limit = limit.clamp(1, MAX_LIST_LIMIT);
    let query_trimmed = query.as_deref().map(str::trim).filter(|s| !s.is_empty());

    let cursor_pair = cursor.map(decode_cursor).transpose()?;

    let conn = pool.get()?;

    // Build SQL dynamically based on whether cursor / query are present.
    let mut sql = String::from(
        "SELECT id, text, first_used_at, last_used_at, use_count, char_count
         FROM prompt_history
         WHERE 1=1",
    );
    let mut args: Vec<Box<dyn rusqlite::ToSql>> = Vec::new();

    if let Some((ts, id)) = &cursor_pair {
        sql.push_str(" AND (last_used_at < ?1 OR (last_used_at = ?1 AND id < ?2))");
        args.push(Box::new(ts.clone()));
        args.push(Box::new(id.clone()));
    }

    if let Some(q) = query_trimmed {
        let placeholder = format!("?{}", args.len() + 1);
        sql.push_str(&format!(" AND text LIKE {placeholder} ESCAPE '\\'"));
        args.push(Box::new(format!("%{}%", escape_like(q))));
    }

    sql.push_str(" ORDER BY last_used_at DESC, id DESC LIMIT ?");
    args.push(Box::new((effective_limit as i64) + 1)); // +1 to detect next page

    let mut stmt = conn.prepare(&sql)?;
    let rows = stmt
        .query_map(
            rusqlite::params_from_iter(args.iter().map(|b| b.as_ref())),
            |row| {
                Ok(HistoryItem {
                    id: row.get(0)?,
                    text: row.get(1)?,
                    first_used_at: row.get(2)?,
                    last_used_at: row.get(3)?,
                    use_count: row.get(4)?,
                    char_count: row.get(5)?,
                })
            },
        )?
        .collect::<std::result::Result<Vec<_>, _>>()?;

    let (items, next_cursor) = if rows.len() > effective_limit as usize {
        let mut trimmed = rows;
        trimmed.truncate(effective_limit as usize);
        let last = trimmed.last().expect("non-empty");
        let cursor = encode_cursor(&last.last_used_at, &last.id);
        (trimmed, Some(cursor))
    } else {
        (rows, None)
    };

    Ok(HistoryPage { items, next_cursor })
}

fn encode_cursor(last_used_at: &str, id: &str) -> String {
    let joined = format!("{last_used_at}|{id}");
    base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(joined.as_bytes())
}

fn decode_cursor(encoded: String) -> Result<(String, String)> {
    let raw = base64::engine::general_purpose::URL_SAFE_NO_PAD
        .decode(encoded.as_bytes())
        .map_err(|e| EventStoreError::InvalidOperation(format!("bad cursor: {e}")))?;
    let s = String::from_utf8(raw)
        .map_err(|e| EventStoreError::InvalidOperation(format!("bad cursor utf8: {e}")))?;
    let (ts, id) = s
        .split_once('|')
        .ok_or_else(|| EventStoreError::InvalidOperation("bad cursor format".into()))?;
    if ts.is_empty() || id.is_empty() {
        return Err(EventStoreError::InvalidOperation(
            "empty cursor field".into(),
        ));
    }
    Ok((ts.to_string(), id.to_string()))
}

/// Escape the three SQL `LIKE` metacharacters so a user-supplied substring
/// can be embedded inside a `LIKE '%…%'` pattern without turning stray `%`
/// or `_` into wildcards.
///
/// The caller must pair the resulting pattern with `ESCAPE '\'` in the SQL
/// (see `list_history` at the only call site). Using a different escape
/// char on the Rust side and the SQL side would silently leak wildcards.
///
/// Escaped characters:
/// - `\` → `\\`   (the escape char itself; a bare trailing `\` would
///                 otherwise leave a dangling escape in the pattern and
///                 SQLite would error at prepare time)
/// - `%` → `\%`   (matches literal percent, not "anything")
/// - `_` → `\_`   (matches literal underscore, not "exactly one character")
///
/// Everything else passes through unchanged. Notable edge cases:
///
/// - **Multi-byte code points** (emoji, CJK, accented Latin) iterate by
///   Unicode scalar via `str::chars()`, so escaping never splits a
///   grapheme. Only the three ASCII metacharacters are matched; `％`
///   (full-width percent, U+FF05) is NOT a LIKE wildcard and is passed
///   through untouched, matching SQLite's behavior.
/// - **Empty input** returns an empty string. The only production caller
///   (`list_history`) filters empty / whitespace-only queries via
///   `query_trimmed`, so an empty pattern is never assembled. The
///   function is still safe to call with `""`.
/// - **Embedded `NUL` (`'\0'`)** passes through. SQLite's LIKE does not
///   special-case NUL; pattern and target are compared as UTF-8 bytes.
/// - **SQLite's default `LIKE` is case-insensitive over ASCII only.** That
///   is a SQL-level property, orthogonal to this function.
fn escape_like(input: &str) -> String {
    let mut out = String::with_capacity(input.len());
    for ch in input.chars() {
        match ch {
            '\\' | '%' | '_' => {
                out.push('\\');
                out.push(ch);
            }
            _ => out.push(ch),
        }
    }
    out
}

#[cfg(test)]
mod escape_like_tests {
    use super::escape_like;

    #[test]
    fn empty_input_returns_empty() {
        assert_eq!(escape_like(""), "");
    }

    #[test]
    fn ascii_passthrough_unchanged() {
        assert_eq!(
            escape_like("search for a bug in handler"),
            "search for a bug in handler"
        );
    }

    #[test]
    fn percent_is_escaped() {
        assert_eq!(escape_like("100%"), "100\\%");
    }

    #[test]
    fn underscore_is_escaped() {
        assert_eq!(escape_like("snake_case"), "snake\\_case");
    }

    #[test]
    fn backslash_itself_is_escaped() {
        // Critical: a bare `\` in the user's query, combined with the SQL's
        // `ESCAPE '\'`, would otherwise produce a dangling escape and a
        // prepare-time error.
        assert_eq!(escape_like("path\\to"), "path\\\\to");
    }

    #[test]
    fn trailing_backslash_is_escaped() {
        // Worst-case placement — the previous behavior without escaping
        // would end the pattern on a dangling `\`.
        assert_eq!(escape_like("trail\\"), "trail\\\\");
    }

    #[test]
    fn all_three_metacharacters_escaped_in_one_string() {
        assert_eq!(escape_like("a_b%c\\d"), "a\\_b\\%c\\\\d");
    }

    #[test]
    fn multibyte_emoji_preserved_verbatim() {
        // 💡 is 4 UTF-8 bytes but a single `char`. Only ASCII `%` / `_` /
        // `\` are escaped; the emoji must survive intact.
        assert_eq!(escape_like("idea 💡 %done"), "idea 💡 \\%done");
    }

    #[test]
    fn cjk_and_accents_pass_through() {
        assert_eq!(escape_like("café 漢字"), "café 漢字");
    }

    #[test]
    fn fullwidth_percent_is_not_a_wildcard_and_passes_through() {
        // U+FF05 FULLWIDTH PERCENT SIGN is not a LIKE wildcard in SQLite.
        // Escaping it would change the matching semantics, so we don't.
        assert_eq!(escape_like("９９％"), "９９％");
    }

    #[test]
    fn nul_byte_passes_through() {
        // SQLite LIKE has no special behavior for NUL; echo it through.
        assert_eq!(escape_like("a\0b"), "a\0b");
    }

    #[test]
    fn repeated_metacharacters_each_get_escaped() {
        assert_eq!(escape_like("%%__\\\\"), "\\%\\%\\_\\_\\\\\\\\");
    }

    #[test]
    fn output_preserves_input_order() {
        // Regression guard: char-by-char iteration, no reordering.
        let input = "x_y%z\\w";
        let escaped = escape_like(input);
        // Strip the escape backslashes inserted before each metacharacter
        // and the original characters must reappear in the same order.
        let stripped: String = {
            let mut chars = escaped.chars().peekable();
            let mut out = String::new();
            while let Some(c) = chars.next() {
                if c == '\\'
                    && let Some(&next) = chars.peek()
                    && matches!(next, '\\' | '%' | '_')
                {
                    // drop the escape and keep the escaped char
                    out.push(chars.next().unwrap());
                } else {
                    out.push(c);
                }
            }
            out
        };
        assert_eq!(stripped, input);
    }
}

// ─── history: delete / clear / prune ───────────────────────────────────────

/// Delete a single history row. Returns `true` if the row existed.
pub fn delete_history(pool: &ConnectionPool, id: &str) -> Result<bool> {
    let conn = pool.get()?;
    let affected = conn.execute("DELETE FROM prompt_history WHERE id = ?1", params![id])?;
    Ok(affected > 0)
}

/// Delete every history row. Returns the count of rows removed.
pub fn clear_history(pool: &ConnectionPool) -> Result<u64> {
    let conn = pool.get()?;
    let affected = conn.execute("DELETE FROM prompt_history", [])?;
    Ok(affected as u64)
}

/// Prune history. `max_age_days = Some(n > 0)` deletes rows older than N days.
/// `max_entries = Some(n > 0)` keeps only the N most recent rows (by `last_used_at`).
/// A value of `Some(0)` or `None` disables that pruning axis.
pub fn prune_history(
    pool: &ConnectionPool,
    max_age_days: Option<u32>,
    max_entries: Option<u32>,
) -> Result<u64> {
    let conn = pool.get()?;
    let mut total = 0u64;

    if let Some(days) = max_age_days {
        if days > 0 {
            let cutoff = Utc::now() - chrono::Duration::days(days as i64);
            let n = conn.execute(
                "DELETE FROM prompt_history WHERE last_used_at < ?1",
                params![cutoff.to_rfc3339()],
            )?;
            total += n as u64;
        }
    }

    if let Some(max) = max_entries {
        if max > 0 {
            let n = conn.execute(
                "DELETE FROM prompt_history
                 WHERE id IN (
                    SELECT id FROM prompt_history
                    ORDER BY last_used_at DESC, id DESC
                    LIMIT -1 OFFSET ?1
                 )",
                params![max as i64],
            )?;
            total += n as u64;
        }
    }

    Ok(total)
}

// ─── snippets ──────────────────────────────────────────────────────────────

fn validate_snippet_name(name: &str) -> Result<String> {
    let trimmed = name.trim();
    if trimmed.is_empty() {
        return Err(EventStoreError::InvalidOperation(
            "snippet name must be non-empty".into(),
        ));
    }
    if trimmed.chars().count() > SNIPPET_NAME_MAX {
        return Err(EventStoreError::InvalidOperation(format!(
            "snippet name must be ≤ {SNIPPET_NAME_MAX} characters"
        )));
    }
    Ok(trimmed.to_string())
}

fn validate_snippet_text(text: &str) -> Result<String> {
    if text.is_empty() {
        return Err(EventStoreError::InvalidOperation(
            "snippet text must be non-empty".into(),
        ));
    }
    Ok(text.to_string())
}

/// Insert a new snippet with a freshly generated UUID v7 and return it.
pub fn create_snippet(pool: &ConnectionPool, name: &str, text: &str) -> Result<Snippet> {
    let name_clean = validate_snippet_name(name)?;
    let text_clean = validate_snippet_text(text)?;
    let id = uuid::Uuid::now_v7().to_string();
    let now = Utc::now().to_rfc3339();

    let conn = pool.get()?;
    let _ = conn.execute(
        "INSERT INTO prompt_snippets (id, name, text, created_at, updated_at)
         VALUES (?1, ?2, ?3, ?4, ?4)",
        params![id, name_clean, text_clean, now],
    )?;

    Ok(Snippet {
        id,
        name: name_clean,
        text: text_clean,
        created_at: now.clone(),
        updated_at: now,
    })
}

/// Update a snippet's `name`, `text`, or both. Returns `Ok(None)` when the id
/// doesn't exist. At least one of `name`/`text` must be `Some`.
pub fn update_snippet(
    pool: &ConnectionPool,
    id: &str,
    name: Option<String>,
    text: Option<String>,
) -> Result<Option<Snippet>> {
    let name_clean = name.map(|n| validate_snippet_name(&n)).transpose()?;
    let text_clean = text.map(|t| validate_snippet_text(&t)).transpose()?;

    if name_clean.is_none() && text_clean.is_none() {
        return Err(EventStoreError::InvalidOperation(
            "update_snippet requires at least one of name or text".into(),
        ));
    }

    let now = Utc::now().to_rfc3339();
    let conn = pool.get()?;

    // COALESCE preserves the existing value when the parameter is NULL.
    let affected = conn.execute(
        "UPDATE prompt_snippets
         SET name = COALESCE(?2, name),
             text = COALESCE(?3, text),
             updated_at = ?4
         WHERE id = ?1",
        params![id, name_clean, text_clean, now],
    )?;

    if affected == 0 {
        return Ok(None);
    }
    get_snippet(pool, id)
}

/// Delete a snippet. Returns `true` if the row existed.
pub fn delete_snippet(pool: &ConnectionPool, id: &str) -> Result<bool> {
    let conn = pool.get()?;
    let affected = conn.execute("DELETE FROM prompt_snippets WHERE id = ?1", params![id])?;
    Ok(affected > 0)
}

/// List all snippets ordered by `updated_at DESC`.
pub fn list_snippets(pool: &ConnectionPool) -> Result<Vec<Snippet>> {
    let conn = pool.get()?;
    let mut stmt = conn.prepare(
        "SELECT id, name, text, created_at, updated_at
         FROM prompt_snippets
         ORDER BY updated_at DESC, id DESC",
    )?;
    let rows = stmt
        .query_map([], |row| {
            Ok(Snippet {
                id: row.get(0)?,
                name: row.get(1)?,
                text: row.get(2)?,
                created_at: row.get(3)?,
                updated_at: row.get(4)?,
            })
        })?
        .collect::<std::result::Result<Vec<_>, _>>()?;
    Ok(rows)
}

/// Look up a single snippet by id.
pub fn get_snippet(pool: &ConnectionPool, id: &str) -> Result<Option<Snippet>> {
    let conn = pool.get()?;
    let row = conn
        .query_row(
            "SELECT id, name, text, created_at, updated_at
             FROM prompt_snippets
             WHERE id = ?1",
            params![id],
            |row| {
                Ok(Snippet {
                    id: row.get(0)?,
                    name: row.get(1)?,
                    text: row.get(2)?,
                    created_at: row.get(3)?,
                    updated_at: row.get(4)?,
                })
            },
        )
        .optional()?;
    Ok(row)
}
