-- v003: Notification read state tracking
--
-- Tracks which NotifyApp events the user has read in the notification inbox.
-- Uses event_id (the events table PK) as the key — no new event types needed.

CREATE TABLE IF NOT EXISTS notification_read_state (
    event_id TEXT PRIMARY KEY,
    read_at  TEXT NOT NULL
);
