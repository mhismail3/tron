/** Builds a `settings.change` request for one Chat-layer key of a session, the
 * way the iPhone sends it: the key, its value and the fence the client read
 * (docs/settings-model.md 5.2). */
export type ChatSetting = "model" | "thinking" | "contextWindow" | "tools";

export function chatSettingChange(setting: ChatSetting, params: Record<string, unknown>): Record<string, unknown> {
  const fence = {
    ...(params.expectedRuntimeGeneration === undefined ? {} : { runtimeGeneration: params.expectedRuntimeGeneration }),
    ...(params.expectedModel === undefined ? {} : { model: params.expectedModel }),
    ...(params.expectedRevision === undefined ? {} : { revision: params.expectedRevision }),
  };
  const change = setting === "model"
    ? { key: "model.ref[role=chat]", layer: "chat", op: "set", value: { provider: params.provider, id: params.modelId } }
    : setting === "thinking"
      ? { key: "model.thinking[role=chat]", layer: "chat", op: "set", value: params.level }
      : setting === "tools"
        ? { key: "tools.active", layer: "chat", op: "set", value: params.tools }
        : {
            key: "model.contextWindow", layer: "chat", qualifiers: { model: `${params.provider}/${params.modelId}` },
            ...(params.contextWindow === null || params.contextWindow === undefined ? { op: "unset" } : { op: "set", value: params.contextWindow }),
          };
  return {
    commandId: params.commandId,
    target: { kind: "session", sessionId: params.sessionId },
    ...(Object.keys(fence).length ? { fence } : {}),
    changes: [change],
  };
}

/** The applied revision a Chat-layer `settings.change` returned. */
export function changedRevision(result: unknown): number | undefined {
  return (result as { changes?: Array<{ revision?: number }> } | undefined)?.changes?.[0]?.revision;
}

/** Builds the `settings.change` that sets Home's memory model (a Profile key,
 * docs/settings-model.md 6.1). Other fields pass through so a fixture can
 * prove the request shape is refused. */
export function homeMemoryChange(params: Record<string, unknown>): Record<string, unknown> {
  const { commandId, model, ...rest } = params;
  return {
    commandId, target: { kind: "home" },
    changes: [{ key: "model.ref[role=memory]", layer: "profile", op: "set", ...(model === undefined ? {} : { value: model }) }],
    ...rest,
  };
}
