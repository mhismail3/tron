const VIRTUAL_MODEL_API = "pi-virtual";

export function isVirtualModel(model: { api: string }): boolean {
  return model.api === VIRTUAL_MODEL_API;
}
