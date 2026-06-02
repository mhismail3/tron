-- v005: Drop the retired profile/home migration ledger.
--
-- Profile/home migration code belonged to the pre-profile-first install
-- layout. Runtime now supports only the current profile schema, so the ledger
-- table and indexes are removed from existing databases. Fresh databases never
-- create them in v001.

DROP INDEX IF EXISTS idx_profile_migrations_time;
DROP TABLE IF EXISTS profile_migrations;
