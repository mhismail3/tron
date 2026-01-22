/**
 * @fileoverview Skill Loading and Content Transformation
 *
 * Extracts skill-related logic from EventStoreOrchestrator:
 * - Skill context building for prompts
 * - Skill tracking/event persistence
 * - Content transformation for LLM consumption
 *
 * Phase 3 of orchestrator refactoring - skill/context loading logic.
 */
import {
  createLogger,
  buildSkillContext,
  DEFAULT_PLAN_MODE_BLOCKED_TOOLS,
  type SkillSource,
  type SkillAddMethod,
  type SkillMetadata,
  type SkillTracker,
  type UserContent,
} from '../index.js';
import type { SessionContext } from './session-context.js';
import type { AgentRunOptions, LoadedSkillContent } from './types.js';

const logger = createLogger('skill-loader');

// =============================================================================
// Types
// =============================================================================

export interface SkillLoaderConfig {
  // Config kept for future extensibility (e.g., custom skill loaders)
}

export interface SkillLoadContext {
  sessionId: string;
  skillTracker: SkillTracker;
  sessionContext: SessionContext;
}

/**
 * Callback interface for triggering plan mode from skill loader.
 * Allows the orchestrator to wire up plan mode entry without
 * creating a circular dependency.
 */
export interface PlanModeCallback {
  /** Enter plan mode with the given skill name and blocked tools */
  enterPlanMode: (skillName: string, blockedTools: string[]) => Promise<void>;
  /** Check if already in plan mode */
  isInPlanMode: () => boolean;
}

// =============================================================================
// SkillLoader Class
// =============================================================================

export class SkillLoader {
  constructor(_config?: SkillLoaderConfig) {
    // Config reserved for future extensibility
  }

