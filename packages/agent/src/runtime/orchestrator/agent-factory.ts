/**
 * @fileoverview Agent Factory
 *
 * Extracts agent creation logic from EventStoreOrchestrator:
 * - Tool instantiation
 * - Browser delegate setup
 * - Agent configuration
 *
 * Phase 7 of orchestrator refactoring.
 */
// Direct imports to avoid circular dependencies through index.js
import { createLogger } from '@infrastructure/logging/index.js';
import { TronAgent } from '../agent/tron-agent.js';
import type { AgentConfig } from '../agent/types.js';
import {
  ReadTool,
  WriteTool,
  EditTool,
  BashTool,
  SearchTool,
  FindTool,
  BrowseTheWebTool,
  AskUserQuestionTool,
  OpenURLTool,
  RenderAppUITool,
  SpawnSubagentTool,
  QueryAgentTool,
  WaitForAgentsTool,
  TodoWriteTool,
  NotifyAppTool,
  WebFetchTool,
  UnifiedSearchTool,
  BraveProvider,
  ExaProvider,
  RememberTool,
  filterToolsByDenial,
  type BrowserDelegate,
  type SpawnSubagentParams,
  type SpawnSubagentResult,
  type QueryAgentResult,
  type WaitForAgentsResult,
  type SubagentQueryType,
  type SubAgentTracker,
  type NotifyAppResult,
  type ToolDenialConfig,
  type WebFetchSubagentCallback,
  type WebFetchSubagentResult,
  type SearchProvider,
} from '@capabilities/tools/index.js';
import type { TronTool } from '@core/types/tools.js';
import type { SessionId } from '@infrastructure/events/types.js';
import type { TronEvent } from '@core/types/events.js';
import type { TodoItem } from '@capabilities/todos/types.js';
import { detectProviderFromModel, getModelCapabilities, type UnifiedAuth } from '@llm/providers/factory.js';
import type { ServerAuth } from '@infrastructure/auth/types.js';
import { WEB_CONTENT_SUMMARIZER_PROMPT } from '@context/system-prompts.js';
import { createMemoryLedgerHook } from '@capabilities/extensions/hooks/builtin/memory-ledger.js';
import { LedgerWriter, CompactionTrigger, MemoryManager } from '@capabilities/memory/index.js';
import { LLMSummarizer } from '@context/llm-summarizer.js';
import type { EventType } from '@infrastructure/events/types/index.js';
import type { GoogleAuth } from '@infrastructure/auth/google-oauth.js';
import { getSettings } from '@infrastructure/settings/index.js';
import { SUBAGENT_MAX_TOKENS_MULTIPLIER, SUBAGENT_EXCLUDED_TOOLS } from '../constants.js';

const logger = createLogger('agent-factory');

// =============================================================================
// Helpers
// =============================================================================

/**
 * Normalize auth to UnifiedAuth format for provider factory.
 * GoogleAuth has optional fields, but UnifiedAuth requires specific shapes.
 */
export function normalizeToUnifiedAuth(auth: ServerAuth | GoogleAuth): UnifiedAuth {
  if (auth.type === 'api_key') {
    // For API key auth, use apiKey from GoogleAuth or ServerAuth
    const apiKey = 'apiKey' in auth ? auth.apiKey : undefined;
    if (!apiKey) {
      throw new Error('API key auth missing apiKey');
    }
    return { type: 'api_key', apiKey };
  } else {
    // For OAuth auth, use accessToken/refreshToken/expiresAt
    const accessToken = 'accessToken' in auth ? auth.accessToken : undefined;
    const refreshToken = 'refreshToken' in auth ? auth.refreshToken : undefined;
    const expiresAt = 'expiresAt' in auth ? auth.expiresAt : undefined;
    if (!accessToken || !refreshToken || expiresAt === undefined) {
      throw new Error('OAuth auth missing required fields');
    }
    return { type: 'oauth', accessToken, refreshToken, expiresAt };
  }
}

// =============================================================================
// Types
// =============================================================================

type SpawnSubsessionResult = SpawnSubagentResult & {
  /** Legacy field kept for compatibility with older spawn implementations. */
  resultSummary?: string;
};

