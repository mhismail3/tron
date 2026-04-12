# Raindrop.io Integration

Process bookmarks from Raindrop.io into the knowledge base. Raindrop is the **source backbone** — the canonical reference library that topic notes link back to.

Read WIKI_RULES before starting. Paths are defined in the skill's Paths table.

---

## Setup

- **Account:** User's existing Raindrop.io account
- **Auth:** Test token from Raindrop.io → Settings → Integrations → "For Developers"
- **Token storage:** `~/.tron/skills/vault/scripts/vault.sh set raindrop-api --type api_key --desc "Raindrop.io API test token" --tags "raindrop,knowledge,wiki" --field token=<test-token>`
- **Monitored collection:** Any collection (resolved dynamically)
- **API base:** `https://api.raindrop.io/rest/v1`

## Credentials

```bash
TOKEN=$(~/.tron/skills/vault/scripts/vault.sh get raindrop-api --field token)
```

If not found, tell the user:
1. Go to Raindrop.io → Settings → Integrations → "For Developers"
2. Create a test token
3. Run: `~/.tron/skills/vault/scripts/vault.sh set raindrop-api --type api_key --field token=<token>`

---

## Workflow

### Step 1: Resolve collection and fetch bookmarks

**Collection selection:**
1. If the user specifies a collection name (e.g., 'raindrop AI Research'), resolve the collection ID via the Raindrop API: `GET https://api.raindrop.io/rest/v1/collections` with Bearer token, find the collection by title.
2. If the user says 'raindrop' with no collection specified, use AskUserQuestion to ask: 'Which Raindrop collection should I process? (e.g., Unsorted, AI Research, or a specific collection name)'
3. Support processing from any collection, not just Unsorted.
4. Track state per collection: `AUTOMATIONS/raindrop-ingest/state/{collection-slug}-last_seen.json`

```bash
# Resolve collection ID (0 = Unsorted, or look up by name)
curl -s -H "Authorization: Bearer $TOKEN" \
  "https://api.raindrop.io/rest/v1/raindrops/$COLLECTION_ID?perpage=25&sort=-created" \
  | jq '.items[] | select((.tags | index("wiki-ingested") | not) and (.tags | index("wiki-error") | not)) | {id: ._id, title: .title, url: .link, tags: .tags, created: .created}'
```

Fetches the 25 most recent bookmarks from the selected collection not yet processed (no `wiki-ingested` or `wiki-error` tag).

### Step 2: Process each bookmark (max 10 per run)

For each unprocessed bookmark:

1. **Fetch content:** WebFetch the bookmark URL

2. **Deep extraction:** Follow `ingest.md` Extract mode:
   - Create source note in WIKI_SOURCES with `raindrop_id` and `raindrop_collection` in frontmatter
   - Transfer Raindrop tags to note's `tags` field
   - Create/update topic notes in WIKI_TOPICS for key concepts
   - Cross-link selectively with existing topic notes

3. **Tag in Raindrop:** Mark the bookmark based on outcome. Preserve existing tags.

**On success** — add `wiki-ingested`:

```bash
# Read current bookmark to get existing tags
EXISTING=$(curl -s -H "Authorization: Bearer $TOKEN" \
  "https://api.raindrop.io/rest/v1/raindrop/<id>" \
  | jq -c '.item.tags')

# Merge tags: existing + wiki-ingested + source-note-slug
curl -s -X PUT -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"tags": <merged_tags_array>}' \
  "https://api.raindrop.io/rest/v1/raindrop/<id>"
```

**On error** (WebFetch failure, JS-rendered page, login wall, etc.) — add `wiki-error` and write a note in the bookmark:

```bash
# Merge tags: existing + wiki-error
curl -s -X PUT -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"tags": <merged_tags_with_wiki_error>, "note": "<error reason>"}' \
  "https://api.raindrop.io/rest/v1/raindrop/<id>"
```

The `note` field should contain a concise error description, e.g.:
- `"wiki-error: JS-rendered page — WebFetch returned empty/script-only content"`
- `"wiki-error: Login required — page returned 403 or login redirect"`
- `"wiki-error: PDF extraction failed — <details>"`
- `"wiki-error: Timeout — page did not respond within fetch window"`

