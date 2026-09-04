# Pi session compatibility fixtures

These immutable JSONL files are hand-authored, minimal public Pi session
corpora. `v1.jsonl` exercises the legacy implicit parent chain and
`firstKeptEntryIndex`; `v2.jsonl` exercises explicit tree IDs plus the legacy
`hookMessage` role; `v3.jsonl` is the current canonical equivalent. Tests copy
fixtures to a temporary directory and only let Pi's public `SessionManager.open`
read or rewrite them. They are not a Tron session format.
