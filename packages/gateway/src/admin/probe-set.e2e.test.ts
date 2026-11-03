import { it } from "vitest";
import { writeFileSync } from "node:fs";
import { startGatewayProcess } from "../../test-support/gateway-process.js";
it("probe", async () => {
  const g = await startGatewayProcess();
  const out: any = {};
  try {
    const c = await g.connect();
    const req = async (m: string, p: any) => { const r = await c.request(m, p); out[m + Object.keys(out).length] = r; return r; };
    const a = (await req("session.create", { commandId: "probe-create-a", cwd: g.cwd })).result.sessionId;
    const o = await req("session.open", { sessionId: a }); await req("session.sync", { sessionId: a, syncToken: o.result.syncToken });
    await req("settings.resolve", { target: { kind: "session", sessionId: a }, keys: ["model.ref[role=chat]"] });
    const ch = await req("settings.change", { commandId: "probe-change-1", target: { kind: "session", sessionId: a }, changes: [{ key: "model.ref[role=chat]", layer: "session", op: "set", value: { provider: "scripted", id: "scripted-alternate" } }] });
    await req("settings.change", { commandId: "probe-change-2", target: { kind: "session", sessionId: a }, changes: [{ key: "model.ref[role=chat]", layer: "session", op: "set", value: { provider: "scripted", id: "scripted-model" }, expected: { provider: "scripted", id: "nope" } }] });
    await req("settings.history", { limit: 5 });
    await req("settings.resolve", { target: { kind: "session", sessionId: a }, keys: ["model.ref[role=chat]"] });
  } finally { writeFileSync("/tmp/probe2142/set.json", JSON.stringify(out, null, 1)); await g.dispose(); }
}, 200000);
