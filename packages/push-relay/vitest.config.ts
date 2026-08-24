import { cloudflareTest } from "@cloudflare/vitest-pool-workers";
import { defineConfig } from "vitest/config";

const testApnsKey = `-----BEGIN PRIVATE KEY-----
MIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQgfmml8ugEZIOvvnw9
iH3e0i5VQ+AB9iLqLPKf+KoNsOihRANCAARvWfF6FsobNcx5TXnlnQo+r2Ug3Bn6
OAtRyfvSosZt+A035KLUfFIhRXveQvVErW4G5ViLw3UIbB8UfFqV+0L9
-----END PRIVATE KEY-----`;

export default defineConfig({
  plugins: [cloudflareTest({
    wrangler: { configPath: "./wrangler.toml" },
    miniflare: {
      bindings: {
        APNS_KEY_P8: testApnsKey,
        APNS_KEY_ID: "TESTKEY001",
        APNS_TEAM_ID: "MYGKXH6TY4",
        APPLE_TEAM_ID: "MYGKXH6TY4",
      },
    },
  })],
  test: {
    include: ["tests/**/*.test.ts"],
  },
});
