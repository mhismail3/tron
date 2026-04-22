use super::store::*;
use super::types::*;
use crate::events::{ConnectionConfig, ConnectionPool, new_in_memory, run_migrations};

fn setup_pool() -> ConnectionPool {
    let pool = new_in_memory(&ConnectionConfig::default()).unwrap();
    {
        let conn = pool.get().unwrap();
        conn.execute_batch("PRAGMA foreign_keys = ON;").unwrap();
        run_migrations(&conn).unwrap();
    }
    pool
}

// ─── history: record_prompt ────────────────────────────────────────────────

#[test]
fn record_prompt_inserts_new_row() {
    let pool = setup_pool();
    let outcome = record_prompt(&pool, "hello world").unwrap();
    match outcome {
        RecordOutcome::Inserted { id } => assert!(!id.is_empty()),
        other => panic!("expected Inserted, got {other:?}"),
    }

    let items = list_history(&pool, 10, None, None).unwrap().items;
    assert_eq!(items.len(), 1);
    assert_eq!(items[0].text, "hello world");
    assert_eq!(items[0].use_count, 1);
    assert_eq!(items[0].first_used_at, items[0].last_used_at);
    assert_eq!(items[0].char_count, 11);
}

#[test]
fn record_prompt_dedups_on_repeat() {
    let pool = setup_pool();
    let first = record_prompt(&pool, "same text").unwrap();
    let id1 = match first {
        RecordOutcome::Inserted { id } => id,
        _ => panic!("expected Inserted"),
    };

    // Sleep not needed; second call updates last_used_at to now.
    std::thread::sleep(std::time::Duration::from_millis(5));

    let second = record_prompt(&pool, "same text").unwrap();
    match second {
        RecordOutcome::Updated { id, use_count } => {
            assert_eq!(id, id1);
            assert_eq!(use_count, 2);
        }
        other => panic!("expected Updated, got {other:?}"),
    }

    let items = list_history(&pool, 10, None, None).unwrap().items;
    assert_eq!(items.len(), 1);
    assert_eq!(items[0].use_count, 2);
    assert!(items[0].last_used_at >= items[0].first_used_at);
}

#[test]
fn record_prompt_dedup_ignores_whitespace_and_crlf() {
    let pool = setup_pool();
    record_prompt(&pool, "  hello\r\nworld  ").unwrap();
    record_prompt(&pool, "hello\nworld").unwrap();

    let items = list_history(&pool, 10, None, None).unwrap().items;
    assert_eq!(items.len(), 1, "normalization should collapse to one row");
    assert_eq!(items[0].use_count, 2);
}

#[test]
fn record_prompt_dedup_nfc_equivalence() {
    let pool = setup_pool();
    let nfc = "caf\u{00e9}";     // é as single code point
    let nfd = "cafe\u{0301}";    // e + combining acute
    record_prompt(&pool, nfc).unwrap();
    record_prompt(&pool, nfd).unwrap();

    let items = list_history(&pool, 10, None, None).unwrap().items;
    assert_eq!(items.len(), 1, "NFC/NFD variants should hash equally");
    assert_eq!(items[0].use_count, 2);
}

#[test]
fn record_prompt_skips_blank() {
    let pool = setup_pool();
    assert_eq!(record_prompt(&pool, "").unwrap(), RecordOutcome::Skipped);
    assert_eq!(record_prompt(&pool, "   \n\t").unwrap(), RecordOutcome::Skipped);

    assert_eq!(list_history(&pool, 10, None, None).unwrap().items.len(), 0);
}

#[test]
fn record_prompt_distinct_texts_insert_separately() {
    let pool = setup_pool();
    record_prompt(&pool, "alpha").unwrap();
    record_prompt(&pool, "beta").unwrap();
    record_prompt(&pool, "gamma").unwrap();

    let items = list_history(&pool, 10, None, None).unwrap().items;
    assert_eq!(items.len(), 3);
}

#[test]
fn record_prompt_case_sensitive() {
    let pool = setup_pool();
    record_prompt(&pool, "Hello").unwrap();
    record_prompt(&pool, "hello").unwrap();
    assert_eq!(list_history(&pool, 10, None, None).unwrap().items.len(), 2);
}

#[test]
fn record_prompt_concurrent_dedup() {
    use std::sync::Arc;
    let pool = Arc::new(setup_pool());
    let mut handles = vec![];
    for _ in 0..10 {
        let p = pool.clone();
        handles.push(std::thread::spawn(move || {
            record_prompt(&p, "shared prompt").unwrap()
        }));
    }
    for h in handles {
        let _ = h.join().unwrap();
    }

    let items = list_history(&pool, 10, None, None).unwrap().items;
    assert_eq!(items.len(), 1);
    assert_eq!(items[0].use_count, 10);
}

