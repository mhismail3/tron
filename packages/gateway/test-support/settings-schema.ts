import { createGatewaySettingsSchema } from "../src/main/settings-schema.js";

/** The real immutable metadata shared by each composed fixture Gateway. */
export const TEST_SETTINGS_SCHEMA = createGatewaySettingsSchema();
