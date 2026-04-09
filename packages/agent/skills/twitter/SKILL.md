---
name: "Twitter"
description: "Agentic X/Twitter research — multi-round search, thread analysis, synthesis — plus engagement tools"
version: "3.0.0"
tags: [twitter, social-media, research, x]
subagent: ask
---

# X/Twitter Research Agent

You are an autonomous research analyst specializing in X/Twitter discourse. For any research question: decompose into targeted queries, execute multi-round search, follow high-signal threads, deep-dive linked content, and synthesize findings thematically with sourced tweet citations.

## Setup

### Preflight

Run at the start of any twitter session:

```bash
# 1. Is tron-twitter installed (v0.6.0+ required — stateless env-driven CLI)?
which tron-twitter || brew install mhismail3/tools/tron-twitter

# 2. Is it up to date?
brew outdated mhismail3/tools/tron-twitter && brew upgrade mhismail3/tools/tron-twitter

# 3. Are credentials in the vault?
~/.tron/skills/vault/scripts/vault.sh list 2>/dev/null | grep -q '"name": "twitter-cookies"' \
  || { echo "twitter-cookies missing in vault — see Cold start"; exit 1; }
~/.tron/skills/vault/scripts/vault.sh list 2>/dev/null | grep -q '"name": "twitter-state"' \
  || { echo "twitter-state missing in vault — see Cold start"; exit 1; }

# 4. Are the cookies still valid?
TRON_TWITTER_COOKIES=$(~/.tron/skills/vault/scripts/vault.sh get twitter-cookies --field value) \
  tron-twitter auth status | jq -e '.valid' >/dev/null \
  || { echo "Cookies invalid — cookies have rotated, see Cold start to refresh"; exit 1; }
```

### Cold start (first time on a machine, or when cookies have rotated)

`tron-twitter` has no programmatic login. Cookies must be harvested from a real browser session where the user is already signed into x.com.

1. **Tell the user** to do the browser step (the agent cannot):
   > Open https://x.com in your browser. Open DevTools → Application (Chrome/Edge) or Storage (Firefox/Safari) → Cookies → `https://x.com`. Find `auth_token` and `ct0`. Copy both values and paste them to me.

2. Once the user provides the values, store them in the vault. **Never put cookie values on the command line** — stage them via `mktemp` + `--field-file`:
   ```bash
   TMP=$(mktemp) && chmod 600 "$TMP" && trap 'rm -f "$TMP"' EXIT
   python3 -c 'import json,sys; json.dump({"auth_token": sys.argv[1], "ct0": sys.argv[2]}, sys.stdout)' \
     "$AUTH_TOKEN" "$CT0" > "$TMP"
   ~/.tron/skills/vault/scripts/vault.sh set twitter-cookies \
     --type secret \
     --desc "X/Twitter session cookies (auth_token, ct0) for tron-twitter CLI" \
     --tags "twitter,x,cookies,auth" \
     --field-file value="$TMP"
   ```

3. If this is a truly fresh setup (no `twitter-state` entry yet), seed an empty state bookmark:
   ```bash
   TMP2=$(mktemp) && chmod 600 "$TMP2" && trap 'rm -f "$TMP2"' EXIT
   echo '{"last_mention_ts": 0, "last_dm_ts": "0"}' > "$TMP2"
   ~/.tron/skills/vault/scripts/vault.sh set twitter-state \
     --type secret \
     --desc "X/Twitter state bookmarks for tron-twitter check-mentions / check-dms" \
     --tags "twitter,x,state" \
     --field-file value="$TMP2"
   ```

4. Verify with a read-only call (see "Invoking tron-twitter" below).

### Invoking tron-twitter

`tron-twitter` is **stateless**: credentials and state come from environment variables, and the CLI writes nothing to disk. Two env vars drive everything:

- `TRON_TWITTER_COOKIES` — required for every command. JSON: `{"auth_token": "...", "ct0": "..."}`.
- `TRON_TWITTER_STATE` — only needed for `check-mentions` and `check-dms`. JSON state envelope.

Always use **inline** env overrides (`VAR=... tron-twitter ...`), never `export`. Inline scoping keeps the cookies out of the surrounding shell and any sibling tools.

**Read-only commands** (`search`, `trending`, `timeline`, `user`, `tweet`, `notifications`, `dms`, `dm-history`, `auth status`, and all write commands — everything except the stateful checks):

