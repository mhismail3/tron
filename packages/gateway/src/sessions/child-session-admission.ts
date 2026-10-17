import { closeSync, fstatSync, lstatSync, openSync, readSync, realpathSync } from "node:fs";
import { basename, dirname, isAbsolute, join, relative, sep } from "node:path";
import type { ExtensionRunActivity } from "../protocol/types.js";
import { extensionRunChildProducerId, type ExtensionRunChildIdentityStrategy } from "./extension-run-projection.js";

const MAX_VALIDATED_CHILD_SESSION_PATHS = 2_048;
/** Only RuntimeSlot's private recovery descriptor builder mints this annotation.
 * Sharing its symbol preserves that identity; JSON/status content cannot carry it. */
export const RECOVERY_SESSION_OWNER = Symbol("recovery-session-owner");

/** The parent state admission reads. Each callback is invoked at the exact point
 * the admission needs it, so no parent file or identity is cached here. */
export interface ChildSessionAdmissionCallbacks {
  parentSessionFile(): string | undefined;
  parentSessionId(): string;
  isEmbeddedLifecycleArtifact(value: unknown): boolean;
}

/**
 * Admits the child-session files a delegated run's lifecycle evidence names, by
 * exact canonical containment, header identity and file identity, and keeps the
 * bounded index of admitted paths. RuntimeSlot keeps the process-to-child bindings
 * and calls `clear` at its reset and dispose cuts.
 */
export class ChildSessionAdmission {
  private readonly validatedChildSessionPaths = new Map<string, string>();

  constructor(private readonly callbacks: ChildSessionAdmissionCallbacks) {}

  /** The canonical file last admitted for this exact child ref and producer. */
  path(ref: string, producerId: string): string | undefined {
    return this.validatedChildSessionPaths.get(`${ref}\0${producerId}`);
  }

  clear(): void {
    this.validatedChildSessionPaths.clear();
  }

  private childSessionReferences(
    value: unknown,
    activity: ExtensionRunActivity,
    identityStrategy: ExtensionRunChildIdentityStrategy,
  ): Map<string, { ref: string; producerId: string; sessionOwnerId?: string }> {
    const references = new Map<string, { ref: string; producerId: string; sessionOwnerId?: string }>();
    const ambiguous = new Set<string>();
    if (!activity.runId) return references;
    const wrapper = value && typeof value === "object" && !Array.isArray(value) ? value as Record<string, unknown> : undefined;
    const root = wrapper?.details && typeof wrapper.details === "object" && !Array.isArray(wrapper.details)
      ? wrapper.details as Record<string, unknown> : wrapper;
    const declaredRun = [root?.runId, root?.asyncId]
      .find((item): item is string => typeof item === "string" && item.trim().length > 0)?.trim();
    const embeddedHeader = this.callbacks.isEmbeddedLifecycleArtifact(value);
    // Exact producer run ownership is established before a child path can
    // enrich the already tool-owned activity. Generic nested records cannot
    // nominate arbitrary sessions.
    if (declaredRun !== activity.runId) return references;
    const visit = (candidate: unknown, depth: number, index: number, isChild: boolean): void => {
      if (depth > 4 || candidate === null || typeof candidate !== "object" || Array.isArray(candidate)) return;
      const record = candidate as Record<string, unknown>;
      const progress = record.progress && typeof record.progress === "object" && !Array.isArray(record.progress)
        ? record.progress as Record<string, unknown> : undefined;
      const childDepth = Math.max(0, depth - 1);
      const producerId = extensionRunChildProducerId(record, index, childDepth, identityStrategy);
      const recoverySessionOwner = identityStrategy === "piArtifact"
        ? (record as Record<PropertyKey, unknown>)[RECOVERY_SESSION_OWNER]
        : undefined;
      const sessionOwnerId = [recoverySessionOwner, embeddedHeader ? record.sessionOwnerId : undefined, record.runId, progress?.runId]
        .find((item): item is string => typeof item === "string" && item.trim().length > 0)?.trim();
      const rawLabel = [progress?.agent, record.agent]
        .find((item): item is string => typeof item === "string" && item.trim().length > 0)?.trim();
      const projectionID = producerId ?? `${rawLabel ?? `Child ${index + 1}`}:${index}`;
      const sessionFile = [record.sessionFile, progress?.sessionFile]
        .find((item): item is string => typeof item === "string" && item.trim().length > 0)?.trim();
      if (isChild && sessionFile && producerId !== activity.runId) {
        const admitted = this.admit(sessionFile, activity.runId!, producerId, sessionOwnerId);
        if (admitted) {
          const evidence = {
            ref: admitted.ref,
            producerId: admitted.producerId,
            ...(admitted.sessionOwnerId ? { sessionOwnerId: admitted.sessionOwnerId } : {}),
          };
          const prior = references.get(projectionID);
          if (prior && (prior.ref !== evidence.ref || prior.producerId !== evidence.producerId
            || prior.sessionOwnerId !== evidence.sessionOwnerId)) {
            references.delete(projectionID);
            ambiguous.add(projectionID);
          } else if (!ambiguous.has(projectionID)) references.set(projectionID, evidence);
        }
      }
      for (const key of ["results", "steps", "children"] as const) {
        const nested = record[key];
        if (Array.isArray(nested)) nested.slice(0, 64).forEach((child, childIndex) => visit(child, depth + 1, childIndex, true));
      }
      if (Array.isArray(record.progress)) {
        record.progress.slice(0, 64).forEach((child, childIndex) => visit(child, depth + 1, childIndex, true));
      }
    };
    visit(root, 0, 0, false);
    return references;
  }

