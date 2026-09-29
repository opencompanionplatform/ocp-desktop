import { findInstallHandoffArg, sanitizeInstallHandoff } from "./install-handoff";
import { findStoreDeepLinkArg, sanitizeStoreDeepLink } from "../src/contracts/store-deep-link";
import { parseShellIntentArgs, type ShellSource, type ShellView } from "../src/contracts/shell-intent";

export type ProtocolInvocationDiagnostic = Readonly<{
  argCount: number;
  hasOcpArg: boolean;
  parsedInstall: boolean;
  parsedStore: boolean;
  additionalInstallParsed: boolean;
  shellIntentParsed: boolean;
  openView: ShellView | "none";
  sourceKind: ShellSource | "none";
  warm: boolean;
  hasRuntimeBridgeArgs: boolean;
  hasCredentialBrokerArgs: boolean;
  source: "argv" | "additionalData" | "none";
}>;

function hasArgPrefix(argv: readonly string[], prefix: string): boolean {
  return argv.some((arg) => typeof arg === "string" && arg.startsWith(prefix));
}

export function summarizeProtocolInvocation(argv: readonly string[], additionalData: unknown): ProtocolInvocationDiagnostic {
  const hasOcpArg = argv.some((arg) => typeof arg === "string" && arg.toLowerCase().startsWith("ocp://"));
  const parsedInstall = findInstallHandoffArg(argv) !== null;
  const argvStoreParsed = findStoreDeepLinkArg(argv) !== null;
  const additionalInstallParsed = typeof additionalData === "object" && additionalData !== null
    ? sanitizeInstallHandoff((additionalData as Record<string, unknown>).installHandoff) !== null
    : false;
  const additionalStoreParsed = typeof additionalData === "object" && additionalData !== null
    ? sanitizeStoreDeepLink((additionalData as Record<string, unknown>).storeLink) !== null
    : false;
  const parsedStore = argvStoreParsed || additionalStoreParsed;

  const hasExplicitShellIntent = hasArgPrefix(argv, "--ocp-open=") || hasArgPrefix(argv, "--ocp-source=");
  const shellIntent = hasExplicitShellIntent ? parseShellIntentArgs(argv) : null;
  const shellIntentParsed = shellIntent?.ok === true;
  const openView = shellIntent?.ok ? shellIntent.value.view : "none";
  const sourceKind = shellIntent?.ok ? shellIntent.value.source : "none";
  const warm = argv.includes("--ocp-warm=1");
  const hasRuntimeBridgeArgs = hasArgPrefix(argv, "--ocp-bridge-dir=") && hasArgPrefix(argv, "--ocp-bridge-token=");
  const hasCredentialBrokerArgs = hasArgPrefix(argv, "--ocp-credential-pipe=") && hasArgPrefix(argv, "--ocp-credential-capability=");

  return {
    argCount: argv.length,
    hasOcpArg,
    parsedInstall,
    parsedStore,
    additionalInstallParsed,
    shellIntentParsed,
    openView,
    sourceKind,
    warm,
    hasRuntimeBridgeArgs,
    hasCredentialBrokerArgs,
    source: additionalInstallParsed || additionalStoreParsed ? "additionalData" : parsedInstall || parsedStore ? "argv" : "none",
  };
}
