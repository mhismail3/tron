import { type ImageContent } from "@earendil-works/pi-ai";
import { openAIResponsesApi } from "@earendil-works/pi-ai/api/openai-responses.lazy";
import { describe, expect, it } from "vitest";
import {
  COMPUTER_USE_FIXTURE_MODEL,
  SYNTHETIC_NATIVE_CALL_ID,
  SYNTHETIC_NATIVE_IMAGE,
  SYNTHETIC_UNRELATED_CALL_ID,
  SYNTHETIC_UNRELATED_IMAGE,
  pngDimensions,
  syntheticComputerUseContext,
} from "../../test-fixtures/pi-sdk/computer-use-image.js";

interface PayloadRecord {
  input: PayloadItem[];
}

type PayloadItem = {
  type?: string;
  role?: string;
  call_id?: string;
  content?: PayloadItem[];
  output?: string | PayloadItem[];
  detail?: string;
  image_url?: string;
  text?: string;
};

function asPayload(value: unknown): PayloadRecord {
  if (!isRecord(value) || !Array.isArray(value.input)) throw new Error("provider payload did not contain input");
  return { input: value.input as PayloadItem[] };
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null;
}

type InputImagePart = PayloadItem & { type: "input_image"; image_url: string };

function imagePart(item: PayloadItem): InputImagePart {
  if (item.type !== "input_image" || typeof item.image_url !== "string") throw new Error("expected input image");
  return item as InputImagePart;
}

function imageFromPart(item: PayloadItem): ImageContent {
  const image = imagePart(item);
  const prefix = "data:";
  const separator = image.image_url.indexOf(",");
  if (!image.image_url.startsWith(prefix) || separator < 0) throw new Error("expected data URL payload");
  const header = image.image_url.slice(prefix.length, separator);
  const [mimeType, encoding] = header.split(";");
  if (!mimeType || encoding !== "base64") throw new Error("expected base64 image");
  return { type: "image", mimeType, data: image.image_url.slice(separator + 1) };
}

function resultOutput(payload: PayloadRecord, callId: string): PayloadItem[] {
  const result = payload.input.find((item) => item.type === "function_call_output" && item.call_id === callId);
  if (!result || !Array.isArray(result.output)) throw new Error(`missing function-call output for ${callId}`);
  return result.output;
}

async function captureRealProviderPayload() {
  let payload: unknown;
  let serializedPayload: unknown;
  let fetchCalls = 0;
  const stream = openAIResponsesApi().stream(COMPUTER_USE_FIXTURE_MODEL, syntheticComputerUseContext(), {
    apiKey: "synthetic-fixture-key",
    fetch: async (_input, init) => {
      fetchCalls++;
      if (typeof init?.body !== "string") throw new Error("Missing serialized fixture request");
      serializedPayload = JSON.parse(init.body);
      // An actual failed HTTP response avoids depending on how the SDK wraps
      // thrown errors across the test runner's VM boundary. Never delegate fetch.
      return new Response(JSON.stringify({ error: { message: "synthetic image transport halted" } }), {
        status: 418, headers: { "content-type": "application/json" },
      });
    },
    onPayload: (candidate) => {
      payload = candidate;
    },
  });
  const result = await stream.result();
  expect(result.stopReason).toBe("error");
  expect(result.errorMessage).toContain("synthetic image transport halted");
  expect(fetchCalls).toBe(1);
  expect(asPayload(serializedPayload)).toEqual(asPayload(payload));
  return { payload: asPayload(serializedPayload), fetchCalls };
}

describe("pinned Pi computer-use image serialization", () => {
  it("retains synthetic bytes, dimensions, order and call identity in the real Responses payload", async () => {
    const { payload, fetchCalls } = await captureRealProviderPayload();
    expect(fetchCalls).toBe(1);

    const nativeOutput = resultOutput(payload, SYNTHETIC_NATIVE_CALL_ID);
    const unrelatedOutput = resultOutput(payload, SYNTHETIC_UNRELATED_CALL_ID);
    expect(nativeOutput[0]).toMatchObject({ type: "input_text", text: expect.stringContaining("native observation") });
    expect(unrelatedOutput[0]).toMatchObject({ type: "input_text", text: "unrelated result" });
    expect(payload.input.filter((item) => item.type === "function_call_output").map((item) => item.call_id)).toEqual([
      SYNTHETIC_NATIVE_CALL_ID,
      SYNTHETIC_UNRELATED_CALL_ID,
    ]);

    const nativeImage = imageFromPart(nativeOutput[1]!);
    expect(nativeImage.data).toBe(SYNTHETIC_NATIVE_IMAGE.data);
    expect(nativeImage.mimeType).toBe(SYNTHETIC_NATIVE_IMAGE.mimeType);
    expect(pngDimensions(nativeImage)).toEqual({ width: 3, height: 2 });
    expect(nativeOutput[1]).toMatchObject({ type: "input_image", detail: "auto" });

    const unrelatedImage = imageFromPart(unrelatedOutput[1]!);
    expect(unrelatedImage.data).toBe(SYNTHETIC_UNRELATED_IMAGE.data);
    expect(pngDimensions(unrelatedImage)).toEqual({ width: 2, height: 3 });
    expect(unrelatedOutput[1]).toMatchObject({ type: "input_image", detail: "auto" });
  });
});
