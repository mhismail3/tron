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
  BrowserTool,
  AskUserQuestionTool,
  OpenBrowserTool,
  AstGrepTool,
  SpawnSubsessionTool,
  SpawnTmuxAgentTool,
  QuerySubagentTool,
  WaitForSubagentTool,
  detectProviderFromModel,
  type AgentConfig,
  type TronTool,
  type SessionId,
  type ServerAuth,
  type BrowserDelegate,
  type SpawnSubsessionParams,
  type SpawnTmuxAgentParams,
  type SubagentQueryType,
  type TronEvent,
} from '@tron/core';

const logger = createLogger('agent-factory');

// =============================================================================
// Types
// =============================================================================

export interface AgentFactoryConfig {
  /** Get authentication for a model */
  getAuthForProvider: (model: string) => Promise<ServerAuth>;
  /** Get EventStore database path */
  getDbPath: () => string;
  /** Spawn subsession callback */
  spawnSubsession: (parentId: string, params: SpawnSubsessionParams) => Promise<any>;
  /** Spawn tmux agent callback */
  spawnTmuxAgent: (parentId: string, params: SpawnTmuxAgentParams) => Promise<any>;
  /** Query subagent callback */
  querySubagent: (sessionId: string, queryType: SubagentQueryType, limit?: number) => any;
  /** Wait for subagents callback */
  waitForSubagents: (sessionIds: string[], mode: 'all' | 'any', timeout: number) => Promise<any>;
  /** Forward agent event callback */
  forwardAgentEvent: (sessionId: SessionId, event: TronEvent) => void;
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
   */
  async createAgentForSession(
    sessionId: SessionId,
    workingDirectory: string,
    model: string,
    systemPrompt?: string
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
      new BrowserTool({ workingDirectory, delegate: browserDelegate }),
      new AskUserQuestionTool({ workingDirectory }),
      new OpenBrowserTool({ workingDirectory }),
      new AstGrepTool({ workingDirectory }),
      // Sub-agent spawning tools
      new SpawnSubsessionTool({
        sessionId,
        workingDirectory,
        model,
        onSpawn: (parentId: string, params: SpawnSubsessionParams) =>
          this.config.spawnSubsession(parentId, params),
      }),
      new SpawnTmuxAgentTool({
        sessionId,
        workingDirectory,
        model,
        dbPath: this.config.getDbPath(),
        onSpawn: (parentId: string, params: SpawnTmuxAgentParams) =>
          this.config.spawnTmuxAgent(parentId, params),
      }),
      new QuerySubagentTool({
        onQuery: (sid: string, queryType: SubagentQueryType, limit?: number) =>
          this.config.querySubagent(sid, queryType, limit),
      }),
      new WaitForSubagentTool({
        onWait: (sessionIds: string[], mode: 'all' | 'any', timeout: number) =>
          this.config.waitForSubagents(sessionIds, mode, timeout),
      }),
    ];

    // System prompt is now handled by ContextManager based on provider type
    // Only pass custom prompt if explicitly provided - otherwise ContextManager
    // will use TRON_CORE_PROMPT with provider-specific adaptations
    const prompt = systemPrompt; // May be undefined - that's fine

    logger.info('Creating agent with tools', {
      sessionId,
      workingDirectory,
      toolCount: tools.length,
      authType: auth.type,
      isOAuth: auth.type === 'oauth',
      providerType,
    });

    const agentConfig: AgentConfig = {
      provider: {
        model,
        auth, // Use OAuth from Codex tokens or auth.json
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
