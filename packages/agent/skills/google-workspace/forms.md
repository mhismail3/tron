# Google Forms

No helper commands — use the raw API directly.

## Raw API

### Forms

```bash
# Create form
gws forms forms create --json '{"info":{"title":"Feedback Survey"}}'

# Get form
gws forms forms get --params '{"formId":"FORM_ID"}'

# Update form (batch update)
gws forms forms batchUpdate --params '{"formId":"FORM_ID"}' --json '{
  "requests": [...]
}'
```

### Common batch update requests

**Add a text question:**
```json
{
  "createItem": {
    "item": {
      "title": "What is your name?",
      "questionItem": {
        "question": {
          "required": true,
          "textQuestion": {"paragraph": false}
        }
      }
    },
    "location": {"index": 0}
  }
}
```

**Add a multiple choice question:**
```json
{
  "createItem": {
    "item": {
      "title": "How would you rate this?",
      "questionItem": {
        "question": {
          "required": true,
          "choiceQuestion": {
            "type": "RADIO",
            "options": [
              {"value": "Excellent"},
              {"value": "Good"},
              {"value": "Fair"},
              {"value": "Poor"}
            ]
          }
        }
      }
    },
    "location": {"index": 1}
  }
}
```

**Add a checkbox question:**
```json
{
  "createItem": {
    "item": {
      "title": "Select all that apply",
      "questionItem": {
        "question": {
          "choiceQuestion": {
            "type": "CHECKBOX",
            "options": [{"value": "Option A"}, {"value": "Option B"}, {"value": "Option C"}]
          }
        }
      }
    },
    "location": {"index": 2}
  }
}
```

**Add a section header:**
```json
{
  "createItem": {
    "item": {
      "title": "Section Title",
      "description": "Section description text"
    },
    "location": {"index": 0}
  }
}
```

### Responses

```bash
# List all responses
gws forms forms responses list --params '{"formId":"FORM_ID"}'

# Get specific response
gws forms forms responses get --params '{"formId":"FORM_ID","responseId":"RESPONSE_ID"}'
```

## Workflow: create a survey and collect responses

```bash
# 1. Create form
gws forms forms create --json '{"info":{"title":"Weekly Feedback"}}'

# 2. Add questions
gws forms forms batchUpdate --params '{"formId":"FORM_ID"}' --json '{
  "requests": [
    {"createItem": {"item": {"title": "How was your week?", "questionItem": {"question": {"required": true, "choiceQuestion": {"type": "RADIO", "options": [{"value": "Great"}, {"value": "OK"}, {"value": "Rough"}]}}}}, "location": {"index": 0}}},
    {"createItem": {"item": {"title": "Any blockers?", "questionItem": {"question": {"textQuestion": {"paragraph": true}}}}, "location": {"index": 1}}}
  ]
}'

# 3. Share the form URL (from the form's responderUri)
gws forms forms get --params '{"formId":"FORM_ID"}'

# 4. Later, read responses
gws forms forms responses list --params '{"formId":"FORM_ID"}'
```

## Gotchas

- Forms API is newer and more limited than other Google APIs. Some features (themes, logic branching) aren't available via API.
- The form URL for respondents is in the `responderUri` field of the form object.
- Question types: `textQuestion` (short/paragraph), `choiceQuestion` (RADIO/CHECKBOX/DROP_DOWN), `scaleQuestion`, `dateQuestion`, `timeQuestion`, `fileUploadQuestion`.
- `location.index` determines question order (0-based).
- Responses are read-only via API — you can't submit responses programmatically (that's by design).
