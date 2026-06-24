use super::*;

// ── get_latest_events tests ──

#[test]
fn get_latest_events_all() {
    let conn = setup();
    for i in 1..=5 {
        let event = make_event(
            &format!("evt_{i}"),
            i,
            EventType::MessageUser,
            None,
            json!({}),
        );
        EventRepo::insert(&conn, &event).unwrap();
    }

    let events = EventRepo::get_latest_events(&conn, "sess_1", None).unwrap();
    assert_eq!(events.len(), 5);
    assert_eq!(events[0].sequence, 1);
    assert_eq!(events[4].sequence, 5);
}

#[test]
fn get_latest_events_with_limit() {
    let conn = setup();
    for i in 1..=10 {
        let event = make_event(
            &format!("evt_{i}"),
            i,
            EventType::MessageUser,
            None,
            json!({}),
        );
        EventRepo::insert(&conn, &event).unwrap();
    }

    let events = EventRepo::get_latest_events(&conn, "sess_1", Some(3)).unwrap();
    assert_eq!(events.len(), 3);
    // Should be the LAST 3 events, in ASC order
    assert_eq!(events[0].sequence, 8);
    assert_eq!(events[1].sequence, 9);
    assert_eq!(events[2].sequence, 10);
}

#[test]
fn get_latest_events_empty_session() {
    let conn = setup();
    let events = EventRepo::get_latest_events(&conn, "sess_1", Some(5)).unwrap();
    assert!(events.is_empty());
}

// ── get_events_before tests ──

#[test]
fn get_events_before_basic() {
    let conn = setup();
    for i in 1..=10 {
        let event = make_event(
            &format!("evt_{i}"),
            i,
            EventType::MessageUser,
            None,
            json!({}),
        );
        EventRepo::insert(&conn, &event).unwrap();
    }

    let events = EventRepo::get_events_before(&conn, "sess_1", 5, None).unwrap();
    assert_eq!(events.len(), 4); // sequences 1, 2, 3, 4
    assert_eq!(events[0].sequence, 1);
    assert_eq!(events[3].sequence, 4);
}

#[test]
fn get_events_before_with_limit() {
    let conn = setup();
    for i in 1..=10 {
        let event = make_event(
            &format!("evt_{i}"),
            i,
            EventType::MessageUser,
            None,
            json!({}),
        );
        EventRepo::insert(&conn, &event).unwrap();
    }

    // Get last 2 events before sequence 8
    let events = EventRepo::get_events_before(&conn, "sess_1", 8, Some(2)).unwrap();
    assert_eq!(events.len(), 2);
    // Should be sequences 6, 7 (the last 2 before 8, in ASC order)
    assert_eq!(events[0].sequence, 6);
    assert_eq!(events[1].sequence, 7);
}

#[test]
fn get_events_before_first_returns_empty() {
    let conn = setup();
    let event = make_event("evt_1", 1, EventType::MessageUser, None, json!({}));
    EventRepo::insert(&conn, &event).unwrap();

    let events = EventRepo::get_events_before(&conn, "sess_1", 1, None).unwrap();
    assert!(events.is_empty());
}

// ── has_events_before tests ──

#[test]
fn has_events_before_true() {
    let conn = setup();
    for i in 1..=5 {
        let event = make_event(
            &format!("evt_{i}"),
            i,
            EventType::MessageUser,
            None,
            json!({}),
        );
        EventRepo::insert(&conn, &event).unwrap();
    }

    assert!(EventRepo::has_events_before(&conn, "sess_1", 3).unwrap());
}

#[test]
fn has_events_before_false() {
    let conn = setup();
    let event = make_event("evt_1", 1, EventType::MessageUser, None, json!({}));
    EventRepo::insert(&conn, &event).unwrap();

    assert!(!EventRepo::has_events_before(&conn, "sess_1", 1).unwrap());
}