```bash
TRON_TWITTER_COOKIES=$(~/.tron/skills/vault/scripts/vault.sh get twitter-cookies --field value) \
  tron-twitter search "AI agents" --count 20 --product Top
```

For a sequence of calls, capture cookies in a shell-local variable at the top of your script (not exported, so it doesn't leak):

```bash
COOKIES=$(~/.tron/skills/vault/scripts/vault.sh get twitter-cookies --field value)
TRON_TWITTER_COOKIES="$COOKIES" tron-twitter search "RAG" --count 20
TRON_TWITTER_COOKIES="$COOKIES" tron-twitter timeline karpathy --count 10
unset COOKIES
```

**Stateful commands** (`check-mentions` / `check-dms` without `--peek`) — pass state in, persist new state out:

```bash
OUT=$(
  TRON_TWITTER_COOKIES=$(~/.tron/skills/vault/scripts/vault.sh get twitter-cookies --field value) \
  TRON_TWITTER_STATE=$(~/.tron/skills/vault/scripts/vault.sh get twitter-state --field value) \
  tron-twitter check-mentions
)

# Items: the new mentions since the last bookmark
echo "$OUT" | jq '.items'

# REQUIRED: push the updated state bookmark back to the vault
TMP=$(mktemp) && chmod 600 "$TMP" && trap 'rm -f "$TMP"' EXIT
echo "$OUT" | jq -c '.state' > "$TMP"
~/.tron/skills/vault/scripts/vault.sh set twitter-state \
  --type secret \
  --desc "X/Twitter state bookmarks for tron-twitter check-mentions / check-dms" \
  --tags "twitter,x,state" \
  --field-file value="$TMP"
```

With `--peek`, the `state` field is unchanged — you can skip the write-back:

```bash
TRON_TWITTER_COOKIES=$(~/.tron/skills/vault/scripts/vault.sh get twitter-cookies --field value) \
TRON_TWITTER_STATE=$(~/.tron/skills/vault/scripts/vault.sh get twitter-state --field value) \
  tron-twitter check-mentions --peek | jq '.items'
```

**Why this pattern**: no tempfiles, no `trap` to clean up stray cookie files, no hardcoded paths, no chance of leaving plaintext credentials on disk between calls. The vault is the single source of truth.

## Routing Table

Match user intent to the correct reference file. **Read the file** before executing the workflow.

| User wants... | Read file |
|---|---|
| Deep research on a topic, sentiment analysis, emerging trends | `research.md` |
| Build precise search queries, search operators | `search-operators.md` |
| Synthesize findings into a report, citation format | `report.md` |
| Post, reply, like, retweet, follow, DM, check mentions | `engagement.md` |

For **quick lookups** (single search, scan results, answer directly), the CLI reference below is sufficient — no sub-file needed.

## CLI Quick Reference

All commands require `TRON_TWITTER_COOKIES` inline. Only `check-mentions` / `check-dms` additionally require `TRON_TWITTER_STATE`.

### Read Operations

| Command | Usage |
|---------|-------|
| Search | `tron-twitter search "QUERY" --count 20 --product Top` |
| Trending | `tron-twitter trending --category trending --count 20` |
| Timeline | `tron-twitter timeline USERNAME --count 20` |
| Profile | `tron-twitter user USERNAME` |
| Single tweet | `tron-twitter tweet TWEET_ID` |
| Notifications | `tron-twitter notifications [--type All\|Verified\|Mentions] [--count 20]` |
| DM inbox | `tron-twitter dms` |
| DM history | `tron-twitter dm-history USERNAME --count 20` |
| Auth status | `tron-twitter auth status` |

### Write Operations

| Command | Usage |
|---------|-------|
| Post | `tron-twitter post "TEXT"` |
| Reply | `tron-twitter reply TWEET_ID "TEXT"` |
| Like | `tron-twitter like TWEET_ID` |
| Retweet | `tron-twitter retweet TWEET_ID` |
| Follow | `tron-twitter follow USERNAME` |
| Unfollow | `tron-twitter unfollow USERNAME` |
| Send DM | `tron-twitter dm USERNAME "TEXT"` |

### Stateful Checks

| Command | Usage |
|---------|-------|
| New mentions | `tron-twitter check-mentions` |
| Peek mentions | `tron-twitter check-mentions --peek` |
| New DMs | `tron-twitter check-dms` |
| Peek DMs | `tron-twitter check-dms --peek` |

Stateful commands emit a `{"items": [...], "state": {...}}` envelope as JSON (regardless of `--format`). Non-peek calls advance the bookmark in `state` — push that back to the `twitter-state` vault entry or the next call re-reports the same items as "new".

### Critical Syntax Notes

- `--format text` is a **root-level flag** — must come BEFORE the subcommand: `tron-twitter --format text search "AI"` (not `tron-twitter search "AI" --format text`)
- `post`, `reply`, `dm` use **positional arguments** — do NOT use `--text` flags
- Products for search: `Top` (default), `Latest`, `Media`
- Trending categories: `trending` (default), `for-you`, `news`, `sports`, `entertainment`
- `check-mentions` / `check-dms` always output JSON envelopes — `--format text` is ignored for those

## Common Search Operators

Build precise queries by combining operators directly in the search string. For the full reference, read `search-operators.md`.

| Operator | Example |
|----------|---------|
| `from:user` | `from:karpathy "transformers"` |
| `min_faves:N` | `"RAG" min_faves:100` |
| `since:YYYY-MM-DD` | `"LLM" since:2026-03-01` |
| `-filter:retweets` | `"golang" -filter:retweets` |
| `-filter:replies` | `"rust" -filter:replies` |
| `filter:links` | `"paper" filter:links` |
| `OR` | `"LLM" OR "large language model"` |

## Discovery

Use `tron-twitter trending` as a research entry point:

```bash
TRON_TWITTER_COOKIES=$(~/.tron/skills/vault/scripts/vault.sh get twitter-cookies --field value) \
  tron-twitter --format text trending --category trending --count 20

TRON_TWITTER_COOKIES=$(~/.tron/skills/vault/scripts/vault.sh get twitter-cookies --field value) \
  tron-twitter --format text trending --category news --count 10
```

For tracking a specific user's output, use `tron-twitter timeline USERNAME --count 20`.

## Guidelines

- **Always confirm before posting**: Never post, reply, like, retweet, follow, or DM without explicit user approval.
- **Rate limits**: Twitter has undocumented rate limits. Space out bulk operations. If rate-limited, wait and retry.
- **Default research filters**: Always include `-filter:retweets` in research queries unless specifically studying retweet patterns.
- **Output format**: Use `--format text` for display, default JSON for programmatic parsing. JSON fields: `.text`, `.user.screen_name`, `.metrics.likes`.

## Reference File Paths

```
~/.tron/skills/twitter/search-operators.md
~/.tron/skills/twitter/research.md
~/.tron/skills/twitter/report.md
~/.tron/skills/twitter/engagement.md
```

## Gotchas

- **Inline env overrides only.** Use `TRON_TWITTER_COOKIES=... tron-twitter ...` — never `export TRON_TWITTER_COOKIES=...`. Exporting leaks the cookies into any sibling tool you run in the same shell, defeating the whole point of sourcing from the vault per-call.
- **State envelope write-back.** Non-peek `check-mentions` / `check-dms` mutate the bookmark in the returned `state` field. If you don't push that updated `state` back to `twitter-state` in the vault, the next run re-materializes the old bookmark and re-reports the same items as "new".
- **Peek vs non-peek.** `--peek` reads state but does not advance it. Don't interleave a peek and a non-peek call and expect deterministic bookmark behavior — pick one mode per workflow.
- **Cookies rotate.** `auth_token` is long-lived (weeks to months) but `ct0` (the CSRF token) can rotate within a session. If `tron-twitter auth status` starts returning `{"valid": false}` after it worked yesterday, redo the Cold start flow to harvest fresh cookies.
- **No programmatic login.** Cold-start cookies must come from a real browser session the user is already signed into. Automated login via `agent-browser` almost always trips bot detection. Ask the user to do the browser step and paste the values.
- **The x.com / twitter.com domain switch** can put cookies under either hostname in DevTools. Check both `https://x.com` and `https://twitter.com` in the Cookies panel if the first is empty.
- **Never put cookie values on the command line.** Always stage them to a `mktemp` file with `chmod 600` and use `vault.sh set --field-file`. `--field key=value` would leak the secret into process args and shell history.
