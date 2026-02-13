# Migration Status: TypeScript -> Rust

Tracks feature parity between `packages/agent/` (TypeScript) and `packages/agent-rs/` (Rust).

Legend: `[x]` = implemented + tested, `[-]` = in progress, `[ ]` = not started

---

## Phase 0: Scaffolding
- [x] Cargo workspace with 23 crates
- [x] `rust-toolchain.toml`
- [x] CI script (`scripts/ci.sh`)
- [x] Architecture docs
- [x] Migration status doc (this file)
- [x] Patterns doc

## Phase 1: tron-core

### Branded IDs
- [ ] `EventId` newtype
- [ ] `SessionId` newtype
- [ ] `WorkspaceId` newtype
- [ ] Serde (de)serialization for all IDs
- [ ] `Display`, `FromStr`, `Deref<Target=str>` impls

### Messages
- [ ] `Message` enum (`User`, `Assistant`, `ToolResult`)
- [ ] `UserMessage` struct
- [ ] `AssistantMessage` struct
- [ ] `ToolResultMessage` struct
- [ ] Serde roundtrip compatibility with TypeScript JSON format

### Content Blocks
- [ ] `ContentBlock` enum
- [ ] `TextContent`
- [ ] `ImageContent`
- [ ] `ThinkingContent`
- [ ] `ToolUseContent`
- [ ] `ToolResultContent`

### Tool Types
- [ ] `TronToolResult` struct
- [ ] `ToolCall` struct
- [ ] `ToolContent` enum

### Errors
- [ ] `TronError` enum (via thiserror)
- [ ] `RpcError` hierarchy
- [ ] Error codes: NOT_FOUND, UNAUTHORIZED, SESSION_BUSY, AGENT_ABORTED, TOOL_NOT_FOUND
- [ ] JSON-RPC standard error codes (-32600 through -32603, -32700)

### Stream Events
- [ ] `StreamEvent` enum (TextDelta, ThinkingDelta, ToolCallStart, ToolCallDelta, Done, Error)

### Utilities
- [ ] Retry logic (exponential backoff)
- [ ] Content normalization

## Phase 2: tron-events

### Event Types (42 variants)
- [ ] `SessionEvent` tagged enum with `#[serde(tag = "type")]`
- [ ] `BaseEvent` struct (id, session_id, workspace_id, parent_id, sequence, timestamp)
- [ ] Session events: `session.start`, `session.end`, `session.fork`
- [ ] Message events: `message.user`, `message.assistant`
- [ ] Tool events: `tool.call`, `tool.result`
- [ ] Stream events: `stream.text_delta`, `stream.thinking_delta`
- [ ] Config events: `config.model_switch`, `config.prompt_update`
- [ ] Compact events: `compact.boundary`, `compact.summary`
- [ ] Worktree events: `worktree.acquired`, `worktree.commit`, `worktree.released`
- [ ] Rules events: `rules.loaded`
- [ ] Subagent events: `subagent.spawned`, `subagent.status_update`, `subagent.completed`
- [ ] Error events: `error.agent`, `error.tool`, `error.provider`
- [ ] Memory events: `memory.ledger`
- [ ] Type guards (pattern matching)

### EventStore
- [ ] `createSession()` - initialize session
- [ ] `appendEvent()` - add event to log
- [ ] `getEvents()` - retrieve event sequence
- [ ] `search()` - full-text search (FTS5)
- [ ] `fork()` - branch session
- [ ] `rewind()` - restore to checkpoint
- [ ] Ancestor walk (event chain traversal)

### SQLite Backend
- [ ] `SqliteEventStore` facade
- [ ] `EventRepo` repository
- [ ] `SessionRepo` repository
- [ ] `WorkspaceRepo` repository
- [ ] `BlobRepo` repository
- [ ] `SearchRepo` (FTS5)
- [ ] `VectorRepo` (sqlite-vec, feature-gated)
- [ ] Connection pool (`r2d2`)
- [ ] Prepared statement caching

### Event Factory & Chain Builder
- [ ] `EventFactory` (scoped to session/workspace, auto IDs/timestamps)
- [ ] `EventChainBuilder` (parent_id threading)

### Message Reconstruction
- [ ] Two-pass algorithm (collect deletions -> build messages)
- [ ] Compaction-aware reconstruction
- [ ] Thinking block handling

### Migrations
- [ ] Version-tracked SQL migrations
- [ ] `include_str!()` embedded SQL
- [ ] Migration runner at startup
- [ ] Schema compatibility with TypeScript databases

