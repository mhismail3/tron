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
- **`ToolClassifiedErrorSection`** — Error display using `ErrorClassification` struct
- **`ToolErrorView`** — File-write-specific structured error display

## Error Classification

For tools that need structured error display:

1. Add a `classifyError(_ message: String) -> ErrorClassification` to the tool's detail parser
2. Use `ToolClassifiedErrorSection` in the sheet (supports additional content via `@ViewBuilder`)

## Rules

- Every sheet uses `ToolDetailSheetContainer` for consistent outer chrome
- Use `ToolClassifiedErrorSection` instead of hand-rolling error display VStacks
- Status rows use `ToolStatusBadge` + optional `ToolDurationBadge` + `ToolInfoPill` pills
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
