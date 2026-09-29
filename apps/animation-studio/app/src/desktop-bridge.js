const MAX_PACKAGE_BYTES = 64 * 1024 * 1024;

function candidateBridge(scope) {
  if (!scope || typeof scope !== "object") return null;
  const windowObject = scope.window && typeof scope.window === "object" ? scope.window : null;
  const bridge = windowObject?.ocpStudio ?? scope.ocpStudio ?? null;
  if (!bridge || typeof bridge !== "object") return null;
  const required = [
    "getEnvironment",
    "beginOAuth",
    "openOAuth",
    "waitOAuth",
    "chooseWorkspace",
    "saveProject",
    "savePackage",
    "getSigningIdentity",
    "provisionSigningIdentity",
    "signPackageDraft",
    "cloudRequest",
    "uploadPresigned",
    "revealLastOutput",
    "installLastBuildToRuntime",
  ];
  return required.every((name) => typeof bridge[name] === "function") ? bridge : null;
}

export function getDesktopStudioBridge(scope = globalThis) {
  return candidateBridge(scope);
}

export async function saveProjectToDesktop(content, fileName, bridge = getDesktopStudioBridge()) {
  if (!bridge) return null;
  if (typeof content !== "string" || content.length < 2 || typeof fileName !== "string" || !fileName.endsWith(".ocp-project.json")) {
    throw new TypeError("desktop project save input is invalid");
  }
  return await bridge.saveProject({ fileName, content });
}

export async function savePackageToDesktop(blob, fileName, bridge = getDesktopStudioBridge()) {
  if (!bridge) return null;
  if (!(blob instanceof Blob) || blob.size < 1 || blob.size > MAX_PACKAGE_BYTES || typeof fileName !== "string" || !fileName.toLowerCase().endsWith(".ocp")) {
    throw new TypeError("desktop package save input is invalid");
  }
  const bytes = new Uint8Array(await blob.arrayBuffer());
  return await bridge.savePackage({ fileName, bytes });
}

export async function getDesktopSigningIdentity(bridge = getDesktopStudioBridge()) {
  return bridge ? await bridge.getSigningIdentity() : null;
}

export async function provisionDesktopSigningIdentity(publisherId, bridge = getDesktopStudioBridge()) {
  if (!bridge) return null;
  if (typeof publisherId !== "string" || !/^[a-z0-9]+(?:[.-][a-z0-9]+)*$/.test(publisherId.trim().toLowerCase())) {
    throw new TypeError("desktop publisher id is invalid");
  }
  return await bridge.provisionSigningIdentity({ publisherId: publisherId.trim().toLowerCase() });
}

export async function signPackageWithDesktop(blob, bridge = getDesktopStudioBridge()) {
  if (!bridge) return null;
  if (!(blob instanceof Blob) || blob.size < 1 || blob.size > MAX_PACKAGE_BYTES) {
    throw new TypeError("desktop signing package is invalid");
  }
  const result = await bridge.signPackageDraft({ bytes: new Uint8Array(await blob.arrayBuffer()) });
  if (!result?.bytes) throw new Error("Desktop signer returned invalid data");
  const bytes = result.bytes instanceof Uint8Array ? result.bytes : new Uint8Array(result.bytes);
  if (bytes.byteLength < 1 || bytes.byteLength > MAX_PACKAGE_BYTES) throw new Error("Desktop signer returned invalid package");
  return new Blob([bytes], { type: "application/octet-stream" });
}

export function createDesktopCreatorCloudFetch(cloudApiUrl, bridge = getDesktopStudioBridge(), fallbackFetch = fetch) {
  if (!bridge || typeof bridge.cloudRequest !== "function" || typeof bridge.uploadPresigned !== "function") return fallbackFetch;
  const base = new URL(cloudApiUrl);
  base.pathname = base.pathname.replace(/\/+$/, "");

  return async (resource, init = {}) => {
    const url = new URL(typeof resource === "string" || resource instanceof URL ? String(resource) : resource.url);
    const method = String(init.method || "GET").toUpperCase();
    const isCloud = url.origin === base.origin
      && (url.pathname === base.pathname || url.pathname.startsWith(base.pathname + "/"));

    if (isCloud) {
      const headers = new Headers(init.headers || {});
      const authorization = headers.get("authorization") || "";
      const prefix = "Bearer ";
      if (!authorization.startsWith(prefix) || authorization.length <= prefix.length) {
        throw new Error("Desktop Studio Cloud request requires an account session");
      }
      const body = init.body == null
        ? null
        : typeof init.body === "string"
          ? init.body
          : (() => { throw new TypeError("Desktop Studio Cloud request body must be JSON text"); })();
      const result = await bridge.cloudRequest({
        url: url.toString(),
        method,
        accessToken: authorization.slice(prefix.length),
        body,
      });
      return new Response(result.bodyText, {
        status: result.status,
        headers: { "content-type": result.contentType || "application/json" },
      });
    }

    if (method === "PUT" && url.protocol === "https:" && init.body instanceof Blob) {
      const result = await bridge.uploadPresigned({
        url: url.toString(),
        bytes: new Uint8Array(await init.body.arrayBuffer()),
      });
      return new Response(null, { status: result.status });
    }

    throw new Error("Desktop Studio network request is not allowlisted");
  };
}

export async function readDesktopStudioEnvironment(bridge = getDesktopStudioBridge()) {
  return bridge ? await bridge.getEnvironment() : null;
}

export async function beginDesktopStudioOAuth(bridge = getDesktopStudioBridge()) {
  return bridge ? await bridge.beginOAuth() : null;
}

export async function openDesktopStudioOAuth(url, bridge = getDesktopStudioBridge()) {
  if (!bridge) return null;
  if (typeof url !== "string" || !url.trim()) throw new TypeError("desktop OAuth URL is invalid");
  await bridge.openOAuth({ url });
  return await bridge.waitOAuth();
}

export async function chooseDesktopStudioWorkspace(bridge = getDesktopStudioBridge()) {
  return bridge ? await bridge.chooseWorkspace() : null;
}

export async function revealDesktopStudioOutput(bridge = getDesktopStudioBridge()) {
  return bridge ? await bridge.revealLastOutput() : null;
}

export async function installDesktopStudioBuildToRuntime(bridge = getDesktopStudioBridge()) {
  return bridge ? await bridge.installLastBuildToRuntime() : null;
}
