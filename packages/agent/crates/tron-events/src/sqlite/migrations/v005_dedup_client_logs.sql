-- Deduplicate iOS client logs and prevent future duplicates.
--
-- The watermark-based dedup in logs.ingest races when multiple ingestion
-- calls arrive concurrently (all read the same watermark before any commit).
-- Fix: partial unique index + INSERT OR IGNORE in the handler.

-- Step 1: Remove existing duplicates, keeping the lowest rowid per group.
DELETE FROM logs
WHERE origin = 'ios-client'
  AND id NOT IN (
    SELECT MIN(id)
    FROM logs
    WHERE origin = 'ios-client'
    GROUP BY timestamp, component, message
  );

-- Step 2: Clean up orphaned FTS entries for deleted duplicates.
DELETE FROM logs_fts
WHERE log_id NOT IN (SELECT id FROM logs);

-- Step 3: Partial unique index — only applies to ios-client rows.
CREATE UNIQUE INDEX idx_logs_ios_client_dedup
  ON logs(timestamp, component, message)
  WHERE origin = 'ios-client';