#[test]
fn has_events_before_empty_session() {
    let conn = setup();
    assert!(!EventRepo::has_events_before(&conn, "sess_1", 100).unwrap());
}

// ── Phase 6 edge case tests ──

#[test]
fn get_latest_events_limit_zero_returns_empty() {
    let conn = setup();
    for i in 1..=5 {
        let event = make_event(
            &format!("evt_{i}"),
            i,
            EventType::MessageUser,
            None,
            json!({}),
        );
        EventRepo::insert(&conn, &event).unwrap();
    }
    let events = EventRepo::get_latest_events(&conn, "sess_1", Some(0)).unwrap();
    assert!(events.is_empty());
}

#[test]
fn get_events_before_sequence_zero_returns_empty() {
    let conn = setup();
    for i in 1..=5 {
        let event = make_event(
            &format!("evt_{i}"),
            i,
            EventType::MessageUser,
            None,
            json!({}),
        );
        EventRepo::insert(&conn, &event).unwrap();
    }
    // Nothing has sequence < 0
    let events = EventRepo::get_events_before(&conn, "sess_1", 0, None).unwrap();
    assert!(events.is_empty());
}

#[test]
fn get_events_before_limit_zero_returns_empty() {
    let conn = setup();
    for i in 1..=5 {
        let event = make_event(
            &format!("evt_{i}"),
            i,
            EventType::MessageUser,
            None,
            json!({}),
        );
        EventRepo::insert(&conn, &event).unwrap();
    }
    let events = EventRepo::get_events_before(&conn, "sess_1", 3, Some(0)).unwrap();
    assert!(events.is_empty());
}

#[test]
fn has_events_before_sequence_zero_returns_false() {
    let conn = setup();
    let event = make_event("evt_1", 1, EventType::MessageUser, None, json!({}));
    EventRepo::insert(&conn, &event).unwrap();
    assert!(!EventRepo::has_events_before(&conn, "sess_1", 0).unwrap());
}

#[test]
fn get_latest_events_limit_larger_than_total() {
    let conn = setup();
    for i in 1..=3 {
        let event = make_event(
            &format!("evt_{i}"),
            i,
            EventType::MessageUser,
            None,
            json!({}),
        );
        EventRepo::insert(&conn, &event).unwrap();
    }
    // limit=100 but only 3 events exist
    let events = EventRepo::get_latest_events(&conn, "sess_1", Some(100)).unwrap();
    assert_eq!(events.len(), 3);
    assert_eq!(events[0].sequence, 1);
    assert_eq!(events[2].sequence, 3);
}

#[test]
fn sequence_gaps_dont_break_queries() {
    let conn = setup();
    // Insert events with sequence gaps: 1, 5, 10
    let e1 = make_event("evt_1", 1, EventType::MessageUser, None, json!({}));
    let e2 = make_event("evt_5", 5, EventType::MessageUser, None, json!({}));
    let e3 = make_event("evt_10", 10, EventType::MessageUser, None, json!({}));
    EventRepo::insert(&conn, &e1).unwrap();
    EventRepo::insert(&conn, &e2).unwrap();
    EventRepo::insert(&conn, &e3).unwrap();

    // get_latest_events returns all 3 in order
    let events = EventRepo::get_latest_events(&conn, "sess_1", None).unwrap();
    assert_eq!(events.len(), 3);
    assert_eq!(events[0].sequence, 1);
    assert_eq!(events[1].sequence, 5);
    assert_eq!(events[2].sequence, 10);

    // get_events_before with gap
    let events = EventRepo::get_events_before(&conn, "sess_1", 7, None).unwrap();
    assert_eq!(events.len(), 2); // seq 1 and 5
    assert_eq!(events[0].sequence, 1);
    assert_eq!(events[1].sequence, 5);

    // has_events_before across gap
    assert!(EventRepo::has_events_before(&conn, "sess_1", 7).unwrap());
    assert!(!EventRepo::has_events_before(&conn, "sess_1", 1).unwrap());
}
