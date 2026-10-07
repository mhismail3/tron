import { homedir } from "node:os";
import { resolve } from "node:path";

const tronHomes = [resolve(homedir(), ".tron"), resolve(homedir(), ".tron-dev")];
const leaked = Object.entries(process.env).flatMap(([name, value]) => {
  if (value === undefined) return [];
  const normalized = value.replaceAll("\\", "/");
  const home = tronHomes.find(candidate => {
    const prefix = candidate.replaceAll("\\", "/");
    return normalized === prefix || normalized.startsWith(`${prefix}/`) || normalized.includes(`${prefix}/`);
  });
  return home ? [`${name}=${home}`] : [];
});

if (leaked.length > 0) {
  throw new Error(`Gateway tests refuse inherited Tron-home environment values: ${leaked.join(", ")}`);
}
