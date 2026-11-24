import { browserExtension } from "./managed-browser.js";

const agentDir = process.env.PI_CODING_AGENT_DIR;
if (!agentDir) throw new Error("The pinned child browser requires the Gateway agent directory");
export default browserExtension(agentDir);
