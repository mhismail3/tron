import { X509Certificate } from "@peculiar/x509";
import { encode } from "cbor-x";
import { describe, expect, test } from "vitest";
import { verifyAssertion, verifyAttestation } from "../src/app-attest";
import { APPLE_APP_ATTESTATION_ROOT_PEM } from "../src/apple-app-attestation-root";
import { base64Url, concatBytes, ownedBuffer, sha256, utf8 } from "../src/crypto";

async function assertionFixture(appId: string, counter: number, clientDataHash: Uint8Array) {
  const keys = await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"]);
  const rpIdHash = await sha256(utf8(appId));
  const authenticatorData = new Uint8Array(37);
  authenticatorData.set(rpIdHash);
  authenticatorData[32] = 0;
  new DataView(authenticatorData.buffer).setUint32(33, counter, false);
  const rawSignature = new Uint8Array(await crypto.subtle.sign(
    { name: "ECDSA", hash: "SHA-256" },
    keys.privateKey,
    ownedBuffer(concatBytes(authenticatorData, clientDataHash)),
  ));
  const signature = rawEcdsaToDer(rawSignature);
  const spki = new Uint8Array(await crypto.subtle.exportKey("spki", keys.publicKey));
  return {
    assertionObject: base64Url(encode({ authenticatorData, signature })),
    publicKeySpki: base64Url(spki),
  };
}

function rawEcdsaToDer(raw: Uint8Array): Uint8Array {
  function integer(value: Uint8Array): Uint8Array {
    let start = 0;
    while (start < value.byteLength - 1 && value[start] === 0) start += 1;
    let significant: Uint8Array<ArrayBufferLike> = value.slice(start);
    if ((significant[0] & 0x80) !== 0) significant = concatBytes(new Uint8Array([0]), significant);
    return concatBytes(new Uint8Array([0x02, significant.byteLength]), significant);
  }
  const r = integer(raw.slice(0, 32));
  const s = integer(raw.slice(32));
  return concatBytes(new Uint8Array([0x30, r.byteLength + s.byteLength]), r, s);
}

describe("Apple App Attest verification", () => {
  test("parses the pinned Apple trust root in the Workers runtime", () => {
    const root = new X509Certificate(APPLE_APP_ATTESTATION_ROOT_PEM);
    expect(root.subject).toContain("Apple App Attestation Root CA");
    expect(root.notAfter.getTime()).toBeGreaterThan(Date.now());
  });

  test("verifies a signed assertion and enforces the monotonic counter and relying party", async () => {
    const clientDataHash = await sha256(utf8("canonical registration"));
    const fixture = await assertionFixture("TEAMID.com.tron.mobile.beta", 7, clientDataHash);
    await expect(verifyAssertion({ ...fixture, clientDataHash, appId: "TEAMID.com.tron.mobile.beta", previousCounter: 6 })).resolves.toBe(7);
    await expect(verifyAssertion({ ...fixture, clientDataHash, appId: "TEAMID.com.tron.mobile.beta", previousCounter: 7 })).rejects.toThrow("assertion_replay");
    await expect(verifyAssertion({ ...fixture, clientDataHash, appId: "TEAMID.com.attacker", previousCounter: 6 })).rejects.toThrow("invalid_relying_party");
  });

  test("fails closed on malformed attestation instead of admitting a development bypass", async () => {
    await expect(verifyAttestation({
      attestationObject: base64Url(encode({ fmt: "none", attStmt: {}, authData: new Uint8Array(37) })),
      keyId: "k".repeat(43),
      clientDataHash: new Uint8Array(32),
      appId: "TEAMID.com.tron.mobile.beta",
      environment: "development",
    })).rejects.toThrow("invalid_attestation_format");
  });
});
