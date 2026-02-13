# Tron Agent (Rust) - Patterns & Conventions

## Error Handling

### Per-Crate Error Enums

Each crate defines its own error enum via `thiserror`:

```rust
#[derive(Debug, thiserror::Error)]
pub enum EventStoreError {
    #[error("session not found: {0}")]
    SessionNotFound(SessionId),
    #[error("event not found: {0}")]
    EventNotFound(EventId),
    #[error("database error: {0}")]
    Database(#[from] rusqlite::Error),
}
```

### Propagation

Internal code uses `anyhow::Result` for convenience. Public APIs return typed errors. At RPC boundaries, errors are converted to `RpcError` with standard JSON-RPC error codes.

## Serialization

### Wire Format Compatibility

All types that cross the WebSocket boundary use `#[serde(rename_all = "camelCase")]` to match the TypeScript JSON format:

```rust
#[derive(Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct BaseEvent {
    pub id: EventId,
    pub session_id: SessionId,
    pub workspace_id: WorkspaceId,
    pub parent_id: Option<EventId>,
    pub sequence: u64,
    pub timestamp: DateTime<Utc>,
}
```

### Tagged Enums

TypeScript discriminated unions map to Rust tagged enums:

```rust
#[derive(Serialize, Deserialize)]
#[serde(tag = "type")]
pub enum SessionEvent {
    #[serde(rename = "session.start")]
    SessionStart { /* ... */ },
    #[serde(rename = "message.user")]
    MessageUser { /* ... */ },
}
```

### Roundtrip Tests

Every serializable type has roundtrip tests: `T -> JSON -> T` and `JSON fixture -> T -> JSON == fixture`.

## Testing

### Setup Pattern

Since Rust doesn't have `beforeEach`, use a setup function:

```rust
struct TestContext {
    store: EventStore,
    _tmp: TempDir,  // dropped when test ends
}

fn setup() -> TestContext {
    let tmp = TempDir::new().unwrap();
    let store = EventStore::open_in_memory().unwrap();
    TestContext { store, _tmp: tmp }
}

#[test]
fn test_append_event() {
    let ctx = setup();
    // ...
}
```

### Async Tests

Use `#[tokio::test]` for async tests. Use `tokio::time::pause()` + `advance()` for time-dependent tests (replaces `vi.useFakeTimers()`).

### Mocking

- Use trait objects + `mockall` for mock generation
- Manual mock implementations when `mockall` is too rigid
- `wiremock` for HTTP endpoint mocking (SSE responses)
- `tempfile::TempDir` for filesystem isolation (auto-cleanup)
- `rusqlite::Connection::open_in_memory()` for database tests

### Snapshot Tests

Use `insta` for complex output verification:

```rust
insta::assert_json_snapshot!(event_envelope);
```

### Property Tests

Use `proptest` for parser and serialization fuzzing:

```rust
proptest! {
    #[test]
    fn event_id_roundtrip(id in "[a-f0-9-]{36}") {
        let eid = EventId::new(id.clone());
        assert_eq!(eid.as_str(), &id);
    }
}
```

## Naming Conventions

| Concept | Convention | Example |
|---------|-----------|---------|
| Crate names | `tron-<subsystem>` | `tron-events` |
| Module files | `snake_case.rs` | `event_store.rs` |
| Types | `PascalCase` | `SessionEvent` |
| Functions | `snake_case` | `create_session()` |
| Constants | `SCREAMING_SNAKE` | `MAX_CONTEXT_WINDOW` |
| Feature flags | `kebab-case` | `vector-search` |
| Test modules | `mod tests` in same file | `#[cfg(test)] mod tests` |
| Integration tests | `tests/<name>.rs` | `tests/event_store.rs` |

## Module Organization

Each crate follows a consistent structure:

```
crates/tron-example/
├── Cargo.toml
├── src/
│   ├── lib.rs           # public API re-exports, module-level docs
│   ├── types.rs         # type definitions
│   ├── errors.rs        # error enum
│   ├── <feature>.rs     # implementation modules
│   └── tests/           # integration-style tests (optional)
└── tests/               # external integration tests
    └── <name>.rs
```

## Lint Configuration

Workspace-level lints in `Cargo.toml`:

- `deny(unsafe_code)`: No unsafe anywhere
- `warn(unused_results)`: Don't ignore Results
- `warn(missing_docs)`: Every public item documented
- Clippy pedantic enabled with targeted allows

## Documentation

Every public item gets rustdoc. Module-level `//!` docs explain purpose, design decisions, and key types. Documentation is detailed enough for an AI agent to understand and modify the code.
