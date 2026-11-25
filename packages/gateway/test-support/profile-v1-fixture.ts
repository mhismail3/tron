import { randomUUID } from "node:crypto";
import type { ProfileStore } from "../src/modules/home/profile-store.js";
import type { ProfileNoteNoteMutationRequest, ProfileNoteRecord } from "../src/modules/home/profile-note-contract.js";
import { createProfileFile, profileFileRecords, readProfileFile, writeProfileFile } from "../src/modules/home/profile-file.js";

export async function legacyProfileFixture(workspace: ConstructorParameters<typeof ProfileStore>[0], _commandId: string, draft: ProfileNoteNoteMutationRequest["record"]): Promise<ProfileNoteRecord> {
  return (await legacyProfileFixtures(workspace, [draft]))[0]!;
}

export async function legacyProfileFixtures(workspace: ConstructorParameters<typeof ProfileStore>[0], drafts: ReadonlyArray<ProfileNoteNoteMutationRequest["record"]>): Promise<ProfileNoteRecord[]> {
  const before = await readProfileFile(workspace), timestamp = new Date().toISOString();
  const records: ProfileNoteRecord[] = drafts.map(draft => ({ ...draft, schemaVersion: 1, id: draft.id ?? randomUUID(), revisionId: randomUUID(), createdAt: draft.createdAt ?? timestamp, updatedAt: draft.updatedAt ?? timestamp }));
  await writeProfileFile(workspace, createProfileFile([...(before ? profileFileRecords(before) : []), ...records], { stateRevision: (before?.stateRevision ?? 0) + 1,
    anchorCandidates: before?.anchors ?? [], ...(before ? { control: before.control } : {}) }));
  await workspace.markFeatureInitialized("profile");
  return records;
}
