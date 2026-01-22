# Phase 4 RPC Layer Analysis

## Current Architecture

```
WebSocket → RpcHandler → handlers/ → adapters/ → orchestrator
```

## Key Finding

**Adapters are NOT pure pass-through**. They serve a real purpose:

1. **Dependency Injection Layer**: Implement manager interfaces (SessionManagerAdapter, AgentManagerAdapter, etc.)
2. **Data Transformation**: Convert between orchestrator format and RPC format (e.g., toSessionInfo helper)
3. **Data Enrichment**: Fetch additional data (e.g., messages from event store)
4. **Interface Mapping**: Map orchestrator methods to standardized manager interfaces

## Recommendation

**Path C: Keep Both** - The layers serve legitimate, separate purposes:
- **Adapters** (`gateway/rpc/adapters/`): Dependency injection + data transformation
- **Handlers** (`rpc/handlers/`): Parameter validation + RPC protocol + response formatting

This is a classic **Adapter Pattern** + **Handler Pattern** architecture, not duplication.

## Alternative: Simplify Handlers

Instead of removing adapters, we could:
1. Simplify handlers that are too verbose
2. Create base handler utilities for common validation patterns
3. Focus on removing circular dependencies instead

This would be lower risk and maintain the architectural separation.
