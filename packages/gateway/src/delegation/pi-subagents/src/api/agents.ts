import type { RegisterRuntimeAgentInput, RuntimeAgentDefinition, RuntimeAgentRegistration } from "../agents/runtime-agent-registry.js";
export { registerRuntimeAgent as registerAgent } from "../agents/runtime-agent-registry.js";
export {
	RUNTIME_AGENT_REGISTER_EVENT,
	RUNTIME_AGENT_REGISTER_VERSION,
	registerAgentViaEvents,
	type RegisterRuntimeAgentViaEventsInput,
	type RuntimeAgentRegistrationRequest,
	type RuntimeAgentRegistrationResult,
} from "../agents/runtime-agent-events.js";

export type { RegisterRuntimeAgentInput, RuntimeAgentDefinition, RuntimeAgentRegistration };
