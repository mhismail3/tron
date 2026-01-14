# Create Agent Tool

Guide for creating a new tool that the agent can use to trigger actions in the iOS app.

## Overview

Tools in Tron follow this data flow:
```
Agent calls tool → Server emits event → iOS receives event → iOS triggers UI/action
```

The existing event system (`agent.tool_start`) already forwards tool calls to iOS. You don't need to create new event types - just handle the tool name in iOS.

## Step-by-Step Implementation

### 1. Create Tool in Core Package

**File**: `packages/core/src/tools/{tool-name}.ts`

```typescript
import type { TronTool, TronToolResult } from '../types/index.js';
import { createLogger } from '../logging/logger.js';

const logger = createLogger('tool:{tool-name}');

export interface {ToolName}Config {
  workingDirectory?: string;
}

export class {ToolName}Tool implements TronTool {
  readonly name = '{ToolName}';
  readonly description = `Description of what this tool does.

Use this tool when you want to:
- First use case
- Second use case

Examples:
- Example 1: { "param": "value" }`;

  readonly parameters = {
    type: 'object' as const,
    properties: {
      param: {
        type: 'string' as const,
        description: 'Description of parameter',
      },
    },
    required: ['param'] as string[],
  };

  readonly label = 'Tool Label';  // For UI display
  readonly category = 'custom' as const;  // Or 'filesystem', 'shell', 'search', 'network'

  constructor(_config: {ToolName}Config = {}) {}

  async execute(args: Record<string, unknown>): Promise<TronToolResult> {
    const param = args.param as string | undefined;

    // Validate required parameters
    if (!param) {
      return {
        content: 'Missing required parameter: param',
        isError: true,
      };
    }

    // Validate parameter values
    const validation = this.validateParam(param);
    if (!validation.valid) {
      return {
        content: validation.error!,
        isError: true,
      };
    }

    logger.info('Executing tool', { param });

    // Return success - iOS will handle the action via tool_start event
    return {
      content: `Action triggered for ${param}`,
      isError: false,
      details: {
        param,
        action: 'action_type',
      },
    };
  }

  private validateParam(param: string): { valid: boolean; error?: string } {
    // Add validation logic
    return { valid: true };
  }
}
```

### 2. Export Tool from Index

**File**: `packages/core/src/tools/index.ts`

Add export:
```typescript
export { {ToolName}Tool, type {ToolName}Config } from './{tool-name}.js';
```

### 3. Register Tool in Server

**File**: `packages/server/src/event-store-orchestrator.ts`

Add to imports (around line 75):
```typescript
import {
  // ... existing imports
  {ToolName}Tool,
} from '@tron/core';
```

Add to tools array (around line 2125):
```typescript
const tools: TronTool[] = [
  // ... existing tools
  new {ToolName}Tool({ workingDirectory }),
];
```

### 4. Handle Tool in iOS

**File**: `packages/ios-app/Sources/ViewModels/ChatViewModel+Events.swift`

Add detection in `handleToolStart` method (around line 70):
```swift
// Check if this is a {ToolName} tool call
if event.toolName.lowercased() == "{toolname}" {
    handle{ToolName}ToolStart(event)
    // Don't return if you still want to show as regular tool use
}
```

Add handler method:
```swift
/// Handle {ToolName} tool start
private func handle{ToolName}ToolStart(_ event: ToolStartEvent) {
    logger.info("{ToolName} tool detected", category: .events)

    // Extract parameters from arguments dictionary
    guard let args = event.arguments,
          let paramValue = args["param"],
          let param = paramValue.value as? String else {
        logger.error("Failed to parse {ToolName} parameters", category: .events)
        return
    }

    logger.info("Handling {ToolName} with param: \(param)", category: .events)

    // Set state to trigger UI
    {toolName}State = param
}
```

### 5. Add State Property to ViewModel

**File**: `packages/ios-app/Sources/ViewModels/ChatViewModel.swift`

Add published property (in appropriate MARK section):
```swift
// MARK: - {ToolName} State

/// State for {ToolName} tool
@Published var {toolName}State: String?
```

### 6. Add UI Presentation

**File**: `packages/ios-app/Sources/Views/ChatView.swift`

Add sheet presentation (around line 245):
```swift
// {ToolName} sheet
.sheet(isPresented: Binding(
    get: { viewModel.{toolName}State != nil },
    set: { if !$0 { viewModel.{toolName}State = nil } }
)) {
    if let state = viewModel.{toolName}State {
        {ToolName}View(state: state)
    }
}
```

### 7. Create View Component (if needed)

**File**: `packages/ios-app/Sources/Views/{ToolName}View.swift`

```swift
import SwiftUI

struct {ToolName}View: View {
    let state: String

    var body: some View {
        // View implementation
    }
}

#Preview {
    {ToolName}View(state: "example")
}
```

