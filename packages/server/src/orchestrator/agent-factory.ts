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
import {
  createLogger,
  TronAgent,
  ReadTool,
  WriteTool,
  EditTool,
  BashTool,
  GrepTool,
  FindTool,
  LsTool,
  AgentWebBrowserTool,
  AskUserQuestionTool,
  OpenBrowserTool,
  AstGrepTool,
  RenderAppUITool,
  SpawnSubagentTool,
  QuerySubagentTool,
  WaitForSubagentTool,
  TodoWriteTool,
  NotifyAppTool,
  detectProviderFromModel,
  type AgentConfig,
  type TronTool,
  type SessionId,
  type ServerAuth,
  type GoogleAuth,
  type BrowserDelegate,
  type SpawnSubagentParams,
  type SubagentQueryType,
  type TronEvent,
  type SubAgentTracker,
  type TodoItem,
  type NotifyAppResult,
  type UnifiedAuth,
} from '@tron/core';

const logger = createLogger('agent-factory');

// =============================================================================
// Helpers
// =============================================================================

/**
 * Normalize auth to UnifiedAuth format for provider factory.
 * GoogleAuth has optional fields, but UnifiedAuth requires specific shapes.
 */
function normalizeToUnifiedAuth(auth: ServerAuth | GoogleAuth): UnifiedAuth {
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

export interface AgentFactoryConfig {
  /** Get authentication for a model (returns GoogleAuth for Google models) */
  getAuthForProvider: (model: string) => Promise<ServerAuth | GoogleAuth>;
  /** Spawn subsession callback - toolCallId included for event correlation */
  spawnSubsession: (parentId: string, params: SpawnSubagentParams, toolCallId?: string) => Promise<any>;
  /** Query subagent callback */
  querySubagent: (sessionId: string, queryType: SubagentQueryType, limit?: number) => any;
  /** Wait for subagents callback */
  waitForSubagents: (sessionIds: string[], mode: 'all' | 'any', timeout: number) => Promise<any>;
  /** Forward agent event callback */
  forwardAgentEvent: (sessionId: SessionId, event: TronEvent) => void;
  /** Get SubAgentTracker for a session (for blocking SpawnSubagent) */
  getSubagentTrackerForSession: (sessionId: string) => SubAgentTracker | undefined;
  /** Callback when todos are updated via TodoWrite tool */
  onTodosUpdated: (sessionId: string, todos: TodoItem[]) => Promise<void>;
  /** Generate unique ID for todos */
  generateTodoId: () => string;
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
    }
  ) => Promise<NotifyAppResult>;
  /** Browser service (optional) */
  browserService?: {
    execute: (sessionId: string, action: string, params: any) => Promise<any>;
    createSession: (sessionId: string) => Promise<void>;
    startScreencast: (sessionId: string, options: any) => Promise<void>;
    hasSession: (sessionId: string) => boolean;
  };
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
   */
  async createAgentForSession(
    sessionId: SessionId,
    workingDirectory: string,
    model: string,
    systemPrompt?: string,
    isSubagent?: boolean
  ): Promise<TronAgent> {
    // Get auth for the model (handles Codex OAuth vs standard auth)
    const auth = await this.config.getAuthForProvider(model);
    const providerType = detectProviderFromModel(model);

    // Create BrowserDelegate for BrowserTool
    let browserDelegate: BrowserDelegate | undefined;
    if (this.config.browserService) {
      const service = this.config.browserService;
      browserDelegate = {
        execute: (sid, action, params) => service.execute(sid, action as any, params),
        ensureSession: async (sid) => {
          await service.createSession(sid);
          // Auto-start streaming so frames flow to iOS immediately
          // everyNthFrame: 6 means ~10 FPS (60Hz / 6 = 10 FPS)
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

    // AskUserQuestion uses async mode - no delegate needed
    // Questions are presented immediately, user answers as a new prompt
    const tools: TronTool[] = [
      new ReadTool({ workingDirectory }),
      new WriteTool({ workingDirectory }),
      new EditTool({ workingDirectory }),
      new BashTool({ workingDirectory }),
      new GrepTool({ workingDirectory }),
      new FindTool({ workingDirectory }),
      new LsTool({ workingDirectory }),
      new AgentWebBrowserTool({ workingDirectory, delegate: browserDelegate, sessionId }),
      new AskUserQuestionTool({ workingDirectory }),
      new OpenBrowserTool({ workingDirectory }),
      new AstGrepTool({ workingDirectory }),
      new RenderAppUITool({ workingDirectory }),
      new TodoWriteTool({
        generateId: () => this.config.generateTodoId(),
        onTodosUpdated: (todos) => this.config.onTodosUpdated(sessionId, todos),
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

    // Sub-agent tools: Only add SpawnSubagent for top-level agents.
    // Subagents cannot spawn their own subagents to prevent complexity and infinite recursion.
    // QuerySubagent and WaitForSubagent are also excluded since they only make sense
    // when spawning is allowed.
    if (!isSubagent) {
      tools.push(
        new SpawnSubagentTool({
          sessionId,
          workingDirectory,
          model,
          onSpawn: (parentId: string, params: SpawnSubagentParams, toolCallId: string) =>
            this.config.spawnSubsession(parentId, params, toolCallId),
          getSubagentTracker: () => {
            const tracker = this.config.getSubagentTrackerForSession(sessionId);
            if (!tracker) {
              throw new Error(`No subagent tracker for session ${sessionId}`);
            }
            return tracker;
          },
        }),
        new QuerySubagentTool({
          onQuery: (sid: string, queryType: SubagentQueryType, limit?: number) =>
            this.config.querySubagent(sid, queryType, limit),
        }),
        new WaitForSubagentTool({
          onWait: (sessionIds: string[], mode: 'all' | 'any', timeout: number) =>
            this.config.waitForSubagents(sessionIds, mode, timeout),
        }),
      );
    }

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
    });

    // Normalize auth to UnifiedAuth format for provider factory
    const normalizedAuth = normalizeToUnifiedAuth(auth);

    const agentConfig: AgentConfig = {
      provider: {
        model,
        auth: normalizedAuth,
        googleEndpoint,
      },
      tools,
      systemPrompt: prompt,
      maxTurns: 50,
    };

    const agent = new TronAgent(agentConfig, {
      sessionId,
      workingDirectory,
    });

    agent.onEvent((event) => {
      this.config.forwardAgentEvent(sessionId, event);
    });

    return agent;
  }
}

// =============================================================================
// Factory Function
// =============================================================================

export function createAgentFactory(config: AgentFactoryConfig): AgentFactory {
  return new AgentFactory(config);
}
