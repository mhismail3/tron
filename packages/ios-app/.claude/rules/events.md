---
paths:
  - "**/Core/Events/**"
---

# Events Architecture

Two systems handle events: **plugins** for live WebSocket events, **transformer** for reconstructing history from stored events.

## Directory Structure

- `Plugins/` - Live event parsing (WebSocket -> UI)
- `Transformer/` - History reconstruction (stored events -> ChatMessage)
- `Payloads/` - Shared Decodable structs for both systems

## Data Flow

```
Live:   WebSocket -> EventRegistry -> Plugin -> EventDispatchCoordinator -> ChatViewModel
Stored: EventDatabase -> Transformer -> ChatMessage array
```

## Rules

- Plugins handle WebSocket events only, transformer handles reconstruction only
- All live events flow through `eventPublisherV2`, never create parallel paths
- Payloads are shared between systems - changes affect both

---

## Update Triggers

Update this rule when:
- Changing plugin vs transformer responsibilities
- Adding new event flow paths
- Modifying shared payload structures

Verification:
```bash
ls packages/ios-app/Sources/Core/Events/
```
