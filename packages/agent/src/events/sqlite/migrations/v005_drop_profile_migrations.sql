-- v005: Drop the retired profile/home migration ledger.
--
-- Profile/home migration code was a temporary bridge for the profile-first
-- refactor. Runtime now supports only the current profile schema, so the
-- ledger table and indexes are removed from existing databases. Fresh
-- databases never create them in v001.

DROP INDEX IF EXISTS idx_profile_migrations_legacy;
DROP INDEX IF EXISTS idx_profile_migrations_time;
DROP TABLE IF EXISTS profile_migrations;
