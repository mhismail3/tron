import { environmentTronHomes, refusedTronHomeEnvironmentLeaks, removableTronHomeVariables } from "../src/tron-home-environment-policy.mjs";

// Inherited live-home paths (for example from a Stable agent shell) are dropped,
// so the suite sees the same environment a clean run sees. Selectors still refuse:
// dropping one would retarget the home rather than restore a clean environment.
const homes = environmentTronHomes(process.env);
for (const name of removableTronHomeVariables(process.env, homes)) delete process.env[name];

// Inherited agent-shell mode, not a live-home path: a delegated agent's shell
// exports PI_SUBAGENT_CHILD=1, which makes the managed pi-subagents act as a
// child and register no parent tools. Test processes are parent sessions; a
// test that needs child mode must set it itself.
delete process.env.PI_SUBAGENT_CHILD;

const refused = refusedTronHomeEnvironmentLeaks(process.env, homes);
if (refused.length > 0) {
  throw new Error(`Gateway tests refuse inherited Tron-home selectors: ${refused.join(", ")}`);
}
