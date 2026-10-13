import { isAbsolute, resolve, sep } from "node:path";
import { pathToFileURL } from "node:url";
import { homedir } from "node:os";

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

// A home may appear alone (PI_SESSION_FILE), in a PATH-style list, or inside a JSON
// value (JITI_ALIAS). It matches as a whole path: a sibling such as .tron-dev or
// .tron.bak, or a longer name that ends in the home, does not match.
function containsTronHomePath(value, home) {
  const absolute = resolve(home);
  const forms = [absolute];
  const user = resolve(homedir());
  if (absolute.startsWith(`${user}/`)) forms.push(`~${absolute.slice(user.length)}`);
  const alternatives = forms.map(form => form.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")).join("|");
  return new RegExp(`(?<![A-Za-z0-9._-])(?:${alternatives})(?![A-Za-z0-9._-])`).test(value);
}

// Selectors choose the data root itself. Dropping one would fall back to the
// default ~/.tron (the Stable home) or retarget another home, so they are refused.
const TRON_HOME_SELECTORS = new Set(["TRON_DATA_DIR", "TRON_HOME_NAME"]);

function tronHomeLeaks(environment, homes) {
  return Object.entries(environment).flatMap(([name, value]) => {
    // PATH locates executables; it does not select or name a Tron data root.
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

/**
 * Inherited variables whose value contains a live-home path, other than home selectors:
 * removing them is safe because the owner derives its default location.
 */
export function removableTronHomeVariables(environment, homes) {
  return tronHomeLeaks(environment, homes).filter(leak => !leak.selector).map(leak => leak.name);
}

/** Selector variables that resolve into a live home; these are never removed. */
export function refusedTronHomeEnvironmentLeaks(environment, homes) {
  return tronHomeLeaks(environment, homes).filter(leak => leak.selector).map(leak => `${leak.name}=${leak.location}`);
}

export function environmentTronHomes(environment = process.env) {
  return [...new Set([resolve(homedir(), ".tron"), resolve(homedir(), ".tron-dev"), resolveTronHomePath(environment)])];
}

// Command-line owner for verify: prints the inherited variable names a check
// environment must drop, one per line, or refuses selectors that point into a home.
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
