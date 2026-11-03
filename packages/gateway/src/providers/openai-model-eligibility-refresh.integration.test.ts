import { ModelRuntime } from "@earendil-works/pi-coding-agent";
import type { Credential, CredentialInfo, CredentialStore } from "@earendil-works/pi-ai";
import { afterEach, expect, it } from "vitest";
import { OpenAIModelEligibility } from "./openai-model-eligibility.js";

class Credentials implements CredentialStore {
  failList = false;
  readonly openai: Credential = { type: "api_key", key: "sk-test" };
  async read(providerId: string) { return providerId === "openai" ? this.openai : undefined; }
  async list(): Promise<readonly CredentialInfo[]> {
    if (this.failList) throw new Error("credential listing unavailable");
    return [{ providerId: "openai", type: "api_key" }];
  }
  async modify(providerId: string, fn: (current: Credential | undefined) => Promise<Credential | undefined>) {
    return fn(providerId === "openai" ? this.openai : undefined);
  }
  async delete() {}
}

const runtimes: ModelRuntime[] = [];
afterEach(async () => {
  // Registration starts detached SDK refreshes; fence them before the next case.
  await Promise.all(runtimes.splice(0).map(runtime => runtime.refresh({ allowNetwork: false })));
});

// `provider.list` and `model.list` call `refresh` on every read. Each session owns a
// ModelRuntime, so reloading every attached runtime per read made those reads grow
// with the open sessions (99 ms at 24 sessions, seconds on a loaded host).
it("reloads attached runtimes only when the eligibility state changes", async () => {
  const credentials = new Credentials();
  const eligibility = new OpenAIModelEligibility({ fetch: async () => { throw new Error("no discovery for API keys"); } });
  const reloads: number[] = [];
  for (let index = 0; index < 4; index += 1) {
    const runtime = await ModelRuntime.create({ modelsPath: null, refreshOnCreate: true, allowModelNetwork: false, credentials });
    runtimes.push(runtime);
    eligibility.attachRuntime(runtime);
    await runtime.refresh({ allowNetwork: false });
    const refresh = runtime.refresh.bind(runtime);
    reloads[index] = 0;
    runtime.refresh = options => { reloads[index]! += 1; return refresh(options); };
  }

  await eligibility.refresh();
  expect(reloads).toEqual([1, 1, 1, 1]);
  for (let read = 0; read < 5; read += 1) await eligibility.refresh();
  expect(reloads).toEqual([1, 1, 1, 1]);

  credentials.failList = true;
  await eligibility.refresh();
  expect(reloads).toEqual([2, 2, 2, 2]);
  await eligibility.refresh();
  expect(reloads).toEqual([2, 2, 2, 2]);
});
