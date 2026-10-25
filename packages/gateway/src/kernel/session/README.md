# gateway/session-catalog — canonical reads

K1 owns `canonical-reader.ts`: bounded read-only canonical JSONL inspection.
It never opens the SDK's repairing/migrating SessionManager.

- `readCanonicalSession` returns the last complete branch and reports a torn tail;
  a source parse failure is translated only when its snapshot changed.
- `visitCanonicalSessionEntries` uses `O_NOFOLLOW`, streams the initial byte cut,
  refuses an incomplete tail and retains the visitor's error.
- `readCanonicalSessionFile` uses `O_NOFOLLOW`, requires current-format complete
  file-wide evidence with ordered parents and a matching final snapshot.
- Prefix and line digests are the shared SHA-256 rules used by Home's incremental
  source. That source's cursors and message projection remain Episodic-owned.

All variants retain their own open/close, header, byte-bound and error contracts.
`errors.ts` supplies the shared refusal class; K4 `prompt-bounds.ts` supplies the
producer-derived default line budget. Neither reader mirrors module policy.

The existing session-catalog manifest at `src/session-catalog.module.json` owns
these readers and the catalog files still under `sessions/`.

## Verify

```bash
scripts/tron test gateway src/episodic/home-source.e2e.test.ts \
  src/episodic/episodic-memory.e2e.test.ts
```
