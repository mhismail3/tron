/**
 * @fileoverview Agent Adapter
 *
 * Adapts EventStoreOrchestrator agent methods to the AgentManager
 * interface expected by RpcContext. Handles agent prompts, abort,
 * and state retrieval.
 */

import { SkillRegistry, createLogger } from '../../../index.js';
import type { AdapterDependencies, AgentManagerAdapter } from '../types.js';

const logger = createLogger('agent-adapter');

// =============================================================================
// Agent Adapter Factory
// =============================================================================

/**
 * Creates an agent manager adapter that handles agent prompts and state
 *
 * @param deps - Adapter dependencies including the orchestrator
 * @returns AgentManagerAdapter implementation
 */
export function createAgentAdapter(deps: AdapterDependencies): AgentManagerAdapter {
  const { orchestrator } = deps;

  /**
   * Create a skill loader for loading skill content by name
   * This closure captures the session context to load from the correct directory
   */
  function createSkillLoader(sessionId: string) {
    return async (skillNames: string[]) => {
      logger.info('[SKILL-LOADER] skillLoader called', {
        skillNames,
        sessionId,
      });

      try {
        // Get session's working directory
        const session = await orchestrator.getSession(sessionId);
        if (!session?.workingDirectory) {
          logger.warn('[SKILL-LOADER] Cannot load skills - no working directory', { sessionId });
          return [];
        }

        logger.info('[SKILL-LOADER] Loading skills from registry', {
          workingDirectory: session.workingDirectory,
          skillNames,
        });

        // Get or create skill registry for this directory
        const registry = new SkillRegistry({ workingDirectory: session.workingDirectory });
        await registry.initialize();

        logger.info('[SKILL-LOADER] Registry initialized', {
          totalSkills: registry.list().length,
          availableSkills: registry.list().map(s => s.name),
        });

        // Load each skill by name
        const loadedSkills: Array<{ name: string; content: string; frontmatter?: { planMode?: boolean; tools?: string[]; [key: string]: unknown } }> = [];
        for (const name of skillNames) {
          const skill = registry.get(name);
          if (skill) {
            loadedSkills.push({
              name: skill.name,
              content: skill.content,
              frontmatter: skill.frontmatter ? { ...skill.frontmatter } : undefined,
            });
            logger.info('[SKILL-LOADER] Loaded skill content', {
              name: skill.name,
              contentLength: skill.content.length,
              contentPreview: skill.content.substring(0, 100) + '...',
              hasFrontmatter: !!skill.frontmatter,
              planMode: skill.frontmatter?.planMode,
            });
          } else {
            logger.warn('[SKILL-LOADER] Skill not found in registry', {
              name,
              sessionId,
              availableSkills: registry.list().map(s => s.name),
            });
          }
        }

        logger.info('[SKILL-LOADER] Returning loaded skills', {
          requestedCount: skillNames.length,
          loadedCount: loadedSkills.length,
          loadedNames: loadedSkills.map(s => s.name),
        });

        return loadedSkills;
      } catch (err) {
        logger.error('[SKILL-LOADER] Error loading skills', { error: err, sessionId });
        return [];
      }
    };
  }

  return {
    /**
     * Start an agent prompt (fire-and-forget, response streamed via events)
     */
    async prompt(params) {
      // Log incoming prompt params for debugging skills
      logger.info('[RPC] agent.prompt received', {
        sessionId: params.sessionId,
        promptLength: params.prompt?.length ?? 0,
        hasSkills: !!params.skills,
        skillCount: params.skills?.length ?? 0,
        skillNames: params.skills?.map(s => s.name) ?? [],
      });

      // Create a skill loader for this session
      const skillLoader = createSkillLoader(params.sessionId);

      // Start the agent run asynchronously - response will be streamed via events
      orchestrator.runAgent({
        sessionId: params.sessionId,
        prompt: params.prompt,
        reasoningLevel: params.reasoningLevel,
        images: params.images,
        attachments: params.attachments,
        skills: params.skills,
        skillLoader,
      }).catch(err => {
        console.error('Agent run error:', err);
      });

      // Return acknowledgement immediately
      return { acknowledged: true };
    },

    /**
     * Abort a running agent
     */
    async abort(sessionId) {
      const cancelled = await orchestrator.cancelAgent(sessionId);
      return { aborted: cancelled };
    },

    /**
     * Get current agent state
     */
    async getState(sessionId) {
      const active = orchestrator.getActiveSession(sessionId);
      const session = await orchestrator.getSession(sessionId);

      // Get ACTUAL agent message count (not just DB count) for debugging
      const agentState = active?.agent.getState();

      // Check if session was interrupted (from active session flag or from persisted events)
      let wasInterrupted = active?.wasInterrupted ?? false;
      if (!wasInterrupted && session) {
        // Check if the last assistant message was interrupted
        wasInterrupted = await orchestrator.wasSessionInterrupted(sessionId);
      }

      return {
        isRunning: active?.isProcessing ?? false,
        currentTurn: agentState?.currentTurn ?? 0,
        messageCount: agentState?.messages.length ?? session?.messageCount ?? 0,
        tokenUsage: {
          input: agentState?.tokenUsage?.inputTokens ?? 0,
          output: agentState?.tokenUsage?.outputTokens ?? 0,
        },
        model: session?.model ?? 'unknown',
        tools: [],
        // Include current turn content for resume support (only when agent is running)
        currentTurnText: active?.isProcessing
          ? active.sessionContext.getAccumulatedContent().text
          : undefined,
        currentTurnToolCalls: active?.isProcessing
          ? active.sessionContext.getAccumulatedContent().toolCalls
          : undefined,
        // Flag indicating session was interrupted
        wasInterrupted,
      };
    },
  };
}