  private boundedSessionHeader(descriptor: number): {
    id: string;
    parentSession?: string;
  } | undefined {
    const maximum = 64 * 1_024;
    try {
      const bytes = Buffer.alloc(maximum + 1);
      const count = readSync(descriptor, bytes, 0, bytes.length, 0);
      const bounded = bytes.subarray(0, Math.min(count, maximum));
      const finalNewline = bounded.lastIndexOf(0x0a);
      if (finalNewline < 0) return undefined;
      const lines = bounded.subarray(0, finalNewline).toString("utf8").split("\n").filter(Boolean);
      if (lines.length === 0) return undefined;
      const header = JSON.parse(lines[0]!) as Record<string, unknown>;
      if (header.type !== "session" || typeof header.id !== "string" || !header.id.trim()) return undefined;
      const parentSession = typeof header.parentSession === "string" && header.parentSession.trim()
        ? header.parentSession.trim() : undefined;
      return {
        id: header.id,
        ...(parentSession ? { parentSession } : {}),
      };
    } catch { return undefined; }
  }

  admit(
    candidate: string,
    expectedRunId: string,
    declaredChildId?: string,
    declaredSessionOwnerId?: string,
  ): { ref: string; path: string; producerId: string; sessionOwnerId?: string } | undefined {
    if (!isAbsolute(candidate) || candidate.length > 4_096 || !expectedRunId || /[\\/\0]/u.test(expectedRunId)
      || declaredSessionOwnerId !== undefined
        && (Buffer.byteLength(declaredSessionOwnerId) > 256 || /[\\/\0]/u.test(declaredSessionOwnerId))) return undefined;
    let canonical: string;
    let identity: { dev: number; ino: number };
    try {
      const metadata = lstatSync(candidate);
      if (!metadata.isFile() || metadata.isSymbolicLink()) return undefined;
      identity = { dev: metadata.dev, ino: metadata.ino };
      canonical = realpathSync(candidate);
    } catch { return undefined; }
    const parentFile = this.callbacks.parentSessionFile();
    if (!parentFile) return undefined;
    let parentCanonical: string;
    try { parentCanonical = realpathSync(parentFile); } catch { return undefined; }
    const childRoot = join(dirname(parentCanonical), basename(parentCanonical, ".jsonl"));
    const ownedRelative = relative(childRoot, canonical);
    const pathParts = ownedRelative.split(sep);
    if (ownedRelative === "" || ownedRelative === ".." || ownedRelative.startsWith(`..${sep}`)
      || isAbsolute(ownedRelative)) return undefined;
    const forkContext = pathParts.length === 2 && pathParts[0] === "forks"
      && pathParts[1] !== ".jsonl" && pathParts[1]!.endsWith(".jsonl");
    const freshContext = pathParts.length === 3 && pathParts[0] !== "forks"
      && pathParts[2] === "session.jsonl" && /^run-\d+$/u.test(pathParts[1]!);
    if (!forkContext && !freshContext) return undefined;
    // A fresh path may be reserved by the root run (ordinary single/parallel/
    // chain) or by a detached workflow child. Keep that filesystem owner
    // separate from the stable child producer identity used by process rows.
    // Fork paths encode neither, so their exact artifact child identity remains
    // mandatory; filenames and transcript presentation never become evidence.
    const pathOwnerId = freshContext ? pathParts[0] : undefined;
    if (freshContext && pathOwnerId !== expectedRunId && pathOwnerId !== declaredSessionOwnerId) return undefined;
    // A path proves containment, never child ownership. Every admitted context
    // also needs a distinct producer identity from the trusted lifecycle shape.
    if (!declaredChildId) return undefined;
    const producerId = declaredChildId;
    if (Buffer.byteLength(producerId) > 256 || /[\\/\0]/u.test(producerId)) return undefined;
    let descriptor: number | undefined;
    try {
      descriptor = openSync(canonical, "r");
      const opened = fstatSync(descriptor);
      if (!opened.isFile() || opened.dev !== identity.dev || opened.ino !== identity.ino) return undefined;
      const header = this.boundedSessionHeader(descriptor);
      if (!header) return undefined;
      if (header.parentSession) {
        let headerParent: string;
        try { headerParent = realpathSync(header.parentSession); } catch { return undefined; }
        if (headerParent !== parentCanonical) return undefined;
      } else if (forkContext) {
        return undefined;
      }
      const after = lstatSync(canonical);
      if (!after.isFile() || after.isSymbolicLink() || after.dev !== opened.dev || after.ino !== opened.ino) return undefined;
      const ref = header.id;
      if (!ref || ref === this.callbacks.parentSessionId() || Buffer.byteLength(ref) > 256) return undefined;
      const bindingKey = `${ref}\0${producerId}`;
      this.validatedChildSessionPaths.delete(bindingKey);
      this.validatedChildSessionPaths.set(bindingKey, canonical);
      while (this.validatedChildSessionPaths.size > MAX_VALIDATED_CHILD_SESSION_PATHS) {
        const oldest = this.validatedChildSessionPaths.keys().next().value;
        if (oldest === undefined) break;
        this.validatedChildSessionPaths.delete(oldest);
      }
      return { ref, path: canonical, producerId, ...(pathOwnerId ? { sessionOwnerId: pathOwnerId } : {}) };
    } catch { return undefined; }
    finally { if (descriptor !== undefined) closeSync(descriptor); }
  }

  attach(
    activity: ExtensionRunActivity,
    value: unknown,
    identityStrategy: ExtensionRunChildIdentityStrategy = "declared",
  ): ExtensionRunActivity {
    const references = this.childSessionReferences(value, activity, identityStrategy);
    if (references.size === 0) return activity;
    const attach = (children: ExtensionRunActivity["children"]): ExtensionRunActivity["children"] => children.map((child) => {
      const evidence = references.get(child.id);
      return {
        ...child,
        ...(evidence ? {
          id: evidence.producerId,
          producerId: evidence.producerId,
          childSessionRef: evidence.ref,
          ...(evidence.sessionOwnerId ? { sessionOwnerId: evidence.sessionOwnerId } : {}),
        } : {}),
        ...(child.children ? { children: attach(child.children) } : {}),
      };
    });
    return { ...activity, children: attach(activity.children) };
  }
}
