/**
 * @fileoverview Agent Adapter
 *
 * Adapts EventStoreOrchestrator agent methods to the AgentManager
 * interface expected by RpcContext. Handles agent prompts, abort,
 * and state retrieval.
 */

import { randomUUID } from 'crypto';
import { createLogger, categorizeError, LogErrorCategory } from '../../../logging/index.js';
import { SkillRegistry } from '../../../skills/index.js';
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
        const session = await orchestrator.sessions.getSession(sessionId);
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
      // Generate unique runId for this agent run
      // This correlates all events emitted during this run
      const runId = randomUUID();

      // Log incoming prompt params for debugging skills/spells
      logger.info('[RPC] agent.prompt received', {
        sessionId: params.sessionId,
        runId,
        promptLength: params.prompt?.length ?? 0,
        hasSkills: !!params.skills,
        skillCount: params.skills?.length ?? 0,
        skillNames: params.skills?.map(s => s.name) ?? [],
        hasSpells: !!params.spells,
        spellCount: params.spells?.length ?? 0,
        spellNames: params.spells?.map(s => s.name) ?? [],
      });

      // Create a skill loader for this session
      const skillLoader = createSkillLoader(params.sessionId);

      // Start the agent run asynchronously - response will be streamed via events
      orchestrator.agent.run({
        sessionId: params.sessionId,
        prompt: params.prompt,
        reasoningLevel: params.reasoningLevel,
        images: params.images,
        attachments: params.attachments,
        skills: params.skills,
        spells: params.spells,
        skillLoader,
        runId, // Pass runId for event correlation
      }).catch(err => {
        const structured = categorizeError(err, { sessionId: params.sessionId, runId, operation: 'agent_run' });
        logger.error('Agent run error', {
          sessionId: params.sessionId,
          runId,
          code: structured.code,
          category: LogErrorCategory.SESSION_STATE,
          error: structured.message,
          retryable: structured.retryable,
        });
      });

      // Return acknowledgement with runId for event correlation
      return { acknowledged: true, runId };
    },

    /**
     * Abort a running agent
     */
    async abort(sessionId) {
      const cancelled = await orchestrator.agent.cancel(sessionId);
      return { aborted: cancelled };
    },

    /**
     * Get current agent state
     */
    async getState(sessionId) {
      const active = orchestrator.getActiveSession(sessionId);
      const session = await orchestrator.sessions.getSession(sessionId);

      // Get ACTUAL agent message count (not just DB count) for debugging
      const agentState = active?.agent.getState();

      // Check if session was interrupted (from active session flag or from persisted events)
      let wasInterrupted = active?.wasInterrupted ?? false;
      if (!wasInterrupted && session) {
        // Check if the last assistant message was interrupted
        wasInterrupted = await orchestrator.sessions.wasSessionInterrupted(sessionId);
      }

      const isRunning = active?.sessionContext?.isProcessing() ?? false;
      return {
        isRunning,
        currentTurn: agentState?.currentTurn ?? 0,
        messageCount: agentState?.messages.length ?? session?.messageCount ?? 0,
        tokenUsage: {
          input: agentState?.tokenUsage?.inputTokens ?? 0,
          output: agentState?.tokenUsage?.outputTokens ?? 0,
        },
        model: session?.model ?? 'unknown',
        tools: [],
        currentTurnText: isRunning
          ? active!.sessionContext.getAccumulatedContent().text
          : undefined,
        currentTurnToolCalls: isRunning
          ? active!.sessionContext.getAccumulatedContent().toolCalls
          : undefined,
        wasInterrupted,
      };
    },
  };
}