This persists the failure reason in Raindrop itself so it's visible when browsing bookmarks and queryable for later retry or tooling improvements. A stub source note should still be created in WIKI_SOURCES with `ingest_status: "blocked"` and the `blocker` field describing the error — see `ingest.md`.

### Step 3: Update state

Write to `AUTOMATIONS/raindrop-ingest/state/{collection-slug}-last_seen.json`:

```json
{
  "last_timestamp": "2026-04-07T10:00:00Z",
  "last_id": "12345678",
  "processed_count": 7
}
```

This is an **optimization** — it lets subsequent runs skip pages already seen. The `wiki-ingested` tag in Raindrop is the true idempotency guard. If this file is lost, nothing gets re-ingested.

### Step 4: Epilogue

Update WIKI_INDEX, append to WIKI_LOG:

```
2026-04-07T16:00:00Z | raindrop | source | 2026-04-07-author-title | Raindrop ID: 12345678 — full extraction
2026-04-07T16:00:00Z | raindrop | source | 2026-04-07-author-title | Raindrop ID: 12345679 — BLOCKED: JS-rendered page
2026-04-07T16:00:00Z | raindrop | topic | concept-slug | From raindrop ingest
```

Git commit:
```bash
cd WIKI_ROOT && git add -A && git commit -m "knowledge: raindrop — processed N bookmarks"
```

### Step 5: Report

1. Bookmarks successfully ingested (count + list with source note paths)
2. Topic notes created/updated (list with what was added)
3. Bookmarks that errored (count + list with bookmark title, URL, and error reason)
4. Bookmarks skipped (already tagged `wiki-ingested` or `wiki-error`)

---

## Automation (Cron)

A cron job in `AUTOMATIONS/automations.json` runs this workflow every 4 hours. The AgentTurn prompt instructs the agent to:

1. Read WIKI_RULES
2. Read `~/.tron/skills/knowledge/raindrop.md` (this file)
3. Execute the workflow above
4. Write a summary to `AUTOMATIONS/raindrop-ingest/output/YYYY-MM-DD_HH-MM-SS.md`

This two-level indirection (cron → skill file → schema) means the cron prompt is stable. The schema and workflow evolve independently without touching the cron entry.

---

## API Reference

| Endpoint | Method | Description |
|---|---|---|
| `/rest/v1/raindrops/{collectionId}` | GET | List bookmarks. Params: `perpage` (max 40), `page` (0-indexed), `sort` |
| `/rest/v1/raindrop/{id}` | GET | Get single bookmark |
| `/rest/v1/raindrop/{id}` | PUT | Update bookmark (tags, collection, etc.) |
| `/rest/v1/collections` | GET | List all collections |
| `/rest/v1/tags/0` | GET | List all tags |

Collection `0` = Unsorted. Use `/rest/v1/collections` to resolve collection names to IDs. All requests need `Authorization: Bearer <token>` header.

---

## Error Handling

| Error | Recovery |
|---|---|
| 401 Unauthorized | Token expired/invalid. Ask user to regenerate and re-store in vault. |
| 429 Rate Limited | Raindrop limits ~120 req/min. The 10-bookmark cap keeps well under this. |
| WebFetch failure (JS-rendered, login wall, timeout, etc.) | Tag bookmark `wiki-error` with reason in `note` field. Create stub source note with `ingest_status: "blocked"`. Log to WIKI_LOG. Continue to next bookmark. |
| Network failure | Stop the run, preserve state. Next run picks up. |
| Vault token missing | Write error to output file and exit. Don't ask for input (cron runs unattended). |

### Retrying errors

Bookmarks tagged `wiki-error` are skipped in normal runs. To retry them:
1. Remove the `wiki-error` tag from the bookmark in Raindrop (manually or via API)
2. The next run will pick it up as unprocessed
3. If the underlying issue persists (e.g., site still requires JS), it will be re-tagged `wiki-error`

## Gotchas