// ─── history: list_history (pagination + search) ───────────────────────────

#[test]
fn list_history_sorts_by_last_used_desc() {
    let pool = setup_pool();
    record_prompt(&pool, "first").unwrap();
    std::thread::sleep(std::time::Duration::from_millis(10));
    record_prompt(&pool, "second").unwrap();
    std::thread::sleep(std::time::Duration::from_millis(10));
    record_prompt(&pool, "third").unwrap();

    let items = list_history(&pool, 10, None, None).unwrap().items;
    assert_eq!(items[0].text, "third");
    assert_eq!(items[1].text, "second");
    assert_eq!(items[2].text, "first");
}

#[test]
fn list_history_pagination_cursor_roundtrip() {
    let pool = setup_pool();
    for i in 0..7 {
        record_prompt(&pool, &format!("prompt {i}")).unwrap();
        std::thread::sleep(std::time::Duration::from_millis(2));
    }

    let page1 = list_history(&pool, 3, None, None).unwrap();
    assert_eq!(page1.items.len(), 3);
    assert!(page1.next_cursor.is_some());

    let page2 = list_history(&pool, 3, page1.next_cursor.clone(), None).unwrap();
    assert_eq!(page2.items.len(), 3);
    assert!(page2.next_cursor.is_some());

    let page3 = list_history(&pool, 3, page2.next_cursor.clone(), None).unwrap();
    assert_eq!(page3.items.len(), 1);
    assert!(page3.next_cursor.is_none());

    // No duplicate ids across pages.
    let mut all_ids: Vec<String> = vec![];
    for page in [&page1, &page2, &page3] {
        for it in &page.items {
            all_ids.push(it.id.clone());
        }
    }
    let mut unique = all_ids.clone();
    unique.sort();
    unique.dedup();
    assert_eq!(all_ids.len(), unique.len(), "pages overlapped");
}

#[test]
fn list_history_limit_clamped_to_max() {
    let pool = setup_pool();
    for i in 0..3 {
        record_prompt(&pool, &format!("p {i}")).unwrap();
    }
    let items = list_history(&pool, 10_000, None, None).unwrap().items;
    assert!(items.len() <= super::store::MAX_LIST_LIMIT as usize);
}

#[test]
fn list_history_search_substring() {
    let pool = setup_pool();
    record_prompt(&pool, "fix the bug in parser").unwrap();
    record_prompt(&pool, "run the tests").unwrap();
    record_prompt(&pool, "bug report template").unwrap();

    let items = list_history(&pool, 10, None, Some("bug".into())).unwrap().items;
    assert_eq!(items.len(), 2);
    for it in &items {
        assert!(it.text.contains("bug"));
    }
}

#[test]
fn list_history_search_escapes_like_wildcards() {
    let pool = setup_pool();
    record_prompt(&pool, "100% coverage").unwrap();
    record_prompt(&pool, "anything goes").unwrap();
    record_prompt(&pool, "literal_under_score").unwrap();

    // `%` must match literal percent, not "anything".
    let items = list_history(&pool, 10, None, Some("%".into())).unwrap().items;
    assert_eq!(items.len(), 1);
    assert!(items[0].text.contains('%'));

    // `_` must match literal underscore, not a single char.
    let items = list_history(&pool, 10, None, Some("_under_".into())).unwrap().items;
    assert_eq!(items.len(), 1);
}

#[test]
fn list_history_empty_query_returns_all() {
    let pool = setup_pool();
    record_prompt(&pool, "a").unwrap();
    record_prompt(&pool, "b").unwrap();
    let items = list_history(&pool, 10, None, Some("".into())).unwrap().items;
    assert_eq!(items.len(), 2);
}

#[test]
fn list_history_bad_cursor_errors() {
    let pool = setup_pool();
    let err = list_history(&pool, 10, Some("not-valid-base64!!!".into()), None);
    assert!(err.is_err());
}

// ─── history: delete / clear / prune ──────────────────────────────────────

#[test]
fn delete_history_idempotent() {
    let pool = setup_pool();
    let RecordOutcome::Inserted { id } = record_prompt(&pool, "x").unwrap() else {
        panic!();
    };
    assert!(delete_history(&pool, &id).unwrap());
    assert!(!delete_history(&pool, &id).unwrap(), "second delete returns false");
    assert!(!delete_history(&pool, "nonexistent").unwrap());
}

#[test]
fn clear_history_returns_count() {
    let pool = setup_pool();
    record_prompt(&pool, "a").unwrap();
    record_prompt(&pool, "b").unwrap();
    record_prompt(&pool, "c").unwrap();

    let n = clear_history(&pool).unwrap();
    assert_eq!(n, 3);
    assert_eq!(list_history(&pool, 10, None, None).unwrap().items.len(), 0);
}