  /**
   * Load skill context for a prompt.
   *
   * Handles:
   * 1. Collecting skills from session tracker and new options
   * 2. Tracking new skills (creates events)
   * 3. Building removed skills instruction
   * 4. Loading skill content via skillLoader callback
   * 5. Building final skill context string
   * 6. Detecting planMode skills and triggering plan mode (if callback provided)
   */
  async loadSkillContextForPrompt(
    context: SkillLoadContext,
    options: AgentRunOptions,
    planModeCallback?: PlanModeCallback
  ): Promise<string> {
    const { sessionId, skillTracker } = context;

    // Get session skills already tracked (persistent across turns)
    const sessionSkills = skillTracker.getAddedSkills();

    // Log incoming skills for debugging
    logger.info('[SKILL] loadSkillContextForPrompt called', {
      sessionId,
      skillsProvided: options.skills?.length ?? 0,
      skills: options.skills?.map((s) => s.name) ?? [],
      sessionSkillCount: sessionSkills.length,
      sessionSkills: sessionSkills.map((s) => s.name),
      hasSkillLoader: !!options.skillLoader,
    });

    // Collect skill names from:
    // 1. Session skills already in tracker (persistent across turns)
    // 2. Newly selected skills from options.skills
    const skillNames: Set<string> = new Set();

    // Add skills already in the session (from skillTracker)
    for (const addedSkill of sessionSkills) {
      skillNames.add(addedSkill.name);
    }

    // Add newly selected skills from options.skills
    if (options.skills && options.skills.length > 0) {
      for (const skill of options.skills) {
        skillNames.add(skill.name);
      }
    }

    // Track skills FIRST (creates events and updates tracker)
    // This must happen BEFORE checking removed skills, so that re-added skills
    // are properly removed from the removedSkillNames set
    if (skillNames.size > 0) {
      await this.trackSkillsForPrompt(context, options);
    }

    // NOW check for removed skills (after tracking, so re-added skills are excluded)
    const removedSkills = skillTracker.getRemovedSkillNames();
    let removedSkillsInstruction = '';
    if (removedSkills.length > 0) {
      const skillList = removedSkills.map((s) => `@${s}`).join(', ');
      removedSkillsInstruction = `<removed-skills>
CRITICAL: The following skills have been REMOVED from this session: ${skillList}

You MUST completely stop applying these skill behaviors starting NOW. This includes:
- Do NOT use any special speaking styles, tones, or personas from these skills
- Do NOT follow any formatting rules from these skills
- Do NOT apply any behavioral modifications from these skills
- Respond in your normal, default manner

The user has explicitly removed these skills and expects you to respond WITHOUT them.
</removed-skills>`;
      logger.info('[SKILL] Including removed skills instruction', {
        sessionId,
        removedSkills,
      });
    }

    // If no skills to add, return just the removed skills instruction (if any)
    if (skillNames.size === 0) {
      logger.info('[SKILL] No skills to load - returning removed skills instruction only', {
        hasRemovedInstruction: removedSkillsInstruction.length > 0,
      });
      return removedSkillsInstruction;
    }

    // If no skill loader provided, we can't load content
    if (!options.skillLoader) {
      logger.warn('[SKILL] Skills referenced but no skillLoader provided', {
        sessionId,
        skillCount: skillNames.size,
        skillNames: Array.from(skillNames),
      });
      return '';
    }

    // Load skill content
    logger.info('[SKILL] Calling skillLoader for skills', {
      skillNames: Array.from(skillNames),
    });
    const loadedSkills = await options.skillLoader(Array.from(skillNames));

    logger.info('[SKILL] skillLoader returned', {
      requestedCount: skillNames.size,
      loadedCount: loadedSkills.length,
      loadedNames: loadedSkills.map((s) => s.name),
    });

    if (loadedSkills.length === 0) {
      logger.warn('[SKILL] No skill content loaded', {
        sessionId,
        requestedSkills: Array.from(skillNames),
      });
      return '';
    }

    // Check for planMode skills and trigger plan mode if needed
    await this.checkAndEnterPlanMode(sessionId, loadedSkills, planModeCallback);

    // Build skill context using buildSkillContext
    // Convert LoadedSkillContent to SkillMetadata format for buildSkillContext
    const skillMetadata: SkillMetadata[] = loadedSkills.map((s) => ({
      name: s.name,
      displayName: s.name,
      content: s.content,
      description: '',
      frontmatter: {},
      source: 'global' as const,
      path: '',
      skillMdPath: '',
      additionalFiles: [],
      lastModified: Date.now(),
    }));

    const skillContext = buildSkillContext(skillMetadata);

    logger.info('[SKILL] Built skill context successfully', {
      sessionId,
      skillCount: loadedSkills.length,
      contextLength: skillContext.length,
      contextPreview: skillContext.substring(0, 200) + '...',
    });

    // Combine removed skills instruction with skill context
    if (removedSkillsInstruction) {
      return `${removedSkillsInstruction}\n\n${skillContext}`;
    }
    return skillContext;
  }

  /**
   * Check loaded skills for planMode flag and enter plan mode if needed.
   *
   * Called after skills are loaded. If any skill has planMode: true in its
   * frontmatter, and we're not already in plan mode, enters plan mode.
   *
   * Blocked tools are computed by inverting the skill's tools list (if specified)
   * or using the default blocked tools (Write, Edit, Bash, NotebookEdit).
   */
  private async checkAndEnterPlanMode(
    sessionId: string,
    loadedSkills: LoadedSkillContent[],
    planModeCallback?: PlanModeCallback
  ): Promise<void> {
    // No callback means plan mode not supported (e.g., in tests)
    if (!planModeCallback) {
      return;
    }

    // Already in plan mode - don't enter again
    if (planModeCallback.isInPlanMode()) {
      logger.debug('[SKILL] Already in plan mode, skipping plan mode check', { sessionId });
      return;
    }

    // Find first skill with planMode: true
    const planModeSkill = loadedSkills.find(skill => skill.frontmatter?.planMode === true);

    if (!planModeSkill) {
      return;
    }

    logger.info('[SKILL] Detected planMode skill, entering plan mode', {
      sessionId,
      skillName: planModeSkill.name,
      hasFrontmatter: !!planModeSkill.frontmatter,
    });

    // Compute blocked tools:
    // If skill specifies tools, block everything except those tools
    // Otherwise use default blocked tools
    let blockedTools = DEFAULT_PLAN_MODE_BLOCKED_TOOLS;

    if (planModeSkill.frontmatter?.tools && planModeSkill.frontmatter.tools.length > 0) {
      // Skill specifies allowed tools - block everything else
      // For now, we use default blocked tools and allow what's specified
      // This is a simplification - in a more complete implementation,
      // we'd compute the inverse of the allowed tools list
      const allowedTools = new Set(planModeSkill.frontmatter.tools);
      blockedTools = DEFAULT_PLAN_MODE_BLOCKED_TOOLS.filter(t => !allowedTools.has(t));
    }

    await planModeCallback.enterPlanMode(planModeSkill.name, blockedTools);

    logger.info('[SKILL] Plan mode entered via skill', {
      sessionId,
      skillName: planModeSkill.name,
      blockedTools,
    });
  }

