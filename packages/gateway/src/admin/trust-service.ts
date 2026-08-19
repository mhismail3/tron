import { realpath, stat } from "node:fs/promises";
import { dirname, resolve } from "node:path";
import {
  hasTrustRequiringProjectResources,
  ProjectTrustStore,
  SettingsManager,
} from "@earendil-works/pi-coding-agent";
import { GatewayError } from "../errors.js";
import { AsyncMutex } from "../util/async-mutex.js";

export interface TrustInspection {
  cwd: string;
  requiresDecision: boolean;
  savedDecision: boolean | null;
  defaultDecision: "ask" | "always" | "never";
  effectiveDecision: boolean | null;
}

export interface PropagatedTrustDecision {
  source: TrustInspection;
  target: TrustInspection;
  rollback: () => Promise<void>;
}

export class TrustService {
  private readonly store: ProjectTrustStore;
  private readonly mutationMutex = new AsyncMutex();

  constructor(private readonly agentDir: string) {
    this.store = new ProjectTrustStore(agentDir);
  }

  async canonicalDirectory(path: string): Promise<string> {
    let canonical: string;
    try {
      canonical = await realpath(resolve(path));
      if (!(await stat(canonical)).isDirectory()) throw new Error("not a directory");
    } catch {
      throw new GatewayError("invalid_request", "Working directory does not exist or is not a directory");
    }
    return canonical;
  }

  async inspect(path: string): Promise<TrustInspection> {
    return this.inspectUnlocked(path);
  }

  private async inspectUnlocked(path: string): Promise<TrustInspection> {
    const cwd = await this.canonicalDirectory(path);
    const requiresDecision = hasTrustRequiringProjectResources(cwd);
    const savedDecision = this.store.get(cwd);
    const settings = SettingsManager.create(cwd, this.agentDir, { projectTrusted: false });
    const defaultDecision = settings.getDefaultProjectTrust();
    const effectiveDecision = savedDecision ?? (defaultDecision === "always" ? true : defaultDecision === "never" ? false : null);
    return { cwd, requiresDecision, savedDecision, defaultDecision, effectiveDecision };
  }

  async requireResolved(path: string): Promise<{ cwd: string; trusted: boolean }> {
    const inspection = await this.inspectUnlocked(path);
    if (inspection.requiresDecision && inspection.effectiveDecision === null) {
      throw new GatewayError("trust_required", "Choose whether to trust this project before loading agent resources", false, inspection);
    }
    return { cwd: inspection.cwd, trusted: inspection.effectiveDecision === true };
  }

  /**
   * A Git worktree is a new canonical path for the same project. Carry the
   * already-resolved source decision only when the target has no explicit or
   * inherited decision, so creating a worktree cannot bypass project trust or
   * overwrite a deliberate target decision.
   */
  async propagateResolvedDecision(sourcePath: string, targetPath: string): Promise<PropagatedTrustDecision> {
    return this.mutationMutex.run(async () => {
      const source = await this.inspectUnlocked(sourcePath);
      if (source.requiresDecision && source.effectiveDecision === null) {
        throw new GatewayError("trust_required", "Choose whether to trust this project before creating a worktree", false, source);
      }
      const target = await this.inspectUnlocked(targetPath);
      const shouldWrite = target.savedDecision === null && target.effectiveDecision === null;
      if (shouldWrite) this.store.set(target.cwd, source.effectiveDecision === true);
      let rolledBack = false;
      return {
        source,
        target: shouldWrite ? { ...target, savedDecision: source.effectiveDecision === true, effectiveDecision: source.effectiveDecision === true } : target,
        rollback: async () => {
          if (!shouldWrite || rolledBack) return;
          await this.mutationMutex.run(async () => {
            if (rolledBack) return;
            rolledBack = true;
            if (this.store.get(target.cwd) === (source.effectiveDecision === true)) {
              this.store.set(target.cwd, null);
            }
          });
        },
      };
    });
  }

  async set(path: string, decision: boolean | null): Promise<TrustInspection> {
    return this.mutationMutex.run(async () => {
      const cwd = await this.canonicalDirectory(path);
      this.store.set(cwd, decision);
      return this.inspectUnlocked(cwd);
    });
  }

  async setAndApply(
    path: string,
    decision: boolean | null,
    apply: (inspection: TrustInspection) => Promise<void>,
    commit: (inspection: TrustInspection) => Promise<void> = async () => {},
  ): Promise<TrustInspection> {
    return this.mutationMutex.run(async () => {
      const previous = await this.inspectUnlocked(path);
      const previousEntry = this.store.getEntry(previous.cwd);
      const previousLocalDecision = previousEntry?.path === previous.cwd
        ? previousEntry.decision
        : null;
      const parent = dirname(previous.cwd);
      const inheritedDecision = parent === previous.cwd ? null : this.store.get(parent);
      const proposedSavedDecision = decision ?? inheritedDecision;
      const proposed: TrustInspection = {
        ...previous,
        savedDecision: proposedSavedDecision,
        effectiveDecision: proposedSavedDecision ?? (
          previous.defaultDecision === "always"
            ? true
            : previous.defaultDecision === "never" ? false : null
        ),
      };
      try {
        await apply(proposed);
        this.store.set(previous.cwd, decision);
        const current = await this.inspectUnlocked(previous.cwd);
        await commit(current);
        return current;
      } catch (failure) {
        try {
          this.store.set(previous.cwd, previousLocalDecision);
          const restored = await this.inspectUnlocked(previous.cwd);
          await apply(restored);
          await commit(restored);
        } catch (rollbackFailure) {
          throw new GatewayError(
            "internal",
            "Project trust failed and the previous runtime state could not be fully restored",
            false,
            {
              failure: failure instanceof Error ? failure.message : "Unknown trust mutation failure",
              rollbackFailure: rollbackFailure instanceof Error ? rollbackFailure.message : "Unknown trust rollback failure",
            },
          );
        }
        throw failure;
      }
    });
  }
}
