/**
 * @fileoverview Skill Adapter
 *
 * Adapts SkillRegistry operations to the SkillRpcManager interface
 * expected by RpcContext. Manages per-directory skill registries and
 * handles skill listing, loading, refreshing, and removal.
 */

import { SkillRegistry } from '../../../skills/index.js';
import type { SkillRpcManager } from '../../../rpc/index.js';
import type {
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
} from '../../../rpc/types/index.js';
import type { SessionId } from '../../../events/types/index.js';
import type { SkillInfo, SkillMetadata } from '../../../skills/index.js';
import type { AdapterDependencies } from '../types.js';

// =============================================================================
// Helper Functions
// =============================================================================

/**
 * Union type for skill data from registry (can be either SkillInfo or SkillMetadata)
 */
type RegistrySkill = SkillInfo | SkillMetadata;

/**
 * Type guard to check if skill is SkillMetadata (has frontmatter)
 */
function isSkillMetadata(s: RegistrySkill): s is SkillMetadata {
  return 'frontmatter' in s;
}

/**
 * Extract autoInject from either SkillInfo or SkillMetadata
 */
function getAutoInject(s: RegistrySkill): boolean {
  return isSkillMetadata(s) ? (s.frontmatter?.autoInject ?? false) : s.autoInject;
}

/**
 * Extract tags from either SkillInfo or SkillMetadata
 */
function getTags(s: RegistrySkill): string[] | undefined {
  return isSkillMetadata(s) ? s.frontmatter?.tags : s.tags;
}

/**
 * Transform SkillMetadata to RpcSkillMetadata (with content)
 * Only call this with SkillMetadata (from listFull), not SkillInfo
 */
function toSkillMetadata(s: SkillMetadata): RpcSkillMetadata {
  return {
    name: s.name,
    displayName: s.displayName,
    description: s.description,
    source: s.source,
    autoInject: s.frontmatter?.autoInject ?? false,
    tags: s.frontmatter?.tags,
    content: s.content,
    path: s.path,
    additionalFiles: s.additionalFiles,
  };
}

/**
 * Transform skill to RpcSkillInfo (without content)
 */
function toSkillInfo(s: RegistrySkill): RpcSkillInfo {
  return {
    name: s.name,
    displayName: s.displayName,
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
    const session = await orchestrator.sessions.getSession(sessionId);
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

        if (params.includeContent) {
          const skills = registry.listFull({ source: 'global', autoInjectOnly: params.autoInjectOnly });
          const autoInjectCount = skills.filter(s => s.frontmatter?.autoInject ?? false).length;
          return {
            skills: skills.map(toSkillMetadata),
            totalCount: skills.length,
            autoInjectCount,
          };
        } else {
          const skills = registry.list({ source: 'global', autoInjectOnly: params.autoInjectOnly });
          const autoInjectCount = skills.filter(s => s.autoInject).length;
          return {
            skills: skills.map(toSkillInfo),
            totalCount: skills.length,
            autoInjectCount,
          };
        }
      }

      const registry = await getOrCreateRegistry(workingDir);
      const autoInjectCount = registry.list({ autoInjectOnly: true }).length;

      if (params.includeContent) {
        const skills = registry.listFull({ source: params.source, autoInjectOnly: params.autoInjectOnly });
        return {
          skills: skills.map(toSkillMetadata),
          totalCount: skills.length,
          autoInjectCount,
        };
      } else {
        const skills = registry.list({ source: params.source, autoInjectOnly: params.autoInjectOnly });
        return {
          skills: skills.map(toSkillInfo),
          totalCount: skills.length,
          autoInjectCount,
        };
      }
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

      // Emit skill.removed event (linearized via EventController)
      await orchestrator.events.append({
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
