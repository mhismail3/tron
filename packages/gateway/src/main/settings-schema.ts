import { createSettingsSchema } from "../admin/settings-schema.js";
import { HOME_TOOL_NAMES } from "../modules/home/home-runtime-policy.js";
import { COMPACTION_POLICY_INSTRUCTION_LIMIT } from "../kernel/run/compaction-policy.js";
import { validateMacTerminalKey } from "../security/mac-terminal.js";

export function createGatewaySettingsSchema() {
  return createSettingsSchema(HOME_TOOL_NAMES, COMPACTION_POLICY_INSTRUCTION_LIMIT, validateMacTerminalKey);
}