## Phase 3: tron-settings + tron-logging + tron-auth + tron-tokens

### Settings
- [ ] `TronSettings` struct (full schema)
- [ ] `DEFAULT_SETTINGS` compiled defaults
- [ ] `figment` layered config (defaults -> JSON -> env vars)
- [ ] `getSettings()` / `getSetting<T>(path)`
- [ ] `~/.tron/settings.json` persistence
- [ ] Path resolution (`resolveTronPath`, `getTronDataDir`, `getNotesDir`)
- [ ] Hot-reload via file watcher (optional)

### Logging
- [ ] `tracing` subscriber setup
- [ ] SQLite async transport (batched inserts)
- [ ] Per-module spans via `tracing::instrument`
- [ ] Log context propagation (request_id, session_id)
- [ ] Log levels (info, debug, warn, error)

### Authentication
- [ ] `UnifiedAuth` enum: `ApiKey | OAuth { access_token, refresh_token, expires_at }`
- [ ] PKCE generation
- [ ] Authorization URL construction
- [ ] Code-for-token exchange
- [ ] Token refresh with expiry buffer
- [ ] Anthropic OAuth flow
- [ ] Google OAuth flow (Cloud Code Assist + Antigravity)
- [ ] OpenAI OAuth flow (Codex)
- [ ] `~/.tron/auth.json` persistence (sync load, async runtime)
- [ ] `getProviderAuth()` / `getProviderAuthSync()`
- [ ] `saveProviderAuth()` / `clearProviderAuth()`

### Tokens & Cost
- [ ] `TokenStateManager` (per-session tracking)
- [ ] `TokenRecord` (immutable audit trail)
- [ ] Per-provider extraction (Anthropic, Google, OpenAI)
- [ ] Token normalization
- [ ] `getPricingTier(model)` lookup
- [ ] `calculateCost(model, usage)` with cache pricing
- [ ] `createSessionUsage()` / `addRequestUsage()` / `getUsageDelta()`
- [ ] `getContextLimit(model)` / `getContextPercentage()`
- [ ] Cache cost tracking with 4-breakpoint strategy

## Phase 4: tron-llm + Provider Crates

### Provider Trait (tron-llm)
- [ ] `Provider` trait: `id()`, `model()`, `stream()`
- [ ] Shared SSE parser (Anthropic/OpenAI/Google format differences)
- [ ] Stream retry with exponential backoff + jitter
- [ ] Tool call JSON parsing from incremental deltas
- [ ] ID remapping utilities
- [ ] Model registry: `model_id -> ModelInfo`
- [ ] Provider factory: `create_provider(config) -> Box<dyn Provider>`
- [ ] `getModelInfo()` / `getModelsForProvider()` / `getModelCapabilities()`
- [ ] `detectProviderFromModel()` / `validateModelId()`

### Anthropic Provider
- [ ] `AnthropicProvider` implementing `Provider`
- [ ] Message converter (Context -> Anthropic API)
- [ ] Stream handler (message_start, content_block_delta, message_stop)
- [ ] OAuth + API key auth
- [ ] Cache pruning
- [ ] Extended thinking support
- [ ] System prompt prefix for OAuth
- [ ] All Claude models (Opus 4.6, 4.5, Sonnet 4.5, Haiku 4.5)

### Google Provider
- [ ] `GoogleProvider` implementing `Provider`
- [ ] Message converter (Context -> Gemini format with thoughtSignature)
- [ ] Stream handler
- [ ] OAuth (Cloud Code Assist + Antigravity)
- [ ] Safety filter handling
- [ ] All Gemini models (3.x, 2.5)

### OpenAI Provider
- [ ] `OpenAIProvider` implementing `Provider`
- [ ] Message converter (Context -> Chat Completions)
- [ ] Stream handler
- [ ] OAuth (Codex) + API key
- [ ] Reasoning effort configuration
- [ ] All OpenAI models

## Phase 5: tron-context

### Context Manager
- [ ] `ContextManager` (assemble full context)
- [ ] `getSnapshot()` - current context state
- [ ] `previewCompaction()` / `executeCompaction()`
- [ ] `addMessages()` - add turn results
- [ ] `MessageStore` (in-memory message buffer)
- [ ] Token budgeting

### System Prompts
- [ ] `buildSystemPrompt()` - unified builder
- [ ] Provider-specific prompt builders (Anthropic, Google, OpenAI)
- [ ] `TRON_CORE_PROMPT` base template
- [ ] File-based prompt loading

