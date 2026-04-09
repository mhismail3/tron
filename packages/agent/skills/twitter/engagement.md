# Engagement

All write operations require **explicit user approval** before execution. Draft content first, show it to the user, and only execute after confirmation.

All commands require `TRON_TWITTER_COOKIES` inline. See `SKILL.md` → "Invoking tron-twitter" for the full pattern.

## Posting

```bash
TRON_TWITTER_COOKIES=$(~/.tron/skills/vault/scripts/vault.sh get twitter-cookies --field value) \
  tron-twitter post "TEXT"                              # New tweet

TRON_TWITTER_COOKIES=$(~/.tron/skills/vault/scripts/vault.sh get twitter-cookies --field value) \
  tron-twitter reply TWEET_ID "TEXT"                    # Reply to tweet
```

`TEXT` is a positional argument — do NOT use `--text` flags.

## Social Actions

```bash
COOKIES=$(~/.tron/skills/vault/scripts/vault.sh get twitter-cookies --field value)
TRON_TWITTER_COOKIES="$COOKIES" tron-twitter like TWEET_ID
TRON_TWITTER_COOKIES="$COOKIES" tron-twitter retweet TWEET_ID
TRON_TWITTER_COOKIES="$COOKIES" tron-twitter follow USERNAME
TRON_TWITTER_COOKIES="$COOKIES" tron-twitter unfollow USERNAME
unset COOKIES
```

## Direct Messages

```bash
COOKIES=$(~/.tron/skills/vault/scripts/vault.sh get twitter-cookies --field value)
TRON_TWITTER_COOKIES="$COOKIES" tron-twitter dms                         # List conversations
TRON_TWITTER_COOKIES="$COOKIES" tron-twitter dm-history USERNAME --count 20   # Read conversation
TRON_TWITTER_COOKIES="$COOKIES" tron-twitter dm USERNAME "TEXT"          # Send message
unset COOKIES
```

`USERNAME` and `TEXT` are positional arguments.

## Monitoring

`check-mentions` / `check-dms` are stateful. Cookies **and** state come in via env vars; the new state comes back in a JSON envelope that you must persist to the vault.

Use `--peek` to preview without advancing the bookmark:

```bash
TRON_TWITTER_COOKIES=$(~/.tron/skills/vault/scripts/vault.sh get twitter-cookies --field value) \
TRON_TWITTER_STATE=$(~/.tron/skills/vault/scripts/vault.sh get twitter-state --field value) \
  tron-twitter check-mentions --peek | jq '.items'

TRON_TWITTER_COOKIES=$(~/.tron/skills/vault/scripts/vault.sh get twitter-cookies --field value) \
TRON_TWITTER_STATE=$(~/.tron/skills/vault/scripts/vault.sh get twitter-state --field value) \
  tron-twitter check-dms --peek | jq '.items'
```

Without `--peek`, the bookmark advances and you **must** push the updated state back to the vault or the next call re-reports the same items as "new":

```bash
OUT=$(
  TRON_TWITTER_COOKIES=$(~/.tron/skills/vault/scripts/vault.sh get twitter-cookies --field value) \
  TRON_TWITTER_STATE=$(~/.tron/skills/vault/scripts/vault.sh get twitter-state --field value) \
  tron-twitter check-mentions
)
echo "$OUT" | jq '.items'                # New mentions

# REQUIRED: write-back the updated bookmark
TMP=$(mktemp) && chmod 600 "$TMP" && trap 'rm -f "$TMP"' EXIT
echo "$OUT" | jq -c '.state' > "$TMP"
~/.tron/skills/vault/scripts/vault.sh set twitter-state \
  --type secret \
  --desc "X/Twitter state bookmarks for tron-twitter check-mentions / check-dms" \
  --tags "twitter,x,state" \
  --field-file value="$TMP"
```

Same write-back pattern applies to `tron-twitter check-dms` without `--peek`.

## Gotchas

- **Confirm before posting.** `post`, `reply`, `like`, `retweet`, `follow`, `dm` are user-visible actions — never execute without explicit user approval, even inside a larger workflow.
- **Inline env overrides only.** Never `export TRON_TWITTER_COOKIES` — leaks cookies into sibling processes. Use `VAR=... tron-twitter ...` per-call (or a shell-local `COOKIES=$(...)` variable inside a tightly-scoped block that you `unset` at the end).
- **Forgetting the state write-back** on non-peek `check-mentions` / `check-dms` is the easiest way to silently re-notify on old mentions. If you see the same items twice, the write-back step was skipped.
- **Don't mix --peek and non-peek** in the same session without thinking. Peek reads state but doesn't advance it; non-peek advances it. If you peek then run a mutating call, the mutating call advances from wherever the bookmark was.
- **Rate limits are undocumented.** Space bulk write operations (replies, likes, follows). If a write fails with a 429, wait several minutes before retrying.
