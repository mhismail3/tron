# Tool Detail Sheets

## Adding a New Tool

When adding a new tool to the iOS app, touch these files:

1. **`Models/Tools/ToolDescriptor.swift`** — Add registry entry with `AnyView` factory for the detail sheet
2. **`Models/Tools/ToolRegistry.swift`** — Add to `commandToolNames` set if it's a command tool
3. **`Views/Tools/<ToolName>/<ToolName>ToolDetailSheet.swift`** — New detail sheet
4. **Result parser** (if needed) — `Views/Tools/<ToolName>/<ToolName>ResultParser.swift`
5. **`Services/Parsing/ToolResultParser.swift`** — Add delegation for the new parser
6. **Chip display** (if custom) — Update `MessageBubble` area

## Shared Components

Use these from `Views/Tools/Shared/`:

- **`ToolDetailSheetContainer`** — NavigationStack + toolbar boilerplate
- **`ToolDetailSection`** — Glass section with title header
- **`ToolStatusBadge`** / **`ToolDurationBadge`** / **`ToolInfoPill`** — Status pills
- **`ToolRunningSpinner`** — Shared spinner for "running" state (title, accent, tint, actionText)
- **`ToolStatusRow`** — Horizontal scroll of status/duration badges + `@ViewBuilder` additional pills
- **`ToolClassifiedErrorSection`** — Error display using `ErrorClassification` struct
- **`ToolErrorView`** — File-write-specific structured error display
- **`FileInfoProperties`** — Shared file path/name/extension extraction from tool arguments
- **`ToolFileInfoSection`** — File info UI (icon + name + extension capsule + path)
- **`ToolCodeBlock`** — Line-numbered code display with accent border and optional copy button
- **`ToolCopyButton`** — Reusable icon-only copy-to-clipboard button
- **`ToolEmptyState`** — Empty/no-results state with icon, message, and optional subtitle
- **`ToolResultNote`** — Success note with checkmark icon (used by Write, Edit)

## Error Classification

For tools that need structured error display:

1. Add a `classifyError(_ message: String) -> ErrorClassification` to the tool's detail parser
2. Use `ToolClassifiedErrorSection` in the sheet (supports additional content via `@ViewBuilder`)

## Rules

- Every sheet uses `ToolDetailSheetContainer` for consistent outer chrome
- Use `ToolClassifiedErrorSection` instead of hand-rolling error display VStacks
- Use `ToolStatusRow` for status rows (wraps ToolStatusBadge + ToolDurationBadge + additional pills)
- Use `ToolRunningSpinner` for running-state spinners instead of hand-rolling ProgressView + Text
- Use `FileInfoProperties` + `ToolFileInfoSection` for file-based tools (Read, Write, Edit)
- Use `ToolCodeBlock` for line-numbered content display (Read content, Write preview, Bash output)
- Use `ToolEmptyState` for no-results states instead of hand-rolling VStack + Image + Text
- Use `ToolCopyButton` for section copy buttons instead of inline Button + Image
- Keep detail sheets under 500 LOC; extract nested subviews for large sheets

---

## Update Triggers

Update this rule when:
- Adding shared tool components
- Changing the tool registration pattern
- Modifying ToolDetailSheetContainer API

Verification:
```bash
ls packages/ios-app/Sources/Views/Tools/Shared/
```
