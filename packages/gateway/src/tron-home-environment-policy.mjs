import { isAbsolute, resolve, sep } from "node:path";
import { pathToFileURL } from "node:url";
import { homedir, userInfo } from "node:os";

export function resolveTronHomePath(environment = process.env) {
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

function containsTronHomePath(value, home) {
  const absolute = resolve(home);
  const forms = [absolute];
  const user = resolve(homedir());
  if (absolute.startsWith(`${user}/`)) forms.push(`~${absolute.slice(user.length)}`);
  const alternatives = forms.map(form => form.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")).join("|");
  return new RegExp(`(?<![A-Za-z0-9._-])(?:${alternatives})(?![A-Za-z0-9._-])`).test(value);
}

const TRON_HOME_SELECTORS = new Set(["TRON_DATA_DIR", "TRON_HOME_NAME"]);

function tronHomeLeaks(environment, homes) {
  return Object.entries(environment).flatMap(([name, value]) => {
    if (name === "PATH" || typeof value !== "string") return [];
    if (name === "TRON_HOME_NAME") {
      if (environment.TRON_DATA_DIR) return [];
      const selected = resolveTronHomePath(environment);
      return homes.some(home => selected === resolve(home) || selected.startsWith(`${resolve(home)}${sep}`))
        ? [{ name, location: selected, selector: true }]
        : [];
    }
    const home = homes.find(candidate => containsTronHomePath(value, candidate));
    return home ? [{ name, location: resolve(home), selector: TRON_HOME_SELECTORS.has(name) }] : [];
  });
}

export function removableTronHomeVariables(environment, homes) {
  return tronHomeLeaks(environment, homes).filter(leak => !leak.selector).map(leak => leak.name);
}

export function refusedTronHomeEnvironmentLeaks(environment, homes) {
  return tronHomeLeaks(environment, homes).filter(leak => leak.selector).map(leak => `${leak.name}=${leak.location}`);
}

export function environmentTronHomes(environment = process.env) {
  const accounts = [...new Set([homedir(), userInfo().homedir])];
  const liveHomes = accounts.flatMap(account => [resolve(account, ".tron"), resolve(account, ".tron-dev")]);
  return [...new Set([...liveHomes, resolveTronHomePath(environment)])];
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  const homes = environmentTronHomes(process.env);
  const refused = refusedTronHomeEnvironmentLeaks(process.env, homes);
  if (refused.length) {
    console.error(`Tron-home environment preflight failed: ${refused.join(", ")}`);
    process.exitCode = 1;
  } else {
    for (const name of removableTronHomeVariables(process.env, homes)) console.log(name);
  }
}
