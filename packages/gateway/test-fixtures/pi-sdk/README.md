# Pi session compatibility fixtures

These immutable JSONL files are hand-authored, minimal public Pi session
corpora. `v1.jsonl` exercises the legacy implicit parent chain and
`firstKeptEntryIndex`; `v2.jsonl` exercises explicit tree IDs plus the legacy
`hookMessage` role; `v3.jsonl` is the current canonical equivalent. The rollback
probe additionally writes and rereads 0.99-only payloads through Pi's public
`SessionManager` APIs: `codemode-store`, virtual-model state and `model_change`,
tool-search loadout deltas, canonical `nestedCalls`, and parent `details.tronNested`.
It checks that both 0.99 and the 0.87.1 reader preserve the JSONL entries,
parent result content and structured content through read/append/reopen cycles.
Files are isolated in disposable directories; they are not a Tron session format.
