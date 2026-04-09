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

Use `--peek` to preview without updating state:
```bash
tron-twitter check-mentions --peek          # Preview new mentions
tron-twitter check-dms --peek               # Preview new DMs
```

Without `--peek`, state advances and those items won't appear as "new" again.

Without `--peek` (updates state):
```bash
tron-twitter check-mentions                 # Returns only NEW mentions since last check
tron-twitter check-dms                      # Returns only NEW DMs since last check
```

State stored in `~/.tron/system/mods/twitter/state.json`. First run returns all; subsequent runs return only new.

## Gotchas
