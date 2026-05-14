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
2. If the user says 'raindrop' with no collection specified, use agent::ask_user to ask: 'Which Raindrop collection should I process? (e.g., Unsorted, AI Research, or a specific collection name)'
3. Support processing from any collection, not just Unsorted.
4. Track state per collection: `AUTOMATIONS/raindrop-ingest/state/{collection-slug}-last_seen.json`

```bash
# Resolve collection ID (0 = Unsorted, or look up by name)
curl -s -H "Authorization: Bearer $TOKEN" \
  "https://api.raindrop.io/rest/v1/raindrops/$COLLECTION_ID?perpage=25&sort=-created" \
  | jq '.items[] | select(.tags | map(startswith("wiki-")) | any | not) | {id: ._id, title: .title, url: .link, tags: .tags, note: .note, created: .created}'
```

Fetches the 25 most recent bookmarks from the selected collection not yet processed. Any bookmark with a `wiki-` prefixed tag is skipped — this covers `wiki-ingested`, `wiki-error`, and any future status tags. The `note` field is included — it may contain user guidance on what to focus on or why the link was saved.

### Step 2: Process each bookmark (max 10 per run)

For each unprocessed bookmark:

1. **Check the `note` field first.** The user may have written a note on the bookmark in Raindrop to indicate what they found interesting or what to focus on. If a note exists, it guides the entire extraction — treat it as the user's intent for this link.

2. **Fetch content.** Use the appropriate method per `ingest.md` Extract mode (web::fetch for articles, the Twitter skill's fxtwitter API for X/Twitter links, etc.)

3. **Decide the ingestion path** based on what you got back:

   **Path A — Extractable content exists:** Follow `ingest.md` Extract mode fully. If the bookmark has a note, use it to guide what to emphasize in the source note and which topics to create/update. Without a note, extract normally.

   **Path B — No extractable content** (landing page, SaaS homepage, login wall, empty/script-only response): Save as a **reference source note**. This is the default for links with no readable content — don't treat it as an error.

   Reference source note format:
   ```markdown
   ---
   type: source
   url: "https://..."
   source_type: reference
   tags: [from-raindrop-tags]
   raindrop_id: 12345678
   raindrop_collection: "Collection Name"
   created: "YYYY-MM-DD"
   updated: "YYYY-MM-DD"
   ---

   # {Title from Raindrop}

   ## What This Is

   {Brief description from the page title, domain, and any available metadata.
   If the bookmark has a note, incorporate the user's context here.}
   ```

   Reference notes are still tagged `wiki-ingested` in Raindrop (not `wiki-error`) — the link was successfully processed, it just didn't have article content to extract.

4. **Common to both paths:**
   - Create source note in WIKI_SOURCES with `raindrop_id` and `raindrop_collection` in frontmatter
   - Transfer Raindrop tags to note's `tags` field
   - Create/update topic notes in WIKI_TOPICS for key concepts (Path A) or relevant existing topics (Path B, if the note provides enough context)
   - Cross-link selectively with existing topic notes

5. **Tag in Raindrop:** Mark the bookmark based on outcome.

   **CRITICAL — tag discipline:** The agent may add EXACTLY ONE tag to a bookmark, and it must be either `wiki-ingested` (on success/reference) or `wiki-error` (on failure). Never add any other tag — not the source-note slug, not topic slugs, not categorization tags, nothing. All existing tags on the bookmark (including tags the user added in Raindrop) must be preserved unchanged. The merge is: `existing_tags ∪ {status_tag}` where `status_tag ∈ {wiki-ingested, wiki-error}`.

**On success** — add `wiki-ingested`:

```bash
# Read current bookmark to get existing tags
EXISTING=$(curl -s -H "Authorization: Bearer $TOKEN" \
  "https://api.raindrop.io/rest/v1/raindrop/<id>" \
  | jq -c '.item.tags')

# Merge tags: existing + wiki-ingested (NEVER add any other tag)
curl -s -X PUT -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"tags": <merged_tags_array>}' \
  "https://api.raindrop.io/rest/v1/raindrop/<id>"
```

**On error** (network failure, HTTP 5xx, PDF extraction crash, etc.) — add `wiki-error` and append the reason to the bookmark's note (preserve the user's existing note):