#[test]
fn prune_history_by_count_keeps_newest() {
    let pool = setup_pool();
    for i in 0..10 {
        record_prompt(&pool, &format!("prompt {i}")).unwrap();
        std::thread::sleep(std::time::Duration::from_millis(2));
    }
    let pruned = prune_history(&pool, None, Some(5)).unwrap();
    assert_eq!(pruned, 5);
    let items = list_history(&pool, 100, None, None).unwrap().items;
    assert_eq!(items.len(), 5);
    assert_eq!(items[0].text, "prompt 9");
    assert_eq!(items[4].text, "prompt 5");
}

#[test]
fn prune_history_unlimited_when_zero() {
    let pool = setup_pool();
    for i in 0..5 {
        record_prompt(&pool, &format!("p {i}")).unwrap();
    }
    let pruned = prune_history(&pool, None, Some(0)).unwrap();
    assert_eq!(pruned, 0);
    assert_eq!(list_history(&pool, 100, None, None).unwrap().items.len(), 5);
}

// ─── history: record_prompt_and_prune ──────────────────────────────────────

#[test]
fn auto_prune_fires_on_threshold_crossing() {
    // *** M21 regression test ***
    //
    // Inserting beyond `max_entries` must stabilize the row count at the
    // cap — never accumulate past it — because the prune runs inline on
    // every insert that grows the population.
    let pool = setup_pool();
    let cap: u32 = 5;

    for i in 0..(cap + 3) {
        record_prompt_and_prune(&pool, &format!("prompt {i:02}"), Some(cap), None).unwrap();
        // Tiny stagger so last_used_at ordering is deterministic across rows.
        std::thread::sleep(std::time::Duration::from_millis(2));
    }

    let items = list_history(&pool, 100, None, None).unwrap().items;
    assert_eq!(items.len(), cap as usize, "count must be clamped to cap");
    // Newest `cap` entries survive; oldest three were pruned.
    assert_eq!(items[0].text, format!("prompt {:02}", cap + 2));
    assert_eq!(items[cap as usize - 1].text, "prompt 03");
}

#[test]
fn auto_prune_does_not_fire_on_dedup() {
    // Dedup → Updated, count unchanged, so no prune opportunity. Ensures
    // a long conversation that repeatedly re-sends the same prompt does
    // not churn DELETE queries against the table.
    let pool = setup_pool();
    let cap: u32 = 5;

    for i in 0..cap {
        record_prompt_and_prune(&pool, &format!("p {i:02}"), Some(cap), None).unwrap();
        std::thread::sleep(std::time::Duration::from_millis(2));
    }
    let outcome = record_prompt_and_prune(&pool, "p 00", Some(cap), None).unwrap();
    assert!(
        matches!(outcome, RecordOutcome::Updated { .. }),
        "repeat must dedup, not insert"
    );

    let items = list_history(&pool, 100, None, None).unwrap().items;
    assert_eq!(items.len(), cap as usize);
}

#[test]
fn auto_prune_disabled_when_caps_none() {
    // None/None → no prune, no cap enforcement.
    let pool = setup_pool();
    for i in 0..10 {
        record_prompt_and_prune(&pool, &format!("p {i:02}"), None, None).unwrap();
    }
    let items = list_history(&pool, 100, None, None).unwrap().items;
    assert_eq!(items.len(), 10);
}

#[test]
fn auto_prune_applies_age_and_count_together() {
    // Both axes active. Count-cap path is straightforward (covered above);
    // this confirms age is honored as well when caller passes it.
    let pool = setup_pool();
    // Seed an expired row by back-dating its last_used_at.
    record_prompt_and_prune(&pool, "old", None, None).unwrap();
    {
        let conn = pool.get().unwrap();
        conn.execute(
            "UPDATE prompt_history SET last_used_at = ?1, first_used_at = ?1 WHERE text = 'old'",
            rusqlite::params!["2020-01-01T00:00:00Z"],
        )
        .unwrap();
    }
    // An insert with age_days=1 should sweep the old row via amortized prune.
    record_prompt_and_prune(&pool, "fresh", Some(10), Some(1)).unwrap();
    let items = list_history(&pool, 100, None, None).unwrap().items;
    assert_eq!(items.len(), 1, "old row pruned by age");
    assert_eq!(items[0].text, "fresh");
}

#[test]
fn auto_prune_blank_input_does_not_prune() {
    // Blank → Skipped, no insert, no prune.
    let pool = setup_pool();
    for i in 0..3 {
        record_prompt_and_prune(&pool, &format!("p {i}"), Some(2), None).unwrap();
    }
    let before = list_history(&pool, 100, None, None).unwrap().items.len();
    // Sending blank should not alter the population.
    let outcome = record_prompt_and_prune(&pool, "   ", Some(2), None).unwrap();
    assert_eq!(outcome, RecordOutcome::Skipped);
    let after = list_history(&pool, 100, None, None).unwrap().items.len();
    assert_eq!(before, after);
}

