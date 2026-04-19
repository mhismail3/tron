-- v003: Remove legacy spell events
--
-- The Spells feature has been removed. Purge all historical spell.cast and
-- spell.consumed rows so that they don't get coerced to SessionStart by the
-- EventType::from_str() fallback in event_rows_to_session_events.
--
-- This is a forward-only cleanup; the server has no code path that can process
-- these rows after the SpellCast/SpellConsumed EventType variants are removed.

DELETE FROM events WHERE type IN ('spell.cast', 'spell.consumed');