### 8. Add to Xcode Project

**File**: `packages/ios-app/TronMobile.xcodeproj/project.pbxproj`

Add three entries:

1. **PBXBuildFile** (around line 95):
```
{TOOLID}00000000200001 /* {ToolName}View.swift in Sources */ = {isa = PBXBuildFile; fileRef = {TOOLID}00000000100001 /* {ToolName}View.swift */; };
```

2. **PBXFileReference** (around line 197):
```
{TOOLID}00000000100001 /* {ToolName}View.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {ToolName}View.swift; sourceTree = "<group>"; };
```

3. **Views group** (around line 320):
```
{TOOLID}00000000100001 /* {ToolName}View.swift */,
```

4. **Sources build phase** (around line 570):
```
{TOOLID}00000000200001 /* {ToolName}View.swift in Sources */,
```

Use a unique ID pattern like `TOOLNAME00000000100001` and `TOOLNAME00000000200001`.

### 9. Add Unit Tests

**File**: `packages/core/test/tools/{tool-name}.test.ts`

```typescript
import { describe, it, expect, beforeEach } from 'vitest';
import { {ToolName}Tool } from '../../src/tools/{tool-name}.js';

describe('{ToolName}Tool', () => {
  let tool: {ToolName}Tool;

  beforeEach(() => {
    tool = new {ToolName}Tool({ workingDirectory: '/test' });
  });

  describe('tool definition', () => {
    it('should have correct name', () => {
      expect(tool.name).toBe('{ToolName}');
    });

    it('should define required parameters', () => {
      expect(tool.parameters.required).toContain('param');
    });
  });

  describe('execute', () => {
    it('should accept valid input', async () => {
      const result = await tool.execute({ param: 'valid' });
      expect(result.isError).toBeFalsy();
    });

    it('should reject missing parameter', async () => {
      const result = await tool.execute({});
      expect(result.isError).toBe(true);
    });

    // Add more test cases for validation
  });
});
```

## Verification Checklist

- [ ] Tool builds: `cd packages/core && bun run build`
- [ ] Server builds: `cd packages/server && bun run build`
- [ ] Tests pass: `cd packages/core && bun test test/tools/{tool-name}.test.ts`
- [ ] iOS builds in Xcode (Cmd+B)
- [ ] Manual test: Start server, use iOS app, trigger tool via agent

## Data Flow Reference

```
┌─────────────────────────────────────────────────────────────────────────┐
│ Agent (TronAgent)                                                       │
│   └── Calls tool.execute() with arguments                              │
│         └── Emits 'tool_execution_start' event                         │
└─────────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────────┐
│ Server (EventStoreOrchestrator)                                         │
│   └── Receives event, forwards as 'agent.tool_start' via WebSocket     │
│         └── Data: { toolCallId, toolName, arguments }                  │
└─────────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────────┐
│ iOS (RPCClient)                                                         │
│   └── Receives WebSocket message, parses as ToolStartEvent             │
│         └── Calls onToolStart callback                                 │
└─────────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────────┐
│ iOS (ChatViewModel+Events)                                              │
│   └── handleToolStart() checks event.toolName                          │
│         └── Extracts args from event.arguments[key].value              │
│               └── Sets @Published property to trigger UI               │
└─────────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────────┐
│ iOS (ChatView)                                                          │
│   └── SwiftUI binding observes @Published property                     │
│         └── Presents sheet/view when property is non-nil               │
└─────────────────────────────────────────────────────────────────────────┘
```

## Key Files Reference

| Purpose | File Path |
|---------|-----------|
| Tool implementation | `packages/core/src/tools/{tool-name}.ts` |
| Tool exports | `packages/core/src/tools/index.ts` |
| Tool registration | `packages/server/src/event-store-orchestrator.ts` |
| iOS event handling | `packages/ios-app/Sources/ViewModels/ChatViewModel+Events.swift` |
| iOS state | `packages/ios-app/Sources/ViewModels/ChatViewModel.swift` |
| iOS presentation | `packages/ios-app/Sources/Views/ChatView.swift` |
| iOS view component | `packages/ios-app/Sources/Views/{ToolName}View.swift` |
| Xcode project | `packages/ios-app/TronMobile.xcodeproj/project.pbxproj` |
| Unit tests | `packages/core/test/tools/{tool-name}.test.ts` |

## Tips

- **Fire-and-forget tools**: Return success immediately, let iOS handle the action
- **Tools needing response**: Use a delegate pattern (see `BrowserTool` for example)
- **URL parameters**: Use `AnyCodable.value` to extract typed values in Swift
- **Sheet presentation**: Use computed `Binding` for optional state to auto-dismiss
- **Xcode IDs**: Use consistent naming pattern for pbxproj entries
