---
paths:
  - "**/Views/**"
  - "**/*View.swift"
  - "**/*Sheet.swift"
---

# Views

SwiftUI view composition patterns.

## Directory Structure

| Location | Purpose |
|----------|---------|
| `Views/Chat/` | Core chat interface (ChatView, ContentView) |
| `Views/Tools/` | Tool chips + detail sheets (paired) |
| `Views/Components/` | Reusable UI components |
| `Views/{Feature}/` | Feature-specific views |

## Patterns

### Chip+Sheet Pairing

Tool features with inline chips and detail sheets belong together:
```
Views/Tools/FeatureName/
├── FeatureNameChip.swift
└── FeatureNameDetailSheet.swift
```

### View Extensions

Large views split across files:
```
Views/Chat/
├── ChatView.swift
├── ChatView+Messages.swift
└── ChatView+Input.swift
```

### Sheet Coordination

Use `SheetCoordinator` for managing sheets:
- Single active sheet pattern (avoids SwiftUI compiler issues)
- Sheet state in `ViewModels/State/SheetState.swift`
- Present via `sheetCoordinator.present(.sheetType)`

## Rules

- Maximum 3 levels: `Sources/Views/Feature/`
- Name views: `*View.swift`, `*Sheet.swift`, `*Chip.swift`
- Reusable components go in `Views/Components/`
- Tool visualizations go in `Views/ToolViewers/`

---

## Update Triggers

Update this rule when:
- Adding new view patterns
- Changing sheet coordination
- Modifying directory structure

Verification:
```bash
ls packages/ios-app/Sources/Views/Tools/*/
find packages/ios-app/Sources/Views -name "*Sheet.swift" | head -3
```
