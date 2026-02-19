# Tron

**A persistent, event-sourced AI coding agent**

Tron is an AI coding agent that runs as a persistent service on macOS. The Rust server handles LLM communication, tool execution, and event-sourced session persistence. The native iOS app provides a real-time chat interface with streaming, session management, and push notifications.

## Architecture

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              iOS App                                        │
│                          packages/ios-app                                    │
│                  SwiftUI · MVVM · Event Plugins                             │
└─────────────────────────────────┬───────────────────────────────────────────┘
                                  │ WebSocket (JSON-RPC 2.0)
                                  │ Port 9847
                                  ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                          Rust Agent Server                                   │
│                         packages/agent                                       │
├─────────────────────────────────────────────────────────────────────────────┤
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐  ┌─────────────────────┐ │
│  │  Providers  │  │    Tools    │  │   Context   │  │    Orchestrator     │ │
│  │  Anthropic  │  │  read/write │  │   loader    │  │  Session lifecycle  │ │
│  │  OpenAI     │  │  edit/bash  │  │  compaction │  │  Turn management    │ │
│  │  Google     │  │  search/web │  │  skills     │  │  Event routing      │ │
│  └─────────────┘  └─────────────┘  └─────────────┘  └─────────────────────┘ │
└────────────────────────────────────┬────────────────────────────────────────┘
                                     │
                                     ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                         Event Store (SQLite)                                 │
│   - Immutable event log with tree structure                                  │
│   - Fork/rewind operations                                                   │
│   - Session state reconstruction via ancestor traversal                      │
└─────────────────────────────────────────────────────────────────────────────┘
```

### Package Structure

```
tron/
├── packages/
│   ├── agent/       # Rust agent server (crates workspace)
│   └── ios-app/     # SwiftUI iOS application
├── scripts/         # CLI and deployment scripts
└── .claude/         # Agent configuration
```

### Rust Crate Structure

```
packages/agent/crates/
├── tron-agent/          # Binary entry point (main.rs)
├── tron-core/           # Shared types, logging, error hierarchy
├── tron-events/         # Event store, SQLite backend, migrations
├── tron-settings/       # Settings loader, defaults
├── tron-llm/            # LLM providers (Anthropic, OpenAI, Google), auth, streaming
├── tron-tools/          # Tool implementations (fs, bash, search, browser, web, subagent)
├── tron-skills/         # Skill loader, registry
├── tron-runtime/        # Orchestrator, session manager, agent turn loop
├── tron-server/         # HTTP/WebSocket server, RPC handlers, event bridge
├── tron-embeddings/     # ONNX embedding service, vector repository
└── tron-transcription/  # Native speech-to-text (Whisper)
```

---

## Quick Start

### Prerequisites

- Rust toolchain (`rustup`, `cargo`)
- Xcode 16+ (for iOS app)
- XcodeGen (`brew install xcodegen`)

### Build and Run

```bash
# Build the server
cd packages/agent
cargo build --release

# Run in foreground (development)
./scripts/tron dev

# Or install as a launchd service
./scripts/tron install
```

### First-Time Setup

```bash
./scripts/tron setup    # Check prerequisites, build, create config
./scripts/tron login    # Authenticate with Claude
```

---

## Tools

### Filesystem Tools

| Tool | Description |
|------|-------------|
| `Read` | Read file contents with line numbers |
| `Write` | Write content to files |
| `Edit` | Search and replace within files |
| `Find` | Find files by pattern |
| `Search` | Search file contents with regex |

### System Tools

| Tool | Description |
|------|-------------|
| `Bash` | Execute shell commands with timeout |
| `Remember` | Store and retrieve memory across sessions |

### Browser Tools

| Tool | Description |
|------|-------------|
| `BrowseTheWeb` | CDP-based browser automation with screenshots |
| `OpenURL` | Open URLs (iOS opens Safari via tool event) |

### Web Tools

| Tool | Description |
|------|-------------|
| `WebFetch` | Fetch and summarize web content |
| `WebSearch` | Search the web (requires Brave API key) |

### Sub-Agent Tools

| Tool | Description |
|------|-------------|
| `SpawnSubagent` | Spawn child agent for parallel tasks |
| `QueryAgent` | Check sub-agent status and progress |
| `WaitForAgents` | Wait for sub-agent completion |

### UI Tools

| Tool | Description |
|------|-------------|
| `AskUserQuestion` | Prompt user for input |
| `NotifyApp` | Send push notification to iOS |
| `TaskManager` | Create/update task lists |
| `RenderAppUI` | Render custom UI in iOS app |

---

## Customization

### Settings

**Location:** `~/.tron/settings.json`

Server-authoritative — the Rust server reads settings directly on startup. iOS reads/writes via `settings.get`/`settings.update` RPC methods.

### Skills

Reusable context packages with optional YAML frontmatter.

**Locations:**
- `~/.tron/skills/` — Global (all projects)
- `.claude/skills/` or `.tron/skills/` — Project (higher precedence)

**Usage:** Reference with `@skill-name` in prompts.

### Hooks

Pre/post tool execution hooks for automation and safety.

---

## Deployment

### Service Management

```bash
tron status          # Show service status
tron start           # Start launchd service
tron stop            # Stop service
tron restart         # Restart service
tron logs            # Query database logs
tron errors          # Show recent errors
```

### Deploy Pipeline

```bash
tron deploy          # Build, test, stop, swap binary, start, health check
tron deploy --force  # Skip confirmations
tron rollback        # Restore previous binary
```

The deploy process:
1. Builds release binary (`cargo build --release`)
2. Runs full test suite (`cargo test --workspace`)
3. Backs up current binary (`~/.tron/tron` → `~/.tron/tron.bak`)
4. Stops service, copies new binary, starts service
5. Health checks (5 attempts, 3s apart)
6. Auto-rollback on failure

### File Locations

```
~/.tron/
├── tron                 # Server binary
├── database/            # SQLite databases (prod.db)
├── settings.json        # Global settings
├── auth.json            # OAuth tokens
├── skills/              # Global skills
├── mods/apns/           # APNS credentials
├── notes/               # Agent notes
└── artifacts/
    ├── server.log       # Production logs
    ├── deployed-commit  # Git commit tracking
    └── canvases/        # Generated artifacts
```

---

## iOS App

### Setup

```bash
brew install xcodegen
cd packages/ios-app
xcodegen generate
open TronMobile.xcodeproj
```

### Features

- Real-time chat with streaming responses
- Session management (create, fork, resume)
- Event-sourced state reconstruction
- Push notifications for background alerts
- Voice transcription input
- Custom UI rendering via RenderAppUI tool

**Documentation:** See `packages/ios-app/docs/`

---

## API Reference

### WebSocket Connection

```
ws://localhost:9847/ws
```

All messages use JSON-RPC 2.0 format.

### Health Endpoint

```
GET http://localhost:9847/health

Response: { "status": "ok" }
```

---

## License

MIT
