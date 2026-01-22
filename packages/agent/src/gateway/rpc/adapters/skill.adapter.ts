/**
 * @fileoverview Skill Adapter
 *
 * Adapts SkillRegistry operations to the SkillRpcManager interface
 * expected by RpcContext. Manages per-directory skill registries and
 * handles skill listing, loading, refreshing, and removal.
 */

import { SkillRegistry } from '../../../index.js';
import type {
  SkillRpcManager,
  SkillListParams,
  SkillListResult,
  SkillGetParams,
  SkillGetResult,
  SkillRefreshParams,
  SkillRefreshResult,
  SkillRemoveParams,
  SkillRemoveResult,
  RpcSkillInfo,
  RpcSkillMetadata,
  SessionId,
} from '../../../index.js';
import type { AdapterDependencies } from '../types.js';

// =============================================================================
// Helper Functions
// =============================================================================

/**
 * Extract autoInject from either SkillInfo or SkillMetadata
 */
function getAutoInject(s: any): boolean {
  return 'frontmatter' in s ? (s.frontmatter?.autoInject ?? false) : (s.autoInject ?? false);
}

/**
 * Extract tags from either SkillInfo or SkillMetadata
 */
function getTags(s: any): string[] | undefined {
  return 'frontmatter' in s ? s.frontmatter?.tags : s.tags;
}

/**
 * Get display name, falling back to name
 */
function getDisplayName(s: any): string {
  return s.displayName ?? s.name;
}

/**
 * Transform skill to RpcSkillMetadata (with content)
 */
function toSkillMetadata(s: any): RpcSkillMetadata {
  return {
    name: s.name,
    displayName: getDisplayName(s),
    description: s.description,
    source: s.source,
    autoInject: getAutoInject(s),
    tags: getTags(s),
    content: s.content,
    path: s.path,
    additionalFiles: s.additionalFiles,
  };
}

/**
 * Transform skill to RpcSkillInfo (without content)
 */
function toSkillInfo(s: any): RpcSkillInfo {
  return {
    name: s.name,
    displayName: getDisplayName(s),
    description: s.description,
    source: s.source,
    autoInject: getAutoInject(s),
    tags: getTags(s),
  };
}

// =============================================================================
// Skill Adapter Factory
// =============================================================================

/**
 * Creates a skill manager adapter that manages per-directory skill registries
 *
 * @param deps - Adapter dependencies including the orchestrator
 * @returns SkillRpcManager implementation
 */
export function createSkillAdapter(deps: AdapterDependencies): SkillRpcManager {
  const { orchestrator } = deps;

  // Map of working directory -> SkillRegistry
  const registries = new Map<string, SkillRegistry>();

  /**
   * Get or create a SkillRegistry for a working directory
   */
  async function getOrCreateRegistry(workingDirectory: string): Promise<SkillRegistry> {
    let registry = registries.get(workingDirectory);
    if (!registry) {
      registry = new SkillRegistry({ workingDirectory });
      await registry.initialize();
      registries.set(workingDirectory, registry);
    }
    return registry;
  }

  /**
   * Get the working directory for a session
   */
  async function getWorkingDirectoryForSession(sessionId?: string): Promise<string | null> {
    if (!sessionId) return null;
    const session = await orchestrator.getSession(sessionId);
    return session?.workingDirectory ?? null;
  }

  return {
    /**
     * List available skills
     */
    async listSkills(params: SkillListParams): Promise<SkillListResult> {
      const workingDir = await getWorkingDirectoryForSession(params.sessionId);

      if (!workingDir) {
        // No session - return global skills only from default registry
        const registry = await getOrCreateRegistry(process.cwd());
        const skills = params.includeContent
          ? registry.listFull({ source: 'global', autoInjectOnly: params.autoInjectOnly })
          : registry.list({ source: 'global', autoInjectOnly: params.autoInjectOnly });

        const autoInjectCount = skills.filter(s => getAutoInject(s)).length;

        return {
          skills: skills.map(s =>
            params.includeContent ? toSkillMetadata(s) : toSkillInfo(s),
          ),
          totalCount: skills.length,
          autoInjectCount,
        };
      }

      const registry = await getOrCreateRegistry(workingDir);
      const skills = params.includeContent
        ? registry.listFull({ source: params.source, autoInjectOnly: params.autoInjectOnly })
        : registry.list({ source: params.source, autoInjectOnly: params.autoInjectOnly });

      const autoInjectCount = registry.list({ autoInjectOnly: true }).length;

      return {
        skills: skills.map(s =>
          params.includeContent ? toSkillMetadata(s) : toSkillInfo(s),
        ),
        totalCount: skills.length,
        autoInjectCount,
      };
    },

    /**
     * Get a specific skill by name
     */
    async getSkill(params: SkillGetParams): Promise<SkillGetResult> {
      const workingDir = await getWorkingDirectoryForSession(params.sessionId);
      const registry = await getOrCreateRegistry(workingDir ?? process.cwd());

      const skill = registry.get(params.name);
      if (!skill) {
        return { skill: null, found: false };
      }

      return {
        skill: {
          name: skill.name,
          displayName: skill.displayName,
          description: skill.description,
          source: skill.source,
          autoInject: skill.frontmatter.autoInject ?? false,
          tags: skill.frontmatter.tags,
          content: skill.content,
          path: skill.path,
          additionalFiles: skill.additionalFiles,
        },
        found: true,
      };
    },

    /**
     * Refresh skills (clear cache and reinitialize)
     */
    async refreshSkills(params: SkillRefreshParams): Promise<SkillRefreshResult> {
      const workingDir = await getWorkingDirectoryForSession(params.sessionId);
      const effectiveDir = workingDir ?? process.cwd();

      // Clear the cached registry and reinitialize
      registries.delete(effectiveDir);
      const registry = await getOrCreateRegistry(effectiveDir);

      return {
        success: true,
        skillCount: registry.size,
      };
    },

    /**
     * Remove a skill from the session context
     */
    async removeSkill(params: SkillRemoveParams): Promise<SkillRemoveResult> {
      const { sessionId, skillName } = params;

      // Check if skill is tracked in the session
      const active = orchestrator.getActiveSession(sessionId);
      if (!active) {
        return { success: false, error: 'Session not active' };
      }

      if (!active.skillTracker.hasSkill(skillName)) {
        return { success: false, error: 'Skill not in session context' };
      }

      // Remove from skill tracker
      active.skillTracker.removeSkill(skillName);

      // Emit skill.removed event (linearized via SessionContext's EventPersister)
      await orchestrator.appendEvent({
        sessionId: sessionId as SessionId,
        type: 'skill.removed',
        payload: {
          skillName,
          removedVia: 'manual',
        },
      });

      // Broadcast skill removed event via WebSocket for real-time notification
      orchestrator.emit('skill_removed', {
        sessionId,
        skillName,
      });

      return { success: true };
    },
  };
}
