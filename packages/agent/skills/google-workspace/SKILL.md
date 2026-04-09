---
name: "Google Workspace"
description: "Full Google Workspace access — Gmail, Drive, Calendar, Docs, Forms, and more via the gws CLI"
version: "1.0.0"
tags: [google, gmail, drive, calendar, docs, forms, email, workspace]
subagent: ask
---

# Google Workspace

You have full access to Google Workspace services via the `gws` CLI. Run `gws auth status` to see the authenticated account.

## Setup

**First time on this machine?** Read `account.md` first — there's a cold-start checklist (GCP project, enabled APIs, consent screen, OAuth client) that has to happen before `gws auth login` will work. Credentials are stored in the Tron vault (entry name: `google-workspace-cli`) and materialized to a temp file per call — see `account.md` for the pattern.

Run these checks before doing anything else:

```bash
# 1. Is gws installed?
which gws || brew install googleworkspace-cli

# 2. Is it up to date?
gws --version
brew outdated googleworkspace-cli && brew upgrade googleworkspace-cli

# 3. Is auth valid?
gws auth status
```

If auth is expired or missing, tell the user to run `gws auth login` manually — it requires an interactive browser flow. After re-login, refresh the vault entry per `account.md`.

## Routing table

Match user intent to the correct reference file. **Read the file** before executing the workflow.

| User wants... | Read file |
|---|---|
| Send/read/search email, manage labels, triage inbox | `gmail.md` |
| Upload/download/organize files, share, search Drive | `drive.md` |
| Create/view events, check agenda, schedule reminders | `calendar.md` |
| Create/edit/export Google Docs | `docs.md` |
| Create forms, read form responses | `forms.md` |
| Sign up for services, manage account, check auth | `account.md` |
| Cross-service workflows (standup, digest, meeting prep) | See "Workflows" below |

For **quick lookups** (single command, scan results, answer directly), the CLI reference below is sufficient — no sub-file needed.

## CLI quick reference

### Gmail

| Command | Usage |
|---------|-------|
| Send | `gws gmail +send --to EMAIL --subject 'Subject' --body 'Body'` |
| Triage inbox | `gws gmail +triage [--max N] [--query 'QUERY']` |
| Reply | `gws gmail +reply --message-id ID --body 'Text'` |
| Reply all | `gws gmail +reply-all --message-id ID --body 'Text'` |
| Forward | `gws gmail +forward --message-id ID --to EMAIL` |
| Watch | `gws gmail +watch --project PROJECT [--once]` |
| List messages | `gws gmail users messages list --params '{"userId":"me","q":"QUERY"}'` |
| Get message | `gws gmail users messages get --params '{"userId":"me","id":"MSG_ID"}'` |
| Modify labels | `gws gmail users messages modify --params '{"userId":"me","id":"MSG_ID"}' --json '{"addLabelIds":["LABEL"]}'` |
| List labels | `gws gmail users labels list --params '{"userId":"me"}'` |

### Drive

| Command | Usage |
|---------|-------|
| Upload | `gws drive +upload ./file.pdf [--parent FOLDER_ID]` |
| List files | `gws drive files list --params '{"q":"QUERY","pageSize":10}'` |
| Get file | `gws drive files get --params '{"fileId":"ID"}'` |
| Download | `gws drive files get --params '{"fileId":"ID","alt":"media"}' --output ./file.pdf` |
| Create folder | `gws drive files create --json '{"name":"Folder","mimeType":"application/vnd.google-apps.folder"}'` |
| Delete | `gws drive files delete --params '{"fileId":"ID"}'` |
| Share | `gws drive permissions create --params '{"fileId":"ID"}' --json '{"role":"reader","type":"user","emailAddress":"EMAIL"}'` |

### Calendar

| Command | Usage |
|---------|-------|
| Agenda | `gws calendar +agenda [--today] [--week] [--days N]` |
| Create event | `gws calendar +insert --summary 'Title' --start 'ISO8601' --end 'ISO8601'` |
| List events | `gws calendar events list --params '{"calendarId":"primary","timeMin":"ISO8601"}'` |
| Update event | `gws calendar events update --params '{"calendarId":"primary","eventId":"ID"}' --json '{...}'` |
| Delete event | `gws calendar events delete --params '{"calendarId":"primary","eventId":"ID"}'` |

### Docs

| Command | Usage |
|---------|-------|
| Append text | `gws docs +write --document DOC_ID --text 'Text'` |
| Get document | `gws docs documents get --params '{"documentId":"ID"}'` |
| Create | `gws docs documents create --json '{"title":"Title"}'` |
| Batch update | `gws docs documents batchUpdate --params '{"documentId":"ID"}' --json '{"requests":[...]}'` |

### Forms

| Command | Usage |
|---------|-------|
| Get form | `gws forms forms get --params '{"formId":"ID"}'` |
| Create form | `gws forms forms create --json '{"info":{"title":"Title"}}'` |
| List responses | `gws forms forms responses list --params '{"formId":"ID"}'` |

### Cross-service workflows

| Command | Usage |
|---------|-------|
| Standup report | `gws workflow +standup-report` |
| Meeting prep | `gws workflow +meeting-prep` |
| Weekly digest | `gws workflow +weekly-digest` |
| Email to task | `gws workflow +email-to-task --message-id MSG_ID` |
| File announce | `gws workflow +file-announce --file-id FILE_ID --space SPACE_NAME` |

Note: Sheets, Slides, and Chat are available via `gws` but don't have dedicated sub-files. Use `gws <service> --help` and `gws schema` for those.

## Global flags

- `--format <json|table|yaml|csv>` — output format (default: json)
- `--dry-run` — validate without executing
- `--page-all` — auto-paginate (NDJSON output)
- `--page-limit <N>` — max pages (default: 10)

## Schema discovery

Inspect any API method's parameters:
```bash
gws schema gmail.users.messages.list
gws schema drive.files.create --resolve-refs
```

## Exit codes

| Code | Meaning |
|------|---------|
| 0 | Success |
| 1 | API error |
| 2 | Auth error |
| 3 | Validation error |
| 4 | Discovery error |
| 5 | Internal error |

## Reference file paths

```
~/.tron/skills/google-workspace/gmail.md
~/.tron/skills/google-workspace/drive.md
~/.tron/skills/google-workspace/calendar.md
~/.tron/skills/google-workspace/docs.md
~/.tron/skills/google-workspace/forms.md
~/.tron/skills/google-workspace/account.md
```