// ─── snippets ──────────────────────────────────────────────────────────────

#[test]
fn create_snippet_valid_inputs() {
    let pool = setup_pool();
    let s = create_snippet(&pool, "My Snippet", "do the thing").unwrap();
    assert_eq!(s.name, "My Snippet");
    assert_eq!(s.text, "do the thing");
    assert_eq!(s.created_at, s.updated_at);
    assert!(!s.id.is_empty());
}

#[test]
fn create_snippet_rejects_empty_name() {
    let pool = setup_pool();
    assert!(create_snippet(&pool, "", "hello").is_err());
    assert!(create_snippet(&pool, "   ", "hello").is_err());
}

#[test]
fn create_snippet_rejects_empty_text() {
    let pool = setup_pool();
    assert!(create_snippet(&pool, "name", "").is_err());
}

#[test]
fn create_snippet_rejects_name_too_long() {
    let pool = setup_pool();
    let long = "a".repeat(101);
    assert!(create_snippet(&pool, &long, "hello").is_err());
    // 100-char name is accepted.
    let max = "a".repeat(100);
    assert!(create_snippet(&pool, &max, "hello").is_ok());
}

#[test]
fn create_snippet_duplicate_names_allowed() {
    let pool = setup_pool();
    create_snippet(&pool, "Shared", "a").unwrap();
    create_snippet(&pool, "Shared", "b").unwrap();
    assert_eq!(list_snippets(&pool).unwrap().len(), 2);
}

#[test]
fn update_snippet_name_only() {
    let pool = setup_pool();
    let s = create_snippet(&pool, "Orig", "body").unwrap();
    std::thread::sleep(std::time::Duration::from_millis(10));
    let updated = update_snippet(&pool, &s.id, Some("New Name".into()), None)
        .unwrap()
        .unwrap();
    assert_eq!(updated.name, "New Name");
    assert_eq!(updated.text, "body");
    assert!(updated.updated_at > s.updated_at);
    assert_eq!(updated.created_at, s.created_at);
}

#[test]
fn update_snippet_text_only() {
    let pool = setup_pool();
    let s = create_snippet(&pool, "Name", "old").unwrap();
    let updated = update_snippet(&pool, &s.id, None, Some("new".into()))
        .unwrap()
        .unwrap();
    assert_eq!(updated.name, "Name");
    assert_eq!(updated.text, "new");
}

#[test]
fn update_snippet_missing_id_returns_none() {
    let pool = setup_pool();
    let out = update_snippet(&pool, "does-not-exist", Some("x".into()), None).unwrap();
    assert!(out.is_none());
}

#[test]
fn update_snippet_rejects_invalid_new_name() {
    let pool = setup_pool();
    let s = create_snippet(&pool, "Orig", "body").unwrap();
    assert!(update_snippet(&pool, &s.id, Some("".into()), None).is_err());
    assert!(update_snippet(&pool, &s.id, Some("a".repeat(101)), None).is_err());
}

#[test]
fn update_snippet_rejects_empty_new_text() {
    let pool = setup_pool();
    let s = create_snippet(&pool, "N", "body").unwrap();
    assert!(update_snippet(&pool, &s.id, None, Some("".into())).is_err());
}

#[test]
fn delete_snippet_idempotent() {
    let pool = setup_pool();
    let s = create_snippet(&pool, "N", "t").unwrap();
    assert!(delete_snippet(&pool, &s.id).unwrap());
    assert!(!delete_snippet(&pool, &s.id).unwrap());
    assert!(!delete_snippet(&pool, "nope").unwrap());
}

#[test]
fn list_snippets_sorted_by_updated_desc() {
    let pool = setup_pool();
    let a = create_snippet(&pool, "A", "a").unwrap();
    std::thread::sleep(std::time::Duration::from_millis(5));
    let _b = create_snippet(&pool, "B", "b").unwrap();
    std::thread::sleep(std::time::Duration::from_millis(5));
    let _c = create_snippet(&pool, "C", "c").unwrap();
    std::thread::sleep(std::time::Duration::from_millis(5));
    // Bump A's updated_at
    update_snippet(&pool, &a.id, None, Some("a2".into())).unwrap();

    let items = list_snippets(&pool).unwrap();
    assert_eq!(items[0].name, "A");
    assert_eq!(items[1].name, "C");
    assert_eq!(items[2].name, "B");
}

#[test]
fn get_snippet_roundtrip() {
    let pool = setup_pool();
    let s = create_snippet(&pool, "N", "t").unwrap();
    let loaded = get_snippet(&pool, &s.id).unwrap().unwrap();
    assert_eq!(loaded, s);
    assert!(get_snippet(&pool, "nope").unwrap().is_none());
}
