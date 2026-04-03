# Google Drive

## Helper commands

### Upload
```bash
gws drive +upload ./report.pdf                          # Upload to root
gws drive +upload ./report.pdf --parent FOLDER_ID       # Upload to folder
gws drive +upload ./data.csv --name 'Sales Data.csv'    # Custom name
```

MIME type is auto-detected from extension.

## Raw API

### Files

```bash
# List files (search)
gws drive files list --params '{"q":"name contains '\''report'\''","pageSize":10,"fields":"files(id,name,mimeType,modifiedTime,size)"}'

# List files in a folder
gws drive files list --params '{"q":"'\''FOLDER_ID'\'' in parents","pageSize":20}'

# Get file metadata
gws drive files get --params '{"fileId":"ID","fields":"id,name,mimeType,modifiedTime,size,webViewLink"}'

# Download file
gws drive files get --params '{"fileId":"ID","alt":"media"}' --output ./downloaded-file.pdf

# Export Google Doc as PDF
gws drive files export --params '{"fileId":"DOC_ID","mimeType":"application/pdf"}' --output ./doc.pdf

# Export Google Sheet as CSV
gws drive files export --params '{"fileId":"SHEET_ID","mimeType":"text/csv"}' --output ./data.csv

# Create empty file
gws drive files create --json '{"name":"notes.txt","mimeType":"text/plain"}'

# Create folder
gws drive files create --json '{"name":"Tron Reports","mimeType":"application/vnd.google-apps.folder"}'

# Create folder inside another folder
gws drive files create --json '{"name":"March 2026","mimeType":"application/vnd.google-apps.folder","parents":["PARENT_FOLDER_ID"]}'

# Update file metadata (rename)
gws drive files update --params '{"fileId":"ID"}' --json '{"name":"new-name.pdf"}'

# Update file content (re-upload)
gws drive files update --params '{"fileId":"ID"}' --upload ./updated-file.pdf

# Move file to folder
gws drive files update --params '{"fileId":"ID","addParents":"FOLDER_ID","removeParents":"OLD_FOLDER_ID"}'

# Copy file
gws drive files copy --params '{"fileId":"ID"}' --json '{"name":"Copy of file","parents":["FOLDER_ID"]}'

# Delete file (permanent)
gws drive files delete --params '{"fileId":"ID"}'

# Trash / Untrash
gws drive files update --params '{"fileId":"ID"}' --json '{"trashed":true}'
gws drive files update --params '{"fileId":"ID"}' --json '{"trashed":false}'
```

### Permissions (sharing)

```bash
# Share with user (viewer)
gws drive permissions create --params '{"fileId":"ID"}' --json '{"role":"reader","type":"user","emailAddress":"alice@example.com"}'

# Share with user (editor)
gws drive permissions create --params '{"fileId":"ID"}' --json '{"role":"writer","type":"user","emailAddress":"alice@example.com"}'

# Share with anyone (link sharing)
gws drive permissions create --params '{"fileId":"ID"}' --json '{"role":"reader","type":"anyone"}'

# List permissions
gws drive permissions list --params '{"fileId":"ID"}'

# Remove permission
gws drive permissions delete --params '{"fileId":"ID","permissionId":"PERM_ID"}'
```

## Drive search query syntax

Use in the `q` parameter of `files list`:

| Query | Example |
|-------|---------|
| Name contains | `name contains 'report'` |
| Exact name | `name = 'Budget 2026.xlsx'` |
| In folder | `'FOLDER_ID' in parents` |
| MIME type | `mimeType = 'application/pdf'` |
| Google Docs | `mimeType = 'application/vnd.google-apps.document'` |
| Google Sheets | `mimeType = 'application/vnd.google-apps.spreadsheet'` |
| Folders only | `mimeType = 'application/vnd.google-apps.folder'` |
| Modified after | `modifiedTime > '2026-03-01T00:00:00'` |
| Not trashed | `trashed = false` |
| Starred | `starred = true` |
| Full text search | `fullText contains 'quarterly'` |
| Combine | `name contains 'report' and mimeType = 'application/pdf' and trashed = false` |

## Recommended folder structure

Organize Tron's Drive like this:

```
My Drive/
  Tron/
    Reports/          # Generated reports, digests
    Exports/          # Data exports, backups
    Scratch/          # Temporary working files
    Shared/           # Files shared with others
```

Create the top-level folder once, then use its ID as `--parent` for uploads.

## Pagination

```bash
gws drive files list --params '{"q":"trashed=false","pageSize":100}' --page-all --page-limit 10
```

## Gotchas

- `fields` parameter controls which fields are returned — always specify it for list operations to avoid bloated responses.
- Google Workspace files (Docs, Sheets, Slides) have zero `size` — they're not traditional files. Use `export` to download them.
- Export MIME types: PDF (`application/pdf`), CSV (`text/csv`), DOCX (`application/vnd.openxmlformats-officedocument.wordprocessingml.document`), XLSX (`application/vnd.openxmlformats-officedocument.spreadsheetml.sheet`), PPTX (`application/vnd.openxmlformats-officedocument.presentationml.presentation`), plain text (`text/plain`).
- `delete` is permanent. Prefer trashing files unless you're sure.
- File IDs are in the URL: `https://docs.google.com/document/d/FILE_ID/edit`.