### Compaction
- [ ] `CompactionEngine` (batch compaction logic)
- [ ] `KeywordSummarizer` (fast extraction)
- [ ] `LLMSummarizer` (Haiku-based summarization via Provider trait)
- [ ] Token estimation (character-based)
- [ ] Compaction thresholds

### Rules
- [ ] `discoverRulesFiles()` - find AGENTS.md/CLAUDE.md
- [ ] `RulesTracker` (monitor changes)
- [ ] `RulesIndex` (efficient lookup)
- [ ] Path-scoped rule activation

## Phase 6: tron-hooks + tron-skills + tron-guardrails + tron-memory + tron-tasks

### Hooks
- [ ] `HookEngine` with `HookRegistry` (priority-sorted)
- [ ] `BackgroundTracker`
- [ ] Hook types: PreToolUse, PostToolUse, SessionStart, SessionEnd, Stop, SubagentStop, UserPromptSubmit, PreCompact
- [ ] Hook context factory
- [ ] Hook discovery from filesystem
- [ ] Builtin hooks: memory-ledger, post-tool-use, pre-compact
- [ ] `discoverHooks()` / `loadDiscoveredHooks()` / `watchHooks()`

### Skills
- [ ] `SkillRegistry` (discovery + registration)
- [ ] `SkillLoader` (SKILL.md frontmatter + body parsing)
- [ ] `parseSkillMd()` - frontmatter extraction
- [ ] `buildSkillContext()` - inject into system prompt
- [ ] `SkillTracker` (per-session activation)
- [ ] `skillFrontmatterToDenials()` - tool denial conversion
- [ ] `getSkillSubagentMode()`

### Guardrails
- [ ] `GuardrailEngine` (rule evaluation)
- [ ] Rule types: Pattern, Path, Resource, Context, Composite
- [ ] Severity levels: block, warn, audit
- [ ] Rule tiers: core (immutable), standard, custom
- [ ] `CORE_RULES`: destructive command prevention, ~/.tron protection, ~/.ssh protection
- [ ] `DEFAULT_RULES` comprehensive set
- [ ] `GuardrailAuditLogger`

### Memory
- [ ] `MemoryManager` (compaction + ledger pipeline)
- [ ] `LedgerWriter` (automatic memory entries)
- [ ] `CompactionTrigger`
- [ ] Fail-silent error handling

### Tasks
- [ ] `TaskRepository` (SQLite CRUD)
- [ ] `TaskService` (business logic)
- [ ] `TaskContextBuilder` (LLM context injection)
- [ ] Task/project/area hierarchy

## Phase 7: tron-tools

### Filesystem Tools
- [ ] `ReadTool` - read file contents
- [ ] `WriteTool` - create/overwrite files
- [ ] `EditTool` - apply edits
- [ ] `GlobTool` - file pattern matching (globset)
- [ ] `GrepTool` - content search (ripgrep regex)

### System Tools
- [ ] `BashTool` - shell execution (timeout, truncation, dangerous pattern detection)

### Browser Tools
- [ ] `OpenURLTool` / `BrowseTheWebTool` (CDP)

### Subagent Tools
- [ ] `SpawnSubagentTool`
- [ ] `QueryAgentTool`
- [ ] `WaitForAgentsTool`
- [ ] `SubAgentTracker`

### UI Tools
- [ ] `AskUserQuestionTool` (stop-turn)
- [ ] `NotifyAppTool`
- [ ] `RenderAppUITool`
- [ ] `TaskManagerTool`

### Web Tools
- [ ] `WebFetchTool` (reqwest + scraper + html2text)
- [ ] `WebSearchTool` (Brave + Exa providers, key rotation)
- [ ] `WebCache` (response caching)
- [ ] `HtmlParser` / `UrlValidator` / `Summarizer`

### Communication Tools
- [ ] `SendMessageTool` / `ReceiveMessagesTool`

### Tool Framework
- [ ] `TronTool` trait (name, description, parameters, category, execute)
- [ ] `ToolDenialConfig` / `checkToolDenial()` / `filterToolsByDenial()`
- [ ] `estimateTokens()` / `truncateOutput()`

## Phase 8: tron-runtime

### Agent
- [ ] `TronAgent` (provider, tools, hooks, context manager)
- [ ] `TronAgent::run()` - main turn loop
- [ ] `TronAgent::interrupt()` - graceful stop
- [ ] `AgentEventEmitter` (typed event dispatch)
- [ ] `AgentToolExecutor` (pre/post hooks, cancellation)
- [ ] `AgentStreamProcessor` (accumulate content blocks)
- [ ] `AgentCompactionHandler` (token monitoring, compaction trigger)
- [ ] `AgentTurnRunner` (build context -> LLM -> tools -> events)

