-- Drop logs FTS — unused by Rust API, 82% of DB space.
-- CLI search (tron logs -q) migrated to LIKE-based matching.
DROP TRIGGER IF EXISTS logs_fts_insert;
DROP TRIGGER IF EXISTS logs_fts_delete;
DROP TABLE IF EXISTS logs_fts;

-- Purge known noise (accumulated despite module overrides due to RUST_LOG override in dev).
DELETE FROM logs WHERE component = 'ort::logging';
DELETE FROM logs WHERE component = 'tron_llm::anthropic::message_sanitizer' AND level = 'warn';
