/**
 * @fileoverview Skill Adapter
 *
 * Adapts SkillRegistry operations to the SkillRpcManager interface
 * expected by RpcContext. Manages per-directory skill registries and
 * handles skill listing, loading, refreshing, and removal.
 */

import { SkillRegistry } from '@capabilities/extensions/skills/index.js';
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
import type { SessionId } from '@infrastructure/events/types/index.js';
import type { SkillInfo, SkillMetadata } from '@capabilities/extensions/skills/index.js';
import type { AdapterDependencies } from '../types.js';

// =============================================================================
// Helper Functions
// =============================================================================

/**
 * Transform SkillMetadata to RpcSkillMetadata (with content)
 */
function toSkillMetadata(s: SkillMetadata): RpcSkillMetadata {
  return {
    name: s.name,
    displayName: s.displayName,
    description: s.description,
    source: s.source,
    tags: s.frontmatter?.tags,
    content: s.content,
    path: s.path,
    additionalFiles: s.additionalFiles,
  };
}

/**
 * Transform skill to RpcSkillInfo (without content)
 */
function toSkillInfo(s: SkillInfo | SkillMetadata): RpcSkillInfo {
  const tags = 'frontmatter' in s ? s.frontmatter?.tags : s.tags;
  return {
    name: s.name,
    displayName: s.displayName,
    description: s.description,
    source: s.source,
    tags,
  };
}

// =============================================================================
// Skill Adapter Factory
// =============================================================================

/**
 * Creates a skill manager adapter that manages per-directory skill registries
 */
export function createSkillAdapter(deps: AdapterDependencies): SkillRpcManager {
  const { orchestrator } = deps;

  const registries = new Map<string, SkillRegistry>();

  async function getOrCreateRegistry(workingDirectory: string): Promise<SkillRegistry> {
    let registry = registries.get(workingDirectory);
    if (!registry) {
      registry = new SkillRegistry({ workingDirectory });
      await registry.initialize();
      registries.set(workingDirectory, registry);
    }
    return registry;
  }

  async function getWorkingDirectoryForSession(sessionId?: string): Promise<string | null> {
    if (!sessionId) return null;
    const session = await orchestrator.sessions.getSession(sessionId);
    return session?.workingDirectory ?? null;
  }

  return {
    async listSkills(params: SkillListParams): Promise<SkillListResult> {
      const workingDir = await getWorkingDirectoryForSession(params.sessionId);

      if (!workingDir) {
        const registry = await getOrCreateRegistry(process.cwd());

        if (params.includeContent) {
          const skills = registry.listFull({ source: 'global' });
          return {
            skills: skills.map(toSkillMetadata),
            totalCount: skills.length,
          };
        } else {
          const skills = registry.list({ source: 'global' });
          return {
            skills: skills.map(toSkillInfo),
            totalCount: skills.length,
          };
        }
      }

      const registry = await getOrCreateRegistry(workingDir);

      if (params.includeContent) {
        const skills = registry.listFull({ source: params.source });
        return {
          skills: skills.map(toSkillMetadata),
          totalCount: skills.length,
        };
      } else {
        const skills = registry.list({ source: params.source });
        return {
          skills: skills.map(toSkillInfo),
          totalCount: skills.length,
        };
      }
    },

    async getSkill(params: SkillGetParams): Promise<SkillGetResult> {
      const workingDir = await getWorkingDirectoryForSession(params.sessionId);
      const registry = await getOrCreateRegistry(workingDir ?? process.cwd());

      const skill = registry.get(params.name);
      if (!skill) {
        return { skill: null, found: false };
      }

      return {
        skill: toSkillMetadata(skill),
        found: true,
      };
    },

    async refreshSkills(params: SkillRefreshParams): Promise<SkillRefreshResult> {
      const workingDir = await getWorkingDirectoryForSession(params.sessionId);
      const effectiveDir = workingDir ?? process.cwd();

      registries.delete(effectiveDir);
      const registry = await getOrCreateRegistry(effectiveDir);

      return {
        success: true,
        skillCount: registry.size,
      };
    },

    async removeSkill(params: SkillRemoveParams): Promise<SkillRemoveResult> {
      const { sessionId, skillName } = params;

      const active = orchestrator.getActiveSession(sessionId);
      if (!active) {
        return { success: false, error: 'Session not active' };
      }

      if (!active.skillTracker.hasSkill(skillName)) {
        return { success: false, error: 'Skill not in session context' };
      }

      active.skillTracker.removeSkill(skillName);

      await orchestrator.events.append({
        sessionId: sessionId as SessionId,
        type: 'skill.removed',
        payload: {
          skillName,
          removedVia: 'manual',
        },
      });

      orchestrator.emit('skill_removed', {
        sessionId,
        skillName,
      });

      return { success: true };
    },
  };
}
