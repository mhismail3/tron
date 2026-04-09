# Engagement

All write operations require **explicit user approval** before execution. Draft content first, show it to the user, and only execute after confirmation.

## Posting

```bash
tron-twitter post "TEXT"                    # New tweet
tron-twitter reply TWEET_ID "TEXT"          # Reply to tweet
```

`TEXT` is a positional argument — do NOT use `--text` flags.

## Social Actions

```bash
tron-twitter like TWEET_ID
tron-twitter retweet TWEET_ID
tron-twitter follow USERNAME
tron-twitter unfollow USERNAME
```

## Direct Messages

```bash
tron-twitter dms                            # List conversations
tron-twitter dm-history USERNAME --count 20 # Read conversation
tron-twitter dm USERNAME "TEXT"             # Send message
```

`USERNAME` and `TEXT` are positional arguments.

## Monitoring

All monitoring commands require the per-call materialization pattern — see "Per-call materialization" in `SKILL.md`. Credentials live in the vault (`twitter-cookies`, `twitter-state`), never on disk between calls.

Use `--peek` to preview without updating state (read-only, cookies only):
```bash
mkdir -p ~/.tron/system/mods/twitter
~/.tron/skills/vault/scripts/vault.sh get twitter-cookies --field value \
  > ~/.tron/system/mods/twitter/cookies.json
~/.tron/skills/vault/scripts/vault.sh get twitter-state --field value \
  > ~/.tron/system/mods/twitter/state.json
chmod 600 ~/.tron/system/mods/twitter/cookies.json ~/.tron/system/mods/twitter/state.json
trap 'rm -f ~/.tron/system/mods/twitter/cookies.json ~/.tron/system/mods/twitter/state.json' EXIT

tron-twitter check-mentions --peek          # Preview new mentions
tron-twitter check-dms --peek               # Preview new DMs
```

Without `--peek`, state advances locally — you **must** push `state.json` back to the vault or the bookmark regresses on the next call:
```bash
mkdir -p ~/.tron/system/mods/twitter
~/.tron/skills/vault/scripts/vault.sh get twitter-cookies --field value \
  > ~/.tron/system/mods/twitter/cookies.json
~/.tron/skills/vault/scripts/vault.sh get twitter-state --field value \
  > ~/.tron/system/mods/twitter/state.json
chmod 600 ~/.tron/system/mods/twitter/cookies.json ~/.tron/system/mods/twitter/state.json
trap 'rm -f ~/.tron/system/mods/twitter/cookies.json ~/.tron/system/mods/twitter/state.json' EXIT

tron-twitter check-mentions                 # Returns only NEW mentions since last check

# REQUIRED: push updated state bookmark back to the vault
~/.tron/skills/vault/scripts/vault.sh set twitter-state \
  --type secret \
  --desc "X/Twitter state (last_mention_id bookmark) for tron-twitter check-mentions" \
  --tags "twitter,x,state" \
  --field-file value=~/.tron/system/mods/twitter/state.json
```

Same write-back is required for `tron-twitter check-dms` without `--peek`.

## Gotchas

- **Confirm before posting.** `post`, `reply`, `like`, `retweet`, `follow`, `dm` are user-visible actions — never execute without explicit user approval, even inside a larger workflow.
- **Materialize cookies for every write command.** `post`/`reply`/`dm` etc. need `cookies.json` at `~/.tron/system/mods/twitter/cookies.json` just like read commands. Don't skip the materialization.
- **Forgetting the state write-back** on non-peek `check-mentions`/`check-dms` is the easiest way to silently re-notify on old mentions. If you see the same items twice, the write-back step was skipped.
- **Don't mix --peek and non-peek** in the same session without thinking. Peek reads state but doesn't advance it; non-peek advances it. If you peek then run a mutating call, the mutating call will still advance from wherever the bookmark was.
- **Rate limits are undocumented.** Space bulk write operations (replies, likes, follows). If a write fails with a 429, wait several minutes before retrying.
