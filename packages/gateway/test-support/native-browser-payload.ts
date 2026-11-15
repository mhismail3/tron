import { readFileSync } from "node:fs";
import { join } from "node:path";

export function nativeBrowserPayloadFiles(gateway: string): string[] {
  const pin = "pi-agent-browser-native-patch.json";
  const { artifact } = JSON.parse(readFileSync(join(gateway, pin), "utf8")) as { artifact: { path: string } };
  if (!/^third_party\/pi-agent-browser-native\/[^/]+\.tgz$/u.test(artifact.path)) throw new Error("native browser artifact must stay inside its carrier directory");
  return ["package-lock.json", pin, artifact.path];
}
