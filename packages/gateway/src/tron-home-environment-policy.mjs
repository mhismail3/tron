import { delimiter, isAbsolute, resolve, sep } from "node:path";
import { pathToFileURL } from "node:url";
import { homedir } from "node:os";

function selectedHome(environment) {
  if (environment.TRON_DATA_DIR) {
    if (!isAbsolute(environment.TRON_DATA_DIR)) throw new Error("TRON_DATA_DIR must be absolute");
    return resolve(environment.TRON_DATA_DIR);
  }
  const name = environment.TRON_HOME_NAME;
  if (name) {
    if (name === "." || name === ".." || name.includes("/")) {
      throw new Error("TRON_HOME_NAME must be one home-relative directory name");
    }
    return resolve(homedir(), name);
  }
  return resolve(homedir(), ".tron");
}

function expandTilde(value) {
  if (value === "~") return homedir();
  if (value.startsWith("~/") || value.startsWith("~\\")) return resolve(homedir(), value.slice(2));
  return value;
}

function normalizedParts(value) {
  return value.split(delimiter).filter(Boolean).map(part => resolve(expandTilde(part)));
}

export function isTronHomePath(value, homes) {
  return normalizedParts(value).some(path => homes.some(home => path === resolve(home) || path.startsWith(`${resolve(home)}${sep}`)));
}

export function tronHomeEnvironmentLeaks(environment, homes) {
  return Object.entries(environment).flatMap(([name, value]) => {
    if (typeof value !== "string") return [];
    const home = homes.find(candidate => isTronHomePath(value, [candidate]));
    return home ? [`${name}=${resolve(home)}`] : [];
  });
}

export function environmentTronHomes(environment = process.env) {
  return [...new Set([resolve(homedir(), ".tron"), resolve(homedir(), ".tron-dev"), selectedHome(environment)].filter(Boolean))];
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  const leaked = tronHomeEnvironmentLeaks(process.env, environmentTronHomes(process.env));
  if (leaked.length) {
    console.error(`Tron-home environment preflight failed: ${leaked.join(", ")}`);
    process.exitCode = 1;
  }
}