### Orchestrator
- [ ] `EventStoreOrchestrator` (multi-session management)
- [ ] `EventPersister` (linearized event writes via MPSC)
- [ ] `TurnManager` (turn lifecycle + content building)
- [ ] `SessionReconstructor` (state reconstruction from events)
- [ ] `SessionContext` (per-session state)
- [ ] `SessionManager` (lifecycle management)
- [ ] `AgentFactory` (dependency injection)
- [ ] `AgentRunner` (skill injection, interrupt handling, agent.ready emission)

### Controllers
- [ ] `ModelController` (switch models mid-session)
- [ ] `NotificationController` (push to iOS)
- [ ] `EmbeddingController` (vector search)

### Operations
- [ ] `ContextOps` (context sheet operations)
- [ ] `SubagentOperations` (spawn, query, waitFor)
- [ ] Worktree operations (buildWorktreeInfo, commitWorkingDirectory)

## Phase 9: tron-rpc + tron-server

### RPC Protocol
- [ ] `MethodRegistry` (parameter validation + middleware)
- [ ] Session handlers: create, get, list, fork, delete, archive
- [ ] Agent handlers: message, abort, respond
- [ ] Model handlers: list, switch
- [ ] Context handlers: get, compact
- [ ] Event handlers: list, sync
- [ ] Settings handlers: get, update
- [ ] Skills handlers: list, get
- [ ] Browser, canvas, device, sandbox, task, transcription, worktree adapters
- [ ] All 30 `RpcEventType` variants as Rust enum
- [ ] `RpcContext` (request state)
- [ ] Error middleware, timing middleware, logging middleware

### Server
- [ ] Axum HTTP server (health, static assets)
- [ ] WebSocket gateway (connection management, heartbeat, message dispatch)
- [ ] Event broadcasting via `tokio::sync::broadcast`
- [ ] Event envelope construction matching `BroadcastEventType`
- [ ] Graceful shutdown (`tokio::signal` + `CancellationToken`)
- [ ] CLI entry point (clap)

## Phase 10: tron-platform

### Browser (CDP)
- [ ] CDP connection management
- [ ] Capture handler
- [ ] Input handler
- [ ] Navigation handler
- [ ] Query handler
- [ ] State handler

### APNS
- [ ] JWT signing
- [ ] HTTP/2 push to Apple servers

### Worktrees
- [ ] `gix` git worktree create/merge/cleanup
- [ ] Per-session isolation
- [ ] `WorktreeCoordinator`

### Transcription
- [ ] Sidecar process management
- [ ] `AudioTranscriber` interface

### Canvas
- [ ] Canvas store
- [ ] Export: JSON, Markdown, PDF

## Phase 11: tron-embeddings

- [ ] ONNX inference via `ort` (q4 quantization)
- [ ] Qwen3-Embedding-0.6B model loading
- [ ] Tokenization + inference + last-token pooling
- [ ] Matryoshka truncation (1024d -> 512d) + L2 normalization
- [ ] sqlite-vec integration (via tron-events VectorRepo)
- [ ] Batch processing for memory backfill
- [ ] `buildEmbeddingText()` preprocessing

## Phase 12: Integration Testing + Packaging

### Protocol Compatibility
- [ ] Record TypeScript WebSocket sessions
- [ ] Replay against Rust server
- [ ] Diff outputs (normalize timestamps/IDs)

### Database Compatibility
- [ ] Read TypeScript-created databases
- [ ] Verify identical query results

### End-to-End Tests
- [ ] Create session -> send message -> streaming events -> tool execution -> persistence
- [ ] Context compaction flow
- [ ] Session fork flow
- [ ] Model switch flow
- [ ] Subagent spawn/complete flow
- [ ] Error handling flows
- [ ] Interrupt/abort flow

### Performance
- [ ] Latency benchmarks vs TypeScript
- [ ] Memory usage benchmarks
- [ ] Throughput benchmarks

### Packaging
- [ ] `cargo build --release` with LTO + strip
- [ ] Binary size < 50MB
- [ ] No unexpected dynamic deps
- [ ] `scripts/tron` support for `TRON_BACKEND=rust`

### Validation Gate
- [ ] All protocol compatibility tests pass
- [ ] Rust reads production TypeScript database
- [ ] iOS full feature test against Rust server
- [ ] Performance parity or better
- [ ] 2-week shadow period (both servers, comparing responses)