```bash
# Merge tags: existing + wiki-error (NEVER add any other tag). Append error to note, preserving user's original.
curl -s -X PUT -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"tags": <merged_tags_with_wiki_error>, "note": "<existing note>\n\nwiki-error: <reason>"}' \
  "https://api.raindrop.io/rest/v1/raindrop/<id>"
```

Error examples:
- `"wiki-error: Network failure — connection refused"`
- `"wiki-error: PDF extraction failed — <details>"`
- `"wiki-error: Timeout — page did not respond within fetch window"`

**Not errors** — these are handled as reference notes (Path B in Step 2):
- Landing pages, SaaS homepages, login walls, JS-rendered pages with no content
- These get `wiki-ingested`, not `wiki-error`

A stub source note should still be created in WIKI_SOURCES for true errors with `ingest_status: "blocked"` and the `blocker` field describing the error — see `ingest.md`.

### Step 3: Update state

Write to `AUTOMATIONS/raindrop-ingest/state/{collection-slug}-last_seen.json`:

```json
{
  "last_timestamp": "2026-04-07T10:00:00Z",
  "last_id": "12345678",
  "processed_count": 7
}
```

This is an **optimization** — it lets subsequent runs skip pages already seen. The `wiki-` prefixed tags in Raindrop are the true idempotency guard. If this file is lost, nothing gets re-ingested.

### Step 4: Epilogue

Update WIKI_INDEX, append to WIKI_LOG:

```
2026-04-07T16:00:00Z | raindrop | source | 2026-04-07-author-title | Raindrop ID: 12345678 — full extraction
2026-04-07T16:00:00Z | raindrop | source | 2026-04-07-paperspace | Raindrop ID: 12345679 — reference (no extractable content)
2026-04-07T16:00:00Z | raindrop | source | 2026-04-07-author-title | Raindrop ID: 12345680 — BLOCKED: network failure
2026-04-07T16:00:00Z | raindrop | topic | concept-slug | From raindrop ingest
```

Git commit:
```bash
cd WIKI_ROOT && git add -A && git commit -m "knowledge: raindrop — processed N bookmarks"
```

### Step 5: Report

1. Bookmarks fully ingested (count + list with source note paths)
2. Bookmarks saved as references (count + list — no extractable content)
3. Topic notes created/updated (list with what was added)
4. Bookmarks that errored (count + list with bookmark title, URL, and error reason)
5. Bookmarks skipped (already tagged with any `wiki-` prefix)

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
| No extractable content (landing page, SaaS homepage, login wall, JS-only) | Save as reference source note (Path B). Tag `wiki-ingested`. Not an error. |
| True fetch failure (network error, HTTP 5xx, timeout, PDF crash) | Tag bookmark `wiki-error` with reason appended to note. Create stub source note with `ingest_status: "blocked"`. Log to WIKI_LOG. Continue to next bookmark. |
| Network failure | Stop the run, preserve state. Next run picks up. |
| Vault token missing | Write error to output file and exit. Don't ask for input (cron runs unattended). |

### Retrying errors

Any bookmark with a `wiki-` prefixed tag is skipped in normal runs. To retry an errored bookmark:
1. Remove the `wiki-error` tag from the bookmark in Raindrop (manually or via API)
2. The next run will pick it up as unprocessed
3. If the underlying issue persists (e.g., site still requires JS), it will be re-tagged `wiki-error`

## Gotchas

- **Only `wiki-ingested` or `wiki-error` may be added as tags.** Do not tag bookmarks with source-note slugs, topic slugs, content categories, or anything else. The `wiki-` prefix is reserved for skill-owned status tags and is the sole mechanism for the idempotency guard (Step 1 filters bookmarks whose tags include any `wiki-` prefixed tag). Adding other tags pollutes the user's Raindrop taxonomy and has no functional value — the source note in the wiki is where categorization lives.
