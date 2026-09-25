import type { AssistantMessage, Context, ImageContent, Model } from "@earendil-works/pi-ai";

/** Synthetic 3×2 RGBA PNG. It contains no user or host data. */
export const SYNTHETIC_NATIVE_IMAGE: ImageContent = {
  type: "image",
  data: "iVBORw0KGgoAAAANSUhEUgAAAAMAAAACCAYAAACddGYaAAAAEUlEQVR4nGP4z8DwH4YZkDkAm34L9XKwuTwAAAAASUVORK5CYII=",
  mimeType: "image/png",
};

/** A second image keeps the hook's non-target negative control observable. */
export const SYNTHETIC_UNRELATED_IMAGE: ImageContent = {
  type: "image",
  data: "iVBORw0KGgoAAAANSUhEUgAAAAIAAAADCAYAAAC56t6BAAAADklEQVR4nGNg+A+FGAwAm38L9SgUsAQAAAAASUVORK5CYII=",
  mimeType: "image/png",
};

export const SYNTHETIC_NATIVE_CALL_ID = "native-call";
export const SYNTHETIC_UNRELATED_CALL_ID = "unrelated-call";

export const COMPUTER_USE_FIXTURE_MODEL = {
  id: "computer-use-fixture",
  name: "Computer-use image serialization fixture",
  api: "openai-responses",
  provider: "computer-use-fixture",
  baseUrl: "https://computer-use-fixture.invalid/v1",
  reasoning: false,
  input: ["text", "image"],
  cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
  contextWindow: 32_000,
  maxTokens: 1_000,
} satisfies Model<"openai-responses">;

const emptyUsage = {
  input: 0,
  output: 0,
  cacheRead: 0,
  cacheWrite: 0,
  totalTokens: 0,
  cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 },
};

/**
 * A provider-bound history with two calls and two results. The first result is
 * the synthetic native observation; the second is an unrelated image control.
 */
export function syntheticComputerUseContext(): Context {
  const assistant: AssistantMessage = {
    role: "assistant",
    content: [
      { type: "toolCall", id: `${SYNTHETIC_NATIVE_CALL_ID}|fc_native`, name: "computer", arguments: { action: "observe" } },
      { type: "toolCall", id: `${SYNTHETIC_UNRELATED_CALL_ID}|fc_other`, name: "other", arguments: { action: "observe" } },
    ],
    api: COMPUTER_USE_FIXTURE_MODEL.api,
    provider: COMPUTER_USE_FIXTURE_MODEL.provider,
    model: COMPUTER_USE_FIXTURE_MODEL.id,
    usage: emptyUsage,
    stopReason: "toolUse",
    timestamp: 2,
  };

  return {
    messages: [
      {
        role: "user",
        content: [
          { type: "text", text: "Keep this unrelated user image unchanged." },
          SYNTHETIC_UNRELATED_IMAGE,
        ],
        timestamp: 1,
      },
      assistant,
      {
        role: "toolResult",
        toolCallId: `${SYNTHETIC_NATIVE_CALL_ID}|fc_native`,
        toolName: "computer",
        content: [
          { type: "text", text: "synthetic native observation; call identity is native-call" },
          SYNTHETIC_NATIVE_IMAGE,
        ],
        isError: false,
        timestamp: 3,
      },
      {
        role: "toolResult",
        toolCallId: `${SYNTHETIC_UNRELATED_CALL_ID}|fc_other`,
        toolName: "other",
        content: [{ type: "text", text: "unrelated result" }, SYNTHETIC_UNRELATED_IMAGE],
        isError: false,
        timestamp: 4,
      },
    ],
  };
}

export interface PngDimensions {
  width: number;
  height: number;
}

/** Decode only PNG metadata needed by this fixture; no image pixels are written. */
export function pngDimensions(image: ImageContent): PngDimensions {
  const bytes = Buffer.from(image.data, "base64");
  if (bytes.length < 24 || bytes.subarray(0, 8).toString("hex") !== "89504e470d0a1a0a" || bytes.subarray(12, 16).toString("ascii") !== "IHDR") {
    throw new Error("fixture image is not a PNG with an IHDR chunk");
  }
  return { width: bytes.readUInt32BE(16), height: bytes.readUInt32BE(20) };
}
