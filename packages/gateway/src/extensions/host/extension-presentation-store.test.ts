import { describe, expect, it } from "vitest";
import { ExtensionPresentationStore, EXTENSION_PRESENTATION_MAX_SURFACES } from "./extension-presentation-store.js";
import type { ExtensionSurface, JsonValue } from "../../protocol/types.js";

function surface(id: string, revision = 1): ExtensionSurface {
  return {
    id, kind: "widget", placement: "aboveEditor", lifecycle: "retained", revision,
    focused: false, inputMode: "none",
    frame: { width: 40, height: 1, lines: [{ plainText: id, runs: [{ text: id, style: {} }] }], plainText: id },
  };
}

describe("ExtensionPresentationStore", () => {
  it("commits aggregate changes atomically with exactly one revision and event", () => {
    const events: Array<{ topic: string; payload: JsonValue }> = [];
    const store = new ExtensionPresentationStore((topic, payload) => events.push({ topic, payload }));
    store.transact((draft) => {
      draft.semanticState.statuses.a = "one";
      draft.surfaces.push(surface("surface"));
      draft.pendingInteractions.push({ id: "interaction", hostEpoch: "", presentationRevision: 0, method: "confirm", title: "Confirm" });
    });
    expect(store.state()).toMatchObject({ revision: 1, semanticState: { statuses: { a: "one" } } });
    expect(store.state().pendingInteractions[0]).toMatchObject({ hostEpoch: store.hostEpoch, presentationRevision: 1 });
    expect(events).toHaveLength(1);
    expect(events[0]).toMatchObject({ topic: "session.extensionPresentation", payload: { version: 2, revision: 1 } });
  });

  it("rejects an invalid transaction without changing state or emitting", () => {
    const events: JsonValue[] = [];
    const store = new ExtensionPresentationStore((_topic, payload) => events.push(payload));
    expect(() => store.transact((draft) => {
      for (let index = 0; index <= EXTENSION_PRESENTATION_MAX_SURFACES; index += 1) draft.surfaces.push(surface(`surface-${index}`));
    })).toThrow(/bounded capacity/);
    expect(store.state().revision).toBe(0);
    expect(store.state().surfaces).toEqual([]);
    expect(events).toEqual([]);
  });

  it("uses explicit removals and never treats malformed upserts as removal", () => {
    const events: JsonValue[] = [];
    const store = new ExtensionPresentationStore((_topic, payload) => events.push(payload));
    store.transact((draft) => { draft.surfaces.push(surface("stable")); });
    expect(() => store.transact((draft) => { draft.surfaces[0]!.revision = 2; draft.surfaces[0]!.frame.width = 161; })).toThrow(/frame is invalid/);
    expect(() => store.transact((draft) => { draft.surfaces[0]!.focused = true; })).toThrow(/exact next revision/);
    expect(store.state().surfaces).toHaveLength(1);
    store.transact((draft) => { draft.surfaces = []; });
    expect(events.at(-1)).toMatchObject({ surfaceRemovals: ["stable"] });
  });

  it("does not alias callback-owned drafts and reports no-op explicitly", () => {
    const events: JsonValue[] = [];
    const store = new ExtensionPresentationStore((_topic, payload) => events.push(payload));
    let retained: ExtensionSurface | undefined;
    let retainedDraft: unknown;
    store.transact((draft) => {
      retained = surface("owned");
      draft.surfaces.push(retained);
      retainedDraft = draft;
    });
    retained!.frame.plainText = "tampered";
    (retainedDraft as { surfaces: ExtensionSurface[] }).surfaces.length = 0;
    expect(store.state().surfaces[0]?.frame.plainText).toBe("owned");
    expect(store.transact(() => {})).toBeUndefined();
    expect(store.state().revision).toBe(1);
    expect(events).toHaveLength(1);
  });

  it("rejects broad-draft semantic, interaction, control, and cell-width bypasses", () => {
    const store = new ExtensionPresentationStore(() => {});
    expect(() => store.transact((draft) => {
      for (let index = 0; index < 33; index += 1) draft.semanticState.statuses[`s${index}`] = "ok";
    })).toThrow(/semantic presentation/);
    expect(() => store.transact((draft) => {
      for (let index = 0; index < 25; index += 1) draft.semanticState.widgets.push({ key: `w${index}`, revision: 1, lines: [], placement: "aboveEditor" });
    })).toThrow(/semantic presentation/);
    expect(() => store.transact((draft) => { draft.semanticState.title = "safe\u009b31munsafe"; })).toThrow(/semantic presentation/);
    expect(() => store.transact((draft) => {
      (draft.semanticState.working as unknown as { indicator: null }).indicator = null;
    })).toThrow(/semantic presentation/);
    expect(() => store.transact((draft) => {
      draft.semanticState.editorText = "changed";
      draft.semanticState.editorRevision = 1;
      draft.editorDirective = { action: "paste", delta: "inconsistent" };
    })).toThrow(/editor directive/);
    expect(() => store.transact((draft) => {
      draft.pendingInteractions.push({ id: "", hostEpoch: "", presentationRevision: 0, method: "confirm", title: "x" });
    })).toThrow(/interactions/);
    expect(() => store.transact((draft) => {
      const over = surface("wide");
      over.frame.width = 1;
      draft.surfaces.push(over);
    })).toThrow(/malformed/);
    expect(store.state().revision).toBe(0);
  });

  it("rejects cross-method interaction fields at the Gateway boundary", () => {
    const store = new ExtensionPresentationStore(() => {});
    const invalid = [
      { method: "confirm", options: ["yes"] },
      { method: "confirm", questionnaire: { version: 1, question: "q", options: [{ label: "yes" }], allowMultiple: false, allowFreeform: false } },
      { method: "select", options: ["yes"], placeholder: "bad" },
      { method: "input", options: ["bad"] },
      { method: "editor", questionnaire: { version: 1, question: "q", options: [{ label: "yes" }], allowMultiple: false, allowFreeform: false } },
    ];
    invalid.forEach((fields, index) => {
      expect(() => store.transact((draft) => {
        draft.pendingInteractions.push({ id: `bad-${index}`, hostEpoch: "", presentationRevision: 0, title: "bad", ...fields } as never);
      })).toThrow(/interactions/);
    });
  });

  it("projects input lease and generic lifecycle activity", () => {
    const store = new ExtensionPresentationStore(() => {});
    store.transact((draft) => {
      draft.surfaces.push(surface("focused"));
      draft.inputLease = { id: "lease", connectionId: "connection", surfaceId: "focused", surfaceRevision: 1, acquiredAt: new Date(0).toISOString() };
    });
    store.setPendingComponentFactories(1);
    store.setScheduledRenders(1);
    expect(store).toMatchObject({ hasMountedPresentation: true, hasInputLease: true, hasPendingComponentFactory: true, hasScheduledRender: true });
  });
});
