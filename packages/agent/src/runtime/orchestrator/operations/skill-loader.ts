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
// Direct imports to avoid circular dependencies through index.js
import { createLogger } from '@infrastructure/logging/index.js';
import { buildSkillContext } from '@capabilities/extensions/skills/skill-injector.js';
import type {
  SkillSource,
  SkillAddMethod,
  SkillMetadata,
} from '@capabilities/extensions/skills/types.js';
import type { SkillTracker } from '@capabilities/extensions/skills/skill-tracker.js';
import type { UserContent } from '@core/types/messages.js';
import type { SessionContext } from '../session/session-context.js';
import type { AgentRunOptions } from '../types.js';

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
   * 2. Collecting spells (ephemeral skills) from options
   * 3. Tracking new skills (creates events) - but NOT spells
   * 4. Building removed skills/spells instruction
   * 5. Loading skill/spell content via skillLoader callback
   * 6. Building final skill context string with tool preferences
   *
   * Note: Tool restrictions (allowedTools) are now handled as suggestions in
   * the skill context, not via plan mode. Enforcement only happens when skills
   * spawn subagents with subagent: 'yes'.
   */
  async loadSkillContextForPrompt(
    context: SkillLoadContext,
    options: AgentRunOptions
  ): Promise<string> {
    const { sessionId, skillTracker } = context;

    // Get session skills already tracked (persistent across turns)
    const sessionSkills = skillTracker.getAddedSkills();

    // 1. Collect current prompt's spell names FIRST (for conditional exclusion from removal)
    const currentSpellNames: Set<string> = new Set();
    if (options.spells && options.spells.length > 0) {
      for (const spell of options.spells) {
        currentSpellNames.add(spell.name);
      }
    }

    // Log incoming skills and spells for debugging
    logger.info('[SKILL] loadSkillContextForPrompt called', {
      sessionId,
      skillsProvided: options.skills?.length ?? 0,
      skills: options.skills?.map((s) => s.name) ?? [],
      spellsProvided: options.spells?.length ?? 0,
      spells: options.spells?.map((s) => s.name) ?? [],
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
    // NOTE: Spells are NOT tracked here - they don't create events
    if (skillNames.size > 0) {
      await this.trackSkillsForPrompt(context, options);
    }

    // 2. Add spells to skillNames for content loading + track as used
    // This happens AFTER skill tracking so we can build the removal instruction correctly
    if (options.spells && options.spells.length > 0) {
      for (const spell of options.spells) {
        skillNames.add(spell.name);
        // Track as used - idempotent (Set handles duplicates)
        // Note: We DO NOT remove from usedSpellNames when re-using
        // The spell stays in usedSpellNames forever (until context clear)
        skillTracker.addUsedSpell(spell.name);
      }
      logger.info('[SKILL] Added spells to skill names and tracked as used', {
        sessionId,
        spells: options.spells.map((s) => s.name),
      });
    }

    // 3. Build removal instruction including:
    //    - Explicitly removed skills (removedSkillNames)
    //    - Previously used spells, EXCLUDING any being re-used in current prompt
    const removedSkills = skillTracker.getRemovedSkillNames();
    const usedSpells = skillTracker.getUsedSpellNames();

    // Collect all removed items for the instruction
    const allRemoved: string[] = [...removedSkills];

    // Add used spells to removal list, but EXCLUDE spells being re-used in current prompt
    for (const spellName of usedSpells) {
      // Only include if NOT being re-used in current prompt
      // This handles the re-use case: spell is excluded from removal for THIS prompt
      // but will be back in removal instruction on subsequent prompts
      if (!currentSpellNames.has(spellName)) {
        allRemoved.push(spellName);
      }
    }

    let removedSkillsInstruction = '';
    if (allRemoved.length > 0) {
      const skillList = allRemoved.map((s) => `@${s}`).join(', ');
      removedSkillsInstruction = `<removed-skills>
CRITICAL: The following skills/spells have been REMOVED from this session: ${skillList}

You MUST completely stop applying these skill behaviors starting NOW. This includes:
- Do NOT use any special speaking styles, tones, or personas from these skills
- Do NOT follow any formatting rules from these skills
- Do NOT apply any behavioral modifications from these skills
- Respond in your normal, default manner

The user has explicitly removed these skills and expects you to respond WITHOUT them.
</removed-skills>`;
      logger.info('[SKILL] Including removed skills/spells instruction', {
        sessionId,
        removedSkills,
        usedSpellsExcludingCurrent: usedSpells.filter(s => !currentSpellNames.has(s)),
        allRemoved,
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

    // Build skill context using buildSkillContext
    // Note: Tool preferences from allowedTools are included as suggestions
    // (enforced only in subagent mode)
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
