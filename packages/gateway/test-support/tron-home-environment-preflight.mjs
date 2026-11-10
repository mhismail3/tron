import { environmentTronHomes, refusedTronHomeEnvironmentLeaks, removableTronHomeVariables } from "../src/tron-home-environment-policy.mjs";

const homes = environmentTronHomes(process.env);
for (const name of removableTronHomeVariables(process.env, homes)) delete process.env[name];

delete process.env.PI_SUBAGENT_CHILD;

const refused = refusedTronHomeEnvironmentLeaks(process.env, homes);
if (refused.length > 0) {
  throw new Error(`Gateway tests refuse inherited Tron-home selectors: ${refused.join(", ")}`);
}
