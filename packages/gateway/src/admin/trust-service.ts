import { realpath, stat } from "node:fs/promises";
import { resolve } from "node:path";
import {
  hasTrustRequiringProjectResources,
  ProjectTrustStore,
  SettingsManager,
} from "@earendil-works/pi-coding-agent";
import { GatewayError } from "../errors.js";

export interface TrustInspection {
  cwd: string;
  requiresDecision: boolean;
  savedDecision: boolean | null;
  defaultDecision: "ask" | "always" | "never";
  effectiveDecision: boolean | null;
}

export class TrustService {
  private readonly store: ProjectTrustStore;

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
    const cwd = await this.canonicalDirectory(path);
    const requiresDecision = hasTrustRequiringProjectResources(cwd);
    const savedDecision = this.store.get(cwd);
    const settings = SettingsManager.create(cwd, this.agentDir, { projectTrusted: false });
    const defaultDecision = settings.getDefaultProjectTrust();
    const effectiveDecision = savedDecision ?? (defaultDecision === "always" ? true : defaultDecision === "never" ? false : null);
    return { cwd, requiresDecision, savedDecision, defaultDecision, effectiveDecision };
  }

  async requireResolved(path: string): Promise<{ cwd: string; trusted: boolean }> {
    const inspection = await this.inspect(path);
    if (inspection.requiresDecision && inspection.effectiveDecision === null) {
      throw new GatewayError("trust_required", "Choose whether to trust this project before loading agent resources", false, inspection);
    }
    return { cwd: inspection.cwd, trusted: inspection.effectiveDecision === true };
  }

  async set(path: string, decision: boolean | null): Promise<TrustInspection> {
    const cwd = await this.canonicalDirectory(path);
    this.store.set(cwd, decision);
    return this.inspect(cwd);
  }
}
