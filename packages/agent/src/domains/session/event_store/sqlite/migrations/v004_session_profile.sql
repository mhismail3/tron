-- v004: Persist the selected execution profile per session.
--
-- `source` remains an origin/type label ("chat", "cron", "import"). `profile`
-- is the AgentExecutionSpec child profile used to assemble prompts, context,
-- capability policy, provider policy, and audit metadata for the session.

ALTER TABLE sessions ADD COLUMN profile TEXT NOT NULL DEFAULT 'normal';

UPDATE sessions
   SET profile = 'chat'
 WHERE source = 'chat';

UPDATE sessions
   SET profile = 'normal'
 WHERE TRIM(profile) = '';

CREATE INDEX IF NOT EXISTS idx_sessions_profile ON sessions(profile);