export interface AgentFactoryConfig {
  /** Get authentication for a model (returns GoogleAuth for Google models) */
  getAuthForProvider: (model: string) => Promise<ServerAuth | GoogleAuth>;
  /** Subagent management callbacks */
  subagents: {
    /** Spawn subsession - toolCallId included for event correlation */
    spawn: (parentId: string, params: SpawnSubagentParams, toolCallId?: string) => Promise<SpawnSubsessionResult>;
    /** Query subagent status/events/output */
    query: (sessionId: string, queryType: SubagentQueryType, limit?: number) => Promise<QueryAgentResult>;
    /** Wait for subagent completion */
    wait: (sessionIds: string[], mode: 'all' | 'any', timeout: number) => Promise<WaitForAgentsResult>;
    /** Get SubAgentTracker for a session (for blocking SpawnAgent) */
    getTracker: (sessionId: string) => SubAgentTracker | undefined;
  };
  /** Forward agent event to orchestrator */
  forwardAgentEvent: (sessionId: SessionId, event: TronEvent) => void;
  /** Todo management callbacks */
  todos: {
    /** Callback when todos are updated via TodoWrite tool */
    onUpdated: (sessionId: string, todos: TodoItem[]) => Promise<void>;
    /** Generate unique ID for todos */
    generateId: () => string;
  };
  /** Path to shared SQLite database (for tmux mode agent spawning) */
  dbPath: string;
  /** Anthropic API key for WebFetch summarizer (optional - enables WebFetch if provided) */
  anthropicApiKey?: string;
  /** Brave Search API keys (optional - enables WebSearch if provided) */
  braveSearchApiKeys?: string[];
  /** @deprecated Use braveSearchApiKeys instead */
  braveSearchApiKey?: string;
  /** Exa Search API key (optional - enables semantic search, tweets, research) */
  exaApiKey?: string;
  /** Blocked domains for web tools (optional) */
  blockedWebDomains?: string[];
  /** Callback for sending push notifications (optional) */
  onNotify?: (
    sessionId: string,
    notification: {
      title: string;
      body: string;
      data?: Record<string, string>;
      priority?: 'high' | 'normal';
      sound?: string;
      badge?: number;
    },
    /** The tool call ID - used for deep linking so iOS can scroll to the notification */
    toolCallId: string
  ) => Promise<NotifyAppResult>;
  /** Memory system callbacks (optional — enables memory ledger for non-subagent sessions) */
  memoryConfig?: {
    /** Append an event to the session */
    appendEvent: (sessionId: string, type: EventType, payload: Record<string, unknown>) => Promise<{ id: string }>;
    /** Get all events for a session */
    getEventsBySession: (sessionId: string) => Promise<import('@infrastructure/events/types/index.js').SessionEvent[]>;
    /** Emit memory_updated event to WebSocket clients */
    emitMemoryUpdated: (data: { sessionId: string; title?: string; entryType?: string }) => void;
    /** Get current context token ratio for a session */
    getTokenRatio: (sessionId: string) => number;
    /** Get recent event types from the current cycle (queries EventStore) */
    getRecentEventTypes: (sessionId: string) => Promise<string[]>;
    /** Get recent Bash tool call commands (queries EventStore) */
    getRecentToolCalls: (sessionId: string) => Promise<string[]>;
    /** Execute compaction for a session */
    executeCompaction: (sessionId: string) => Promise<{ success: boolean }>;
    /** Embed a memory ledger entry for semantic search (optional) */
    embedMemory?: (eventId: string, workspaceId: string, payload: Record<string, unknown>) => Promise<void>;
    /** Get workspace ID for a session */
    getWorkspaceId?: (sessionId: string) => string;
  };
  /** Embedding service for semantic search in Remember tool (optional) */
  embeddingService?: import('@infrastructure/embeddings/index.js').EmbeddingService;
  /** Vector repository for semantic search in Remember tool (optional) */
  vectorRepo?: import('@infrastructure/events/sqlite/repositories/vector.repo.js').VectorRepository;
  /** Browser service (optional) */
  browserService?: {
    execute: (sessionId: string, action: string, params: Record<string, unknown>) => Promise<{
      success: boolean;
      data?: Record<string, unknown>;
      error?: string;
    }>;
    createSession: (sessionId: string) => Promise<void>;
    startScreencast: (sessionId: string, options: Record<string, unknown>) => Promise<void>;
    hasSession: (sessionId: string) => boolean;
  };
}

// =============================================================================
// Extracted Helpers
// =============================================================================

/**
 * Create a BrowserDelegate wiring to the browser service.
 * Auto-starts screencast for iOS frame streaming on session creation.
 */
function createBrowserDelegate(
  service: NonNullable<AgentFactoryConfig['browserService']>,
): BrowserDelegate {
  return {
    execute: (sid, action, params) => service.execute(sid, action, params),
    ensureSession: async (sid) => {
      await service.createSession(sid);
      await service.startScreencast(sid, {
        format: 'jpeg',
        quality: 60,
        maxWidth: 1280,
        maxHeight: 800,
        everyNthFrame: 6,
      });
    },
    hasSession: (sid) => service.hasSession(sid),
  };
}

