import { environmentTronHomes, tronHomeEnvironmentLeaks } from "../src/tron-home-environment-policy.mjs";

const leaked = tronHomeEnvironmentLeaks(process.env, environmentTronHomes(process.env));
if (leaked.length > 0) {
  throw new Error(`Gateway tests refuse inherited Tron-home environment values: ${leaked.join(", ")}`);
}
