# Gmail

## Helper commands

### Send email
```bash
gws gmail +send --to alice@example.com --subject 'Subject' --body 'Plain text body'
gws gmail +send --to alice@example.com --subject 'Subject' --body '<b>HTML</b> body' --html
gws gmail +send --to alice@example.com --subject 'Hi' --body 'Text' --cc bob@example.com --bcc secret@example.com
```

### Triage inbox
```bash
gws gmail +triage                              # Unread inbox, top 20
gws gmail +triage --max 5                      # Limit to 5
gws gmail +triage --query 'from:github.com'    # Custom search
gws gmail +triage --format table --labels      # Table with label names
```

### Reply / Reply all
```bash
gws gmail +reply --message-id MSG_ID --body 'Thanks!'
gws gmail +reply --message-id MSG_ID --body '<b>Bold</b>' --html
gws gmail +reply-all --message-id MSG_ID --body 'Noted, thanks everyone.'
gws gmail +reply --message-id MSG_ID --body 'Looping in' --cc extra@example.com
```

### Forward
```bash
gws gmail +forward --message-id MSG_ID --to dave@example.com
gws gmail +forward --message-id MSG_ID --to dave@example.com --body 'FYI see below'
```

### Watch for new email
```bash
gws gmail +watch --project GCP_PROJECT          # Stream new emails as NDJSON
gws gmail +watch --project GCP_PROJECT --once    # Pull once and exit
gws gmail +watch --subscription projects/p/subscriptions/sub  # Use existing subscription
```

Requires Pub/Sub setup. Watch expires after 7 days — re-run to renew.

## Raw API

### Messages

```bash
# List messages (search)
gws gmail users messages list --params '{"userId":"me","q":"is:unread from:github.com","maxResults":10}'

# Get full message
gws gmail users messages get --params '{"userId":"me","id":"MSG_ID"}'

# Get metadata only
gws gmail users messages get --params '{"userId":"me","id":"MSG_ID","format":"metadata"}'

# Send raw (for attachments)
gws gmail users messages send --params '{"userId":"me"}' --json '{"raw":"BASE64_RFC2822"}'

# Trash / Untrash
gws gmail users messages trash --params '{"userId":"me","id":"MSG_ID"}'
gws gmail users messages untrash --params '{"userId":"me","id":"MSG_ID"}'

# Permanently delete (no recovery)
gws gmail users messages delete --params '{"userId":"me","id":"MSG_ID"}'

# Modify labels
gws gmail users messages modify --params '{"userId":"me","id":"MSG_ID"}' --json '{"addLabelIds":["STARRED"],"removeLabelIds":["UNREAD"]}'

# Batch modify
gws gmail users messages batchModify --params '{"userId":"me"}' --json '{"ids":["ID1","ID2"],"addLabelIds":["LABEL"]}'
```

### Labels

```bash
# List all labels
gws gmail users labels list --params '{"userId":"me"}'

# Create label
gws gmail users labels create --params '{"userId":"me"}' --json '{"name":"Tron/Automated","labelListVisibility":"labelShow","messageListVisibility":"show"}'

# Get label
gws gmail users labels get --params '{"userId":"me","id":"LABEL_ID"}'

# Delete label
gws gmail users labels delete --params '{"userId":"me","id":"LABEL_ID"}'
```

### Drafts

```bash
# List drafts
gws gmail users drafts list --params '{"userId":"me"}'

# Create draft
gws gmail users drafts create --params '{"userId":"me"}' --json '{"message":{"raw":"BASE64_RFC2822"}}'

# Send draft
gws gmail users drafts send --params '{"userId":"me"}' --json '{"id":"DRAFT_ID"}'
```

### Threads

```bash
# List threads
gws gmail users threads list --params '{"userId":"me","q":"subject:weekly report"}'

# Get thread (all messages)
gws gmail users threads get --params '{"userId":"me","id":"THREAD_ID"}'
```

## Gmail search operators

Use these in `--query` for `+triage` or `q` for raw API:

| Operator | Example |
|----------|---------|
| `from:` | `from:alice@example.com` |
| `to:` | `to:bob@example.com` |
| `subject:` | `subject:invoice` |
| `has:attachment` | `has:attachment filename:pdf` |
| `after:` / `before:` | `after:2026/03/01 before:2026/03/15` |
| `is:unread` / `is:starred` | `is:unread is:important` |
| `label:` | `label:tron-automated` |
| `newer_than:` | `newer_than:2d` (2 days) |
| `larger:` / `smaller:` | `larger:5M` |
| `OR` / `-` (NOT) | `from:alice OR from:bob -subject:spam` |
| `{ }` (grouping) | `{from:alice from:bob}` = OR |

## Pagination

Messages list returns max 500 per page. Use `--page-all` for auto-pagination:
```bash
gws gmail users messages list --params '{"userId":"me","q":"label:inbox"}' --page-all --page-limit 5
```

## Gotchas

- `userId` is always `"me"` for the authenticated account.
- Message bodies are base64url-encoded in raw format. The `+send`/`+reply` helpers handle encoding automatically.
- Attachments require the raw API with multipart MIME — helpers don't support attachments yet.
- `+triage` is read-only, never modifies the mailbox.
- Labels: system labels are uppercase (`INBOX`, `UNREAD`, `STARRED`), custom labels use their ID from `labels list`.
