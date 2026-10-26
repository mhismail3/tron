import { expect, it } from "vitest";
import { homeOwnerOf } from "../../../test-support/gateway-registry.js";
import { fixture, readProfilePage } from "../../../test-support/home-profile-fixture.js";
import { readHomeProfile } from "./home-profile.js";

it("SQL profile record pages retain native kind/creation/ID ordering across a cursor, not random UUID order", async () => {
  const f = await fixture("profile-order");
  for (let index = 0; index < 17; index++) {
    // The oldest record sorts LAST by UUID: a projection must not turn the
    // original chronological contract into a chance-dependent array order.
    const id = index === 0 ? "ffffffff-ffff-4fff-8fff-ffffffffffff" : `00000000-0000-4000-8000-${index.toString(16).padStart(12, "0")}`;
    await f.store.createNote({ commandId: `profile-order-${index}`, record: {
      kind: "note", id, scope: "personal", createdAt: new Date(Date.UTC(2026, 0, 1, 0, 0, index)).toISOString(),
      provenance: { actor: "agent", source: "order-fixture", evidence: [] }, relations: [],
      content: { title: `Ordering fixture ${index}`, role: "preference", confirmed: false,
        tags: ["home-profile", "kind-preference"], profile: { version: 2, path: ["inferred", "review"] } },
    } });
  }
  const canonical = await readHomeProfile(f.knowledge);
  expect(canonical.items[0]!.id).toBe("ffffffff-ffff-4fff-8fff-ffffffffffff");
  const native = await homeOwnerOf(f.registry).profileList();
  const first = await readProfilePage(f);
  expect(first.items).toHaveLength(16);
  expect(first.nextCursor).toBeDefined();
  const second = await readProfilePage(f, "inferred", first.nextCursor);
  expect(second.items).toHaveLength(1);
  expect(second.nextCursor).toBeUndefined();
  expect([...first.items, ...second.items].map(item => item.id)).toEqual(canonical.items.map(item => item.id));
  expect(native.items.map(item => item.id)).toEqual(canonical.items.map(item => item.id));
});
