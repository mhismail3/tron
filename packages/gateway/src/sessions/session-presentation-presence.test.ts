import { describe, expect, it } from "vitest";
import { SessionPresentationPresenceRegistry } from "./session-presentation-presence.js";

describe("SessionPresentationPresenceRegistry", () => {
  it("orders visibility by exact subscription revision and expires stale leases", () => {
    let now = 1_000;
    const presence = new SessionPresentationPresenceRegistry(() => now, 100);

    expect(presence.set({
      clientId: "phone", sessionId: "session", subscriptionToken: "token", revision: 1, visible: true,
    })).toEqual({ visible: true, revision: 1 });
    expect(presence.isVisible("session")).toBe(true);

    expect(presence.set({
      clientId: "phone", sessionId: "session", subscriptionToken: "token", revision: 2, visible: false,
    })).toEqual({ visible: false, revision: 2 });
    expect(presence.set({
      clientId: "phone", sessionId: "session", subscriptionToken: "token", revision: 1, visible: true,
    })).toEqual({ visible: false, revision: 2 });
    expect(presence.isVisible("session")).toBe(false);

    presence.set({
      clientId: "phone", sessionId: "session", subscriptionToken: "token", revision: 3, visible: true,
    });
    now += 101;
    expect(presence.isVisible("session")).toBe(false);
  });

  it("keeps a session visible while any independent mobile lease remains active", () => {
    const presence = new SessionPresentationPresenceRegistry(() => 1_000, 100);
    presence.set({
      clientId: "phone-a", sessionId: "session", subscriptionToken: "token-a", revision: 1, visible: true,
    });
    presence.set({
      clientId: "phone-b", sessionId: "session", subscriptionToken: "token-b", revision: 1, visible: true,
    });

    presence.set({
      clientId: "phone-a", sessionId: "session", subscriptionToken: "token-a", revision: 2, visible: false,
    });
    expect(presence.isVisible("session")).toBe(true);
    presence.remove("phone-b");
    expect(presence.isVisible("session")).toBe(false);
  });

  it("replaces one mobile connection owner and cleans up by client, session, and rekey", () => {
    const presence = new SessionPresentationPresenceRegistry(() => 1_000, 100);
    presence.set({
      clientId: "phone", sessionId: "first", subscriptionToken: "first-token", revision: 1, visible: true,
    });
    presence.set({
      clientId: "phone", sessionId: "second", subscriptionToken: "second-token", revision: 2, visible: true,
    });
    expect(presence.isVisible("first")).toBe(false);
    expect(presence.isVisible("second")).toBe(true);

    presence.rekey("second", "replacement");
    expect(presence.isVisible("second")).toBe(false);
    expect(presence.isVisible("replacement")).toBe(true);

    presence.remove("phone", "other");
    expect(presence.isVisible("replacement")).toBe(true);
    presence.removeSession("replacement");
    expect(presence.isVisible("replacement")).toBe(false);
  });
});
