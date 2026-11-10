import { ModelRuntime } from "@earendil-works/pi-coding-agent";
import type { Credential, CredentialInfo, CredentialStore } from "@earendil-works/pi-ai";
import { afterEach, expect, it } from "vitest";
import { OpenAIModelEligibility } from "./openai-model-eligibility.js";

class Credentials implements CredentialStore {
  failList = false;
  readonly openai: Credential = { type: "api_key", key: "sk-test" };
  anthropic: Credential | undefined;
  async read(providerId: string) { return providerId === "openai" ? this.openai : providerId === "anthropic" ? this.anthropic : undefined; }
  async list(): Promise<readonly CredentialInfo[]> {
    if (this.failList) throw new Error("credential listing unavailable");
    return [{ providerId: "openai", type: "api_key" }, ...(this.anthropic ? [{ providerId: "anthropic", type: this.anthropic.type }] : [])];
  }
  async modify(providerId: string, fn: (current: Credential | undefined) => Promise<Credential | undefined>) {
    return fn(providerId === "openai" ? this.openai : providerId === "anthropic" ? this.anthropic : undefined);
  }
  async delete() {}
}

const runtimes: ModelRuntime[] = [];
afterEach(async () => {
  await Promise.all(runtimes.splice(0).map(runtime => runtime.refresh({ allowNetwork: false })));
});

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

  expect(runtimes[3]!.hasConfiguredAuth("anthropic")).toBe(false);
  credentials.anthropic = { type: "api_key", key: "sk-ant-test" };
  await eligibility.refresh();
  expect(reloads).toEqual([2, 2, 2, 2]);
  expect(runtimes[3]!.hasConfiguredAuth("anthropic")).toBe(true);
  await eligibility.refresh();
  expect(reloads).toEqual([2, 2, 2, 2]);

  credentials.failList = true;
  await eligibility.refresh();
  expect(reloads).toEqual([3, 3, 3, 3]);
  await eligibility.refresh();
  expect(reloads).toEqual([3, 3, 3, 3]);
});
