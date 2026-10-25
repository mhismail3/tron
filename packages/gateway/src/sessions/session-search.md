# Session search

## Purpose

Search ordinary canonical conversations without making the disposable SQLite
index an authority over admitted source bytes or Home history.

## Owns

The search coordinator, bounded SQLite index, text derivation, embedding client
and search request/result values. Registry owns canonical cuts and invalidation;
Home owns its chapter history and tool admission.

## Public surface

`SessionSearchService.search` returns current source anchors and redacted
passages. `warm` rebuilds disposable rows; `close` cancels warmup and joins index
work before closing SQLite. A caller's abort cancels its wait, not that owner.

## Dependencies

The real Registry/Pi source and catalog cuts, SQLite, credential redaction and
an optional embedding provider. No second transcript mirror or search cache is
canonical. Editing an open session goes through its existing SDK owner.

## Failure and lifecycle

Every candidate is checked against a fresh admitted cut, including after
embedding I/O. Edited, omitted or excluded passages cannot acquire citations
from stale index rows. Home chapters stay on Home's native memory route.
Reopening an index derives current text instead of publishing a retired branch.

## Verify

`scripts/tron verify --module gateway/session-search` selects the persisted-store
lock, query-cancellation/reopen lock, and existing Home research/legacy journeys
through the manifest's explicit consumer declarations. Those unchanged real
Home tools prove edited citations, redacted persisted results, chapter exclusion
and preserved historical citations. No scheduler or Home fixture is duplicated.
The cancellation lock records `test-results/session-search-retirement/trace.json`
from a real Registry/Pi session and SQLite index with a faux embedding provider.