/**
 * Create the WebFetch summarizer callback.
 * Spawns a no-tools Haiku subagent session for web content summarization.
 */
function createWebFetchSummarizer(
  sessionId: SessionId,
  spawnSubsession: AgentFactoryConfig['subagents']['spawn'],
): WebFetchSubagentCallback {
  return async (params): Promise<WebFetchSubagentResult> => {
    try {
      const result = await spawnSubsession(sessionId, {
        task: params.task,
        model: params.model,
        systemPrompt: WEB_CONTENT_SUMMARIZER_PROMPT,
        toolDenials: { denyAll: true },
        maxTurns: params.maxTurns,
        blocking: true,
        timeout: params.timeout,
      });

      return {
        sessionId: result.sessionId || `summarizer-${Date.now()}`,
        success: result.success !== false,
        output: result.output || result.summary || result.resultSummary,
        error: result.error,
        tokenUsage: result.tokenUsage,
      };
    } catch (error) {
      const err = error as Error;
      logger.error('WebFetch subagent spawn failed', { error: err.message });
      return {
        sessionId: `summarizer-error-${Date.now()}`,
        success: false,
        error: err.message,
      };
    }
  };
}

/**
 * Wire the memory ledger hook into an agent.
 * Sets up CompactionTrigger → LedgerWriter → MemoryManager pipeline.
 */
function wireMemoryLedger(
  agent: TronAgent,
  sessionId: SessionId,
  model: string,
  workingDirectory: string,
  memCfg: NonNullable<AgentFactoryConfig['memoryConfig']>,
  compactorSettings: ReturnType<typeof getSettings>['context']['compactor'],
  spawnSubsession: AgentFactoryConfig['subagents']['spawn'],
): void {
  const compactionTrigger = new CompactionTrigger({
    triggerTokenThreshold: compactorSettings.triggerTokenThreshold,
    alertZoneThreshold: compactorSettings.alertZoneThreshold,
    defaultTurnFallback: compactorSettings.defaultTurnFallback,
    alertTurnFallback: compactorSettings.alertTurnFallback,
  });
  if (compactorSettings.forceAlways) {
    compactionTrigger.setForceAlways(true);
    logger.info('Compaction force-always enabled', { sessionId });
  }

  const ledgerWriter = new LedgerWriter({
    spawnSubsession: (params) => spawnSubsession(sessionId, {
      task: params.task,
      model: params.model,
      systemPrompt: params.systemPrompt,
      toolDenials: params.toolDenials,
      maxTurns: params.maxTurns,
      blocking: params.blocking,
      timeout: params.timeout,
    }),
    appendEvent: (params) => memCfg.appendEvent(sessionId, params.type, params.payload),
    getEventsBySession: () => memCfg.getEventsBySession(sessionId),
    sessionId,
    workspaceId: '',
  });

  const workspaceId = memCfg.getWorkspaceId?.(sessionId) ?? '';
  const memoryManager = new MemoryManager({
    writeLedgerEntry: (opts) => ledgerWriter.writeLedgerEntry(opts),
    shouldCompact: (input) => compactionTrigger.shouldCompact(input),
    resetCompactionTrigger: () => compactionTrigger.reset(),
    executeCompaction: () => memCfg.executeCompaction(sessionId),
    emitMemoryUpdated: (data) => memCfg.emitMemoryUpdated(data),
    embedMemory: memCfg.embedMemory,
    isLedgerEnabled: () => getSettings().context.memory.ledger?.enabled ?? true,
    sessionId,
    workspaceId,
  });

  agent.registerHook(createMemoryLedgerHook({
    onCycleComplete: (info) => memoryManager.onCycleComplete(info),
    getModel: () => model,
    getWorkingDirectory: () => workingDirectory,
    getTokenRatio: () => memCfg.getTokenRatio(sessionId),
    getRecentEventTypes: () => memCfg.getRecentEventTypes(sessionId),
    getRecentToolCalls: () => memCfg.getRecentToolCalls(sessionId),
  }));

  logger.debug('Memory ledger hook registered', { sessionId });
}

// =============================================================================
// AgentFactory Class
// =============================================================================

export class AgentFactory {
  private config: AgentFactoryConfig;

  constructor(config: AgentFactoryConfig) {
    this.config = config;
  }

