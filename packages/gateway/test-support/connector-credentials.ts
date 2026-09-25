import type { ConnectorCredentialStore } from "../src/knowledge/connector-credentials.js";

/** Synthetic-only adapter for Gateway tests. */
export class InMemoryConnectorCredentialStore implements ConnectorCredentialStore {
  constructor(private readonly values: ReadonlyMap<string, string>) {}
  async read(reference: string): Promise<string | undefined> {
    const value = this.values.get(reference);
    return value && value.length <= 8_192 ? value : undefined;
  }
}