  /**
   * Track skills explicitly added with a prompt.
   *
   * Skills are tracked when explicitly selected via the skill sheet or
   * @mention detection in the client (passed in options.skills).
   *
   * Note: @mentions in prompt text are NOT extracted here. The iOS client handles
   * @mention detection and converts them to explicit skill chips before sending.
   *
   * For each skill not already tracked:
   * - Creates a skill.added event (persisted to EventStore)
   * - Adds the skill to the session's skillTracker
   *
   * This ensures skill tracking is:
   * - Persisted (events can be replayed for session resume/fork)
   * - Deferred until prompt send (not tracked while typing)
   * - Deduplicated (skills already in context are not re-added)
   */
  async trackSkillsForPrompt(
    context: SkillLoadContext,
    options: AgentRunOptions
  ): Promise<void> {
    const { sessionId, skillTracker, sessionContext } = context;

    // Collect skills to track from explicitly selected skills only
    // @mentions in prompt text are handled client-side (converted to chips)
    const skillsToTrack: Array<{
      name: string;
      source: SkillSource;
      addedVia: SkillAddMethod;
    }> = [];

    // Add explicitly selected skills from options.skills
    if (options.skills && options.skills.length > 0) {
      for (const skill of options.skills) {
        skillsToTrack.push({
          name: skill.name,
          source: skill.source,
          addedVia: 'explicit',
        });
      }
    }

    // Track each skill that's not already in the session's context
    for (const skill of skillsToTrack) {
      if (!skillTracker.hasSkill(skill.name)) {
        // Create skill.added event (linearized via SessionContext)
        const skillEvent = await sessionContext.appendEvent('skill.added', {
          skillName: skill.name,
          source: skill.source,
          addedVia: skill.addedVia,
        });

        // Update in-memory tracker
        if (skillEvent) {
          skillTracker.addSkill(
            skill.name,
            skill.source,
            skill.addedVia,
            skillEvent.id
          );

          logger.debug('[SKILL] skill.added event created', {
            sessionId,
            skillName: skill.name,
            source: skill.source,
            addedVia: skill.addedVia,
            eventId: skillEvent.id,
          });
        }
      }
    }
  }

  /**
   * Transform message content for LLM consumption.
   * Converts text file documents (text/*, application/json) to inline text content,
   * since Claude's document type only supports PDFs.
   * The original document blocks are preserved in the event store for iOS display.
   */
  transformContentForLLM(content: string | UserContent[]): string | UserContent[] {
    // Simple string content - no transformation needed
    if (typeof content === 'string') {
      return content;
    }

    // Transform content blocks
    return content.map((block) => {
      // Only transform document blocks that are text files
      if (
        block.type === 'document' &&
        'mimeType' in block &&
        (block.mimeType?.startsWith('text/') || block.mimeType === 'application/json')
      ) {
        // Convert text file document to inline text content
        try {
          const textContent = Buffer.from(block.data as string, 'base64').toString('utf-8');
          const fileName = 'fileName' in block ? block.fileName : 'file';
          return {
            type: 'text' as const,
            text: `--- File: ${fileName} ---\n${textContent}\n--- End of file ---`,
          };
        } catch {
          // If decoding fails, return original block
          return block;
        }
      }
      // Keep other blocks as-is (images, PDFs, text)
      return block;
    });
  }
}

// =============================================================================
// Factory Function
// =============================================================================

export function createSkillLoader(config?: SkillLoaderConfig): SkillLoader {
  return new SkillLoader(config);
}
