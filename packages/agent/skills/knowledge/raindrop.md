# Raindrop.io Integration

Process bookmarks from Raindrop.io into the wiki. Raindrop is the **source backbone** — the canonical reference library that wiki pages link back to.

Read WIKI_SCHEMA before starting. Paths are defined in the skill's Paths table.

---

## Setup

- **Account:** User's existing Raindrop.io account
- **Auth:** Test token from Raindrop.io → Settings → Integrations → "For Developers"
- **Token storage:** `~/.tron/skills/vault/scripts/vault.sh set raindrop-api --type api_key --desc "Raindrop.io API test token" --tags "raindrop,knowledge,wiki" --field token=<test-token>`
- **Monitored collection:** Unsorted (collection ID `0`)
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

### Step 1: Fetch unsorted bookmarks

```bash
curl -s -H "Authorization: Bearer $TOKEN" \
  "https://api.raindrop.io/rest/v1/raindrops/0?perpage=25&sort=-created" \
  | jq '.items[] | select(.tags | index("wiki-ingested") | not) | {id: ._id, title: .title, url: .link, tags: .tags, created: .created}'
```

Fetches the 25 most recent unsorted bookmarks not yet ingested (no `wiki-ingested` tag).

### Step 2: Process each bookmark (max 10 per run)

For each unprocessed bookmark:

1. **Fetch content:** WebFetch the bookmark URL

2. **Deep extraction:** Follow `ingest.md` Extract mode:
   - Create source note in WIKI_SOURCES with `raindrop_id` and `raindrop_collection` in frontmatter
   - Transfer Raindrop tags to note's `tags` field
   - Create/update wiki pages in WIKI_PAGES for key concepts
   - Cross-link selectively with existing wiki pages

3. **Tag in Raindrop:** Mark as processed. Preserve existing tags, add `wiki-ingested`:

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

### Step 3: Update state

Write to `AUTOMATIONS/raindrop-ingest/state/last_seen.json`:

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
2026-04-07T16:00:00Z | raindrop | source | 2026-04-07-author-title | Raindrop ID: 12345678
2026-04-07T16:00:00Z | raindrop | wiki | concept-slug | From raindrop ingest
```

Git commit:
```bash
cd WIKI_ROOT && git add -A && git commit -m "wiki: raindrop — processed N bookmarks"
```

### Step 5: Report

1. Bookmarks processed (count)
2. Notes created/updated (list with paths)
3. Bookmarks skipped (already tagged, fetch failed)
4. Errors encountered

---

## Automation (Cron)

A cron job in `AUTOMATIONS/automations.json` runs this workflow every 4 hours. The AgentTurn prompt instructs the agent to:

1. Read WIKI_SCHEMA
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

Collection `0` = Unsorted. All requests need `Authorization: Bearer <token>` header.

---

## Error Handling

| Error | Recovery |
|---|---|
| 401 Unauthorized | Token expired/invalid. Ask user to regenerate and re-store in vault. |
| 429 Rate Limited | Raindrop limits ~120 req/min. The 10-bookmark cap keeps well under this. |
| WebFetch failure | Skip the bookmark, log the error, continue. Don't tag it as ingested. |
| Network failure | Stop the run, preserve state. Next run picks up. |
| Vault token missing | Write error to output file and exit. Don't ask for input (cron runs unattended). |

## Gotchas
