# Google Calendar

## Helper commands

### View agenda
```bash
gws calendar +agenda                                    # Default upcoming events
gws calendar +agenda --today                            # Today only
gws calendar +agenda --tomorrow                         # Tomorrow only
gws calendar +agenda --week                             # This week
gws calendar +agenda --days 3                           # Next 3 days
gws calendar +agenda --today --format table             # Table output
gws calendar +agenda --calendar 'Work'                  # Specific calendar
gws calendar +agenda --today --timezone America/Denver  # Override timezone
```

### Create event
```bash
gws calendar +insert --summary 'Standup' --start '2026-03-15T09:00:00-07:00' --end '2026-03-15T09:30:00-07:00'
gws calendar +insert --summary 'Review' --start '...' --end '...' --attendee alice@example.com
gws calendar +insert --summary 'Lunch' --start '...' --end '...' --location 'Cafe' --description 'Weekly sync'
```

Times must be RFC 3339 (ISO 8601 with timezone offset).

## Raw API

### Events

```bash
# List events (upcoming)
gws calendar events list --params '{"calendarId":"primary","timeMin":"2026-03-15T00:00:00Z","maxResults":10,"singleEvents":true,"orderBy":"startTime"}'

# List events (date range)
gws calendar events list --params '{"calendarId":"primary","timeMin":"2026-03-01T00:00:00Z","timeMax":"2026-03-31T23:59:59Z","singleEvents":true,"orderBy":"startTime"}'

# Get event
gws calendar events get --params '{"calendarId":"primary","eventId":"EVENT_ID"}'

# Create event (full control)
gws calendar events insert --params '{"calendarId":"primary"}' --json '{
  "summary": "Team sync",
  "start": {"dateTime": "2026-03-15T14:00:00-07:00"},
  "end": {"dateTime": "2026-03-15T15:00:00-07:00"},
  "description": "Weekly team sync",
  "location": "Conference Room A",
  "attendees": [{"email": "alice@example.com"}],
  "reminders": {"useDefault": false, "overrides": [{"method": "popup", "minutes": 10}]}
}'

# Create all-day event
gws calendar events insert --params '{"calendarId":"primary"}' --json '{
  "summary": "Deadline: Q1 report",
  "start": {"date": "2026-03-31"},
  "end": {"date": "2026-04-01"}
}'

# Create recurring event
gws calendar events insert --params '{"calendarId":"primary"}' --json '{
  "summary": "Daily standup",
  "start": {"dateTime": "2026-03-15T09:00:00-07:00", "timeZone": "America/Denver"},
  "end": {"dateTime": "2026-03-15T09:15:00-07:00", "timeZone": "America/Denver"},
  "recurrence": ["RRULE:FREQ=DAILY;BYDAY=MO,TU,WE,TH,FR"]
}'

# Update event
gws calendar events update --params '{"calendarId":"primary","eventId":"EVENT_ID"}' --json '{
  "summary": "Updated title",
  "start": {"dateTime": "2026-03-15T15:00:00-07:00"},
  "end": {"dateTime": "2026-03-15T16:00:00-07:00"}
}'

# Patch event (partial update)
gws calendar events patch --params '{"calendarId":"primary","eventId":"EVENT_ID"}' --json '{"summary":"New title"}'

# Delete event
gws calendar events delete --params '{"calendarId":"primary","eventId":"EVENT_ID"}'
```

### Calendars

```bash
# List all calendars
gws calendar calendarList list

# Create secondary calendar
gws calendar calendars insert --json '{"summary":"Tron Automations"}'
```

### Free/busy

```bash
# Check availability
gws calendar freebusy query --json '{
  "timeMin": "2026-03-15T00:00:00Z",
  "timeMax": "2026-03-15T23:59:59Z",
  "items": [{"id": "primary"}]
}'
```

## Cross-service workflows

```bash
# Standup: today's meetings + open tasks
gws workflow +standup-report

# Meeting prep: next meeting's agenda, attendees, linked docs
gws workflow +meeting-prep

# Weekly digest: this week's meetings + unread email count
gws workflow +weekly-digest
```

## Timezone handling

The account timezone is auto-detected from the Google account settings. Override per-query with `--timezone` (helpers) or `timeZone` in event JSON.

Use IANA timezone names: `America/Denver`, `America/New_York`, `UTC`, etc.

## Gotchas

- `singleEvents: true` expands recurring events into individual instances — required for `orderBy: startTime`.
- All-day events use `date` (not `dateTime`). The end date is exclusive — for a single day, end = start + 1 day.
- `calendarId` is `"primary"` for the main calendar. Secondary calendars use their email-like ID from `calendarList list`.
- Recurring event deletion: deleting the parent deletes all instances. Delete a specific `eventId` (with the `_YYYYMMDD` suffix) to remove one occurrence.
- The `+agenda` helper is read-only.
