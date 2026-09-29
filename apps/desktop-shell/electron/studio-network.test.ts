import { describe, expect, it } from "vitest";

import {
  DEFAULT_OCP_STUDIO_CLOUD_API_URL,
  resolveStudioCloudApiBase,
  sanitizeStudioCloudRequest,
  sanitizeStudioPresignedUploadInput,
  studioCloudResponseBodyWithinLimit,
} from "./studio-network";

const BASE = new URL(DEFAULT_OCP_STUDIO_CLOUD_API_URL);
const ACCESS = "account-session-token";

describe("Desktop Studio network boundary", () => {
  it("pins Cloud requests to the OCP API and explicit creator routes", () => {
    expect(resolveStudioCloudApiBase(undefined).toString()).toBe(DEFAULT_OCP_STUDIO_CLOUD_API_URL);

    const profile = sanitizeStudioCloudRequest({
      url: DEFAULT_OCP_STUDIO_CLOUD_API_URL + "/v1/creator/profile",
      method: "GET",
      accessToken: ACCESS,
      body: null,
    }, BASE);
    expect(profile?.method).toBe("GET");

    const identity = sanitizeStudioCloudRequest({
      url: DEFAULT_OCP_STUDIO_CLOUD_API_URL + "/v1/creator/identity?packageId=character.bible&displayName=BIBLE",
      method: "GET",
      accessToken: ACCESS,
      body: null,
    }, BASE);
    expect(identity).not.toBeNull();

    expect(sanitizeStudioCloudRequest({
      url: "https://evil.example/functions/v1/cloud-api/v1/creator/profile",
      method: "GET",
      accessToken: ACCESS,
      body: null,
    }, BASE)).toBeNull();

    expect(sanitizeStudioCloudRequest({
      url: DEFAULT_OCP_STUDIO_CLOUD_API_URL + "/v1/admin/operations/summary",
      method: "GET",
      accessToken: ACCESS,
      body: null,
    }, BASE)).toBeNull();
  });

  it("allows only method/path combinations needed by Animation Studio", () => {
    for (const request of [
      { url: "/v1/creator/publishers", method: "GET", body: null },
      { url: "/v1/creator/publishers", method: "POST", body: "{}" },
      { url: "/v1/creator/keys", method: "POST", body: "{}" },
      { url: "/v1/creator/submissions?publisherId=creator.demo", method: "GET", body: null },
      { url: "/v1/creator/identity?packageId=character.bible&displayName=BIBLE&publisherId=creator.demo", method: "GET", body: null },
      { url: "/v1/creator/identity/reservations/character.bible?publisherId=creator.demo", method: "DELETE", body: null },
    ]) {
      expect(sanitizeStudioCloudRequest({
        url: DEFAULT_OCP_STUDIO_CLOUD_API_URL + request.url,
        method: request.method,
        accessToken: ACCESS,
        body: request.body,
      }, BASE)).not.toBeNull();
    }

    expect(sanitizeStudioCloudRequest({
      url: DEFAULT_OCP_STUDIO_CLOUD_API_URL + "/v1/creator/uploads",
      method: "POST",
      accessToken: ACCESS,
      body: "{\"packageId\":\"character.bible\"}",
    }, BASE)).not.toBeNull();

    expect(sanitizeStudioCloudRequest({
      url: DEFAULT_OCP_STUDIO_CLOUD_API_URL + "/v1/creator/uploads",
      method: "DELETE",
      accessToken: ACCESS,
      body: null,
    }, BASE)).toBeNull();

    expect(sanitizeStudioCloudRequest({
      url: DEFAULT_OCP_STUDIO_CLOUD_API_URL + "/v1/creator/identity/reservations/character.bible",
      method: "DELETE",
      accessToken: ACCESS,
      body: null,
    }, BASE)).not.toBeNull();
  });

  it("accepts only signed Cloudflare R2 PUT capability URLs", () => {
    const query = new URLSearchParams({
      "X-Amz-Algorithm": "AWS4-HMAC-SHA256",
      "X-Amz-Credential": "AKIAEXAMPLE/20260913/auto/s3/aws4_request",
      "X-Amz-Date": "20260913T010203Z",
      "X-Amz-Expires": "900",
      "X-Amz-SignedHeaders": "host",
      "X-Amz-Signature": "a".repeat(64),
    });
    const url = "https://ocp-packages.0123456789abcdef0123456789abcdef.r2.cloudflarestorage.com/creator-staging/demo.ocp?" + query;
    expect(sanitizeStudioPresignedUploadInput({
      url,
      bytes: new Uint8Array([1, 2, 3]),
    })?.bytes.byteLength).toBe(3);

    expect(sanitizeStudioPresignedUploadInput({
      url: "https://example.com/demo.ocp?" + query,
      bytes: new Uint8Array([1]),
    })).toBeNull();
    expect(sanitizeStudioPresignedUploadInput({
      url: "https://ocp-packages.0123456789abcdef0123456789abcdef.r2.cloudflarestorage.com/demo.ocp",
      bytes: new Uint8Array([1]),
    })).toBeNull();
  });

  it("caps proxied Cloud response bodies", () => {
    expect(studioCloudResponseBodyWithinLimit("{}")).toBe(true);
    expect(studioCloudResponseBodyWithinLimit("x".repeat(2_000_001))).toBe(false);
  });
});
