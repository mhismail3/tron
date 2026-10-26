import type { KnowledgeNoteMutationRequest, KnowledgeRecord } from "../src/knowledge/knowledge-contract.js";
import { profileLabels } from "../src/knowledge/knowledge-notes.js";
import type { KnowledgeStore } from "../src/knowledge/knowledge-store.js";

/** Arrange historical data through the real privileged restore owner. Ordinary
 * note APIs must not acquire a legacy-write bypass merely for fixture setup. */
export async function legacyProfileFixture(store: KnowledgeStore, commandId: string, record: KnowledgeNoteMutationRequest["record"]): Promise<Extract<KnowledgeRecord, { kind: "note" }>> {
  const tags = record.content.tags ?? [];
  const created = (await store.createNote({ commandId, record: { ...record, content: { ...record.content,
    tags: tags.filter(tag => !tag.startsWith("home-file-")), profile: { version: 2, path: ["life"] } } } })).record;
  const labels = profileLabels(tags);
  await store.partitionProfile({ commandId: `${commandId}-historical-fixture`, mode: "reorganize", assignments: [{ id: created.id, expectedRevision: created.revisionId, labels }] }, { restoring: true, create: () => ({ fixture: "historical-profile-restore" }), validate: envelope => { if ((envelope as { fixture?: string }).fixture !== "historical-profile-restore") throw new Error("Unexpected fixture recovery envelope"); } });
  return await store.read(created.id) as Extract<KnowledgeRecord, { kind: "note" }>;
}