  /**
   * Create an agent for a session with all configured tools.
   *
   * @param isSubagent - If true, excludes SpawnSubagent tool to prevent nested subagent spawning.
   *                     Subagents cannot spawn their own subagents to avoid complexity and
   *                     potential infinite recursion. This restriction may be relaxed in the future.
   * @param toolDenials - Tool denial configuration. Subagent inherits all parent tools minus denials.
   *                      - undefined: all tools available (default for agent type)
   *                      - { denyAll: true }: no tools (text generation only)
   *                      - { tools: ['Bash', 'Write'] }: deny specific tools
   */
  async createAgentForSession(
    sessionId: SessionId,
    workingDirectory: string,
    model: string,
    systemPrompt?: string,
    isSubagent?: boolean,
    toolDenials?: ToolDenialConfig,
  ): Promise<TronAgent> {
    // Get auth for the model (handles Codex OAuth vs standard auth)
    const auth = await this.config.getAuthForProvider(model);
    const providerType = detectProviderFromModel(model);

    // Read settings from settings.json (server-authoritative)
    const settings = getSettings();
    const compactorSettings = settings.context.compactor;
    const webSettings = settings.tools.web;

    // Create BrowserDelegate for BrowserTool
    const browserDelegate = this.config.browserService
      ? createBrowserDelegate(this.config.browserService)
      : undefined;

    // AskUserQuestion uses async mode - no delegate needed
    // Questions are presented immediately, user answers as a new prompt
    // Build ALL tools first, then apply denial filtering at the end
    let tools: TronTool<never>[] = [
      new ReadTool({ workingDirectory }),
      new WriteTool({ workingDirectory }),
      new EditTool({ workingDirectory }),
      new BashTool({ workingDirectory }),
      new SearchTool({ workingDirectory }),
      new FindTool({ workingDirectory }),
      new BrowseTheWebTool({ workingDirectory, delegate: browserDelegate, sessionId }),
      new AskUserQuestionTool({ workingDirectory }),
      new OpenURLTool({ workingDirectory }),
      new RenderAppUITool({ workingDirectory }),
      new TodoWriteTool({
        generateId: () => this.config.todos.generateId(),
        onTodosUpdated: (todos) => this.config.todos.onUpdated(sessionId, todos),
      }),
      new RememberTool({
        dbPath: this.config.dbPath,
        embeddingService: this.config.embeddingService,
        vectorRepo: this.config.vectorRepo,
      }),
    ];

    // Add NotifyApp tool if push notifications are configured
    if (this.config.onNotify) {
      tools.push(
        new NotifyAppTool({
          sessionId,
          onNotify: this.config.onNotify,
        })
      );
    }

    // Add WebFetch tool - uses real Tron subagent for summarization
    const webFetchSummarizer = createWebFetchSummarizer(sessionId, this.config.subagents.spawn);

    tools.push(
      new WebFetchTool({
        workingDirectory,
        onSpawnSubagent: webFetchSummarizer,
        http: { timeout: webSettings.fetch.timeoutMs },
        cache: { ttl: webSettings.cache.ttlMs, maxEntries: webSettings.cache.maxEntries },
        urlValidator: { blockedDomains: this.config.blockedWebDomains },
      })
    );

    // Add WebSearch tool (UnifiedSearchTool with Brave + Exa providers)
    // Support both new braveSearchApiKeys array and legacy braveSearchApiKey
    const braveApiKeys = this.config.braveSearchApiKeys?.length
      ? this.config.braveSearchApiKeys
      : this.config.braveSearchApiKey
        ? [this.config.braveSearchApiKey]
        : [];

    const exaApiKey = this.config.exaApiKey;

    // Build providers object
    const searchProviders: { brave?: SearchProvider; exa?: SearchProvider } = {};

    if (braveApiKeys.length > 0) {
      searchProviders.brave = new BraveProvider({ apiKeys: braveApiKeys });
    }

    if (exaApiKey) {
      searchProviders.exa = new ExaProvider({ apiKey: exaApiKey });
    }

    // Add unified search if at least one provider is available
    if (Object.keys(searchProviders).length > 0) {
      tools.push(
        new UnifiedSearchTool({
          providers: searchProviders,
          blockedDomains: this.config.blockedWebDomains,
        })
      );
    }

    // Add subagent management tools (will be filtered out for subagents via denials)
    tools.push(
      new SpawnSubagentTool({
        sessionId,
        workingDirectory,
        model,
        dbPath: this.config.dbPath,
        onSpawn: (parentId: string, params: SpawnSubagentParams, toolCallId: string) =>
          this.config.subagents.spawn(parentId, params, toolCallId),
        getSubagentTracker: () => {
          const tracker = this.config.subagents.getTracker(sessionId);
          if (!tracker) {
            throw new Error(`No subagent tracker for session ${sessionId}`);
          }
          return tracker;
        },
      }),
      new QueryAgentTool({
        onQuery: (sid: string, queryType: SubagentQueryType, limit?: number) =>
          this.config.subagents.query(sid, queryType, limit),
      }),
      new WaitForAgentsTool({
        onWait: (sessionIds: string[], mode: 'all' | 'any', timeout: number) =>
          this.config.subagents.wait(sessionIds, mode, timeout),
      }),
    );

    // Build effective tool denial config:
    // 1. Start with explicit toolDenials from caller
    // 2. If isSubagent, also deny subagent management tools (prevent infinite recursion)
    let effectiveDenials = toolDenials;
    if (isSubagent) {
      const subagentToolsDenial: ToolDenialConfig = {
        tools: [...SUBAGENT_EXCLUDED_TOOLS],
      };
      // Merge with any existing denials
      if (effectiveDenials) {
        effectiveDenials = {
          denyAll: effectiveDenials.denyAll,
          tools: [
            ...(effectiveDenials.tools ?? []),
            ...(subagentToolsDenial.tools ?? []),
          ],
          rules: effectiveDenials.rules,
        };
      } else {
        effectiveDenials = subagentToolsDenial;
      }

      // Remove interactive tools (require user interaction)
      tools = tools.filter(t => !t.interactive);
    }

    // Apply tool denial filtering
    tools = filterToolsByDenial(tools, effectiveDenials);

    // System prompt is now handled by ContextManager based on provider type
    // Only pass custom prompt if explicitly provided - otherwise ContextManager
    // will use TRON_CORE_PROMPT with provider-specific adaptations
    const prompt = systemPrompt; // May be undefined - that's fine

    // Extract Google-specific fields from auth if present
    const googleEndpoint = 'endpoint' in auth
      ? (auth as GoogleAuth).endpoint
      : undefined;

    logger.info('Creating agent with tools', {
      sessionId,
      workingDirectory,
      toolCount: tools.length,
      authType: auth.type,
      isOAuth: auth.type === 'oauth',
      providerType,
      googleEndpoint,
      compactorSettings: {
        preserveRecentCount: compactorSettings.preserveRecentCount,
        forceAlways: compactorSettings.forceAlways,
      },
    });

    // Normalize auth to UnifiedAuth format for provider factory
    const normalizedAuth = normalizeToUnifiedAuth(auth);

    // Check model capabilities for thinking support and output limits
    const capabilities = getModelCapabilities(providerType, model);
    const enableThinking = capabilities.supportsThinking;

    if (enableThinking) {
      logger.info('Enabling thinking for model', { model, providerType });
    }

    let maxTokens: number | undefined;
    if (isSubagent) {
      maxTokens = Math.floor(capabilities.maxOutput * SUBAGENT_MAX_TOKENS_MULTIPLIER);
      logger.info('Setting subagent maxTokens based on model capacity', {
        sessionId,
        model,
        modelMaxOutput: capabilities.maxOutput,
        subagentMaxTokens: maxTokens,
      });
    }

    const agentConfig: AgentConfig = {
      provider: {
        model,
        auth: normalizedAuth,
        googleEndpoint,
      },
      tools,
      systemPrompt: prompt,
      maxTurns: 50,
      maxTokens,  // Set for subagents, undefined for regular agents (uses default)
      enableThinking,
      compaction: {
        preserveRecentTurns: compactorSettings.preserveRecentCount,
      },
    };

    const agent = new TronAgent(agentConfig, {
      sessionId,
      workingDirectory,
    });

    agent.onEvent((event) => {
      this.config.forwardAgentEvent(sessionId, event);
    });

    // Wire LLM summarizer for non-subagent sessions (enables auto-compaction)
    if (!isSubagent) {
      const llmSummarizer = new LLMSummarizer({
        spawnSubsession: (params) => this.config.subagents.spawn(sessionId, params),
      });
      agent.setSummarizer(llmSummarizer);
    }

    // Register memory ledger hook for non-subagent sessions
    if (!isSubagent && this.config.memoryConfig) {
      wireMemoryLedger(
        agent, sessionId, model, workingDirectory,
        this.config.memoryConfig, compactorSettings,
        this.config.subagents.spawn,
      );
    }

    return agent;
  }
}

// =============================================================================
// Factory Function
// =============================================================================

export function createAgentFactory(config: AgentFactoryConfig): AgentFactory {
  return new AgentFactory(config);
}
