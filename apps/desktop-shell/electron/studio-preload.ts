import { contextBridge, ipcRenderer } from "electron";

import type {
  StudioCloudRequestInput,
  StudioCloudResponse,
  StudioEnvironment,
  StudioOAuthBeginResult,
  StudioOAuthCallbackResult,
  StudioOAuthOpenInput,
  StudioPackageSaveInput,
  StudioPackageSignInput,
  StudioSignedPackageResult,
  StudioSigningIdentity,
  StudioSigningProvisionInput,
  StudioPresignedUploadInput,
  StudioPresignedUploadResult,
  StudioProjectSaveInput,
  StudioRevealResult,
  StudioRuntimeTestResult,
  StudioSaveResult,
  StudioWorkspaceResult,
} from "./studio-bridge";

export type OcpStudioDesktopApi = Readonly<{
  getEnvironment: () => Promise<StudioEnvironment>;
  beginOAuth: () => Promise<StudioOAuthBeginResult>;
  openOAuth: (input: StudioOAuthOpenInput) => Promise<void>;
  waitOAuth: () => Promise<StudioOAuthCallbackResult>;
  chooseWorkspace: () => Promise<StudioWorkspaceResult>;
  saveProject: (input: StudioProjectSaveInput) => Promise<StudioSaveResult>;
  savePackage: (input: StudioPackageSaveInput) => Promise<StudioSaveResult>;
  getSigningIdentity: () => Promise<StudioSigningIdentity>;
  provisionSigningIdentity: (input: StudioSigningProvisionInput) => Promise<StudioSigningIdentity>;
  signPackageDraft: (input: StudioPackageSignInput) => Promise<StudioSignedPackageResult>;
  cloudRequest: (input: StudioCloudRequestInput) => Promise<StudioCloudResponse>;
  uploadPresigned: (input: StudioPresignedUploadInput) => Promise<StudioPresignedUploadResult>;
  revealLastOutput: () => Promise<StudioRevealResult>;
  installLastBuildToRuntime: () => Promise<StudioRuntimeTestResult>;
}>;

const studioApi: OcpStudioDesktopApi = Object.freeze({
  getEnvironment: (): Promise<StudioEnvironment> =>
    ipcRenderer.invoke("ocp:studio:get-environment") as Promise<StudioEnvironment>,
  beginOAuth: (): Promise<StudioOAuthBeginResult> =>
    ipcRenderer.invoke("ocp:studio:oauth-begin") as Promise<StudioOAuthBeginResult>,
  openOAuth: (input: StudioOAuthOpenInput): Promise<void> =>
    ipcRenderer.invoke("ocp:studio:oauth-open", input) as Promise<void>,
  waitOAuth: (): Promise<StudioOAuthCallbackResult> =>
    ipcRenderer.invoke("ocp:studio:oauth-wait") as Promise<StudioOAuthCallbackResult>,
  chooseWorkspace: (): Promise<StudioWorkspaceResult> =>
    ipcRenderer.invoke("ocp:studio:choose-workspace") as Promise<StudioWorkspaceResult>,
  saveProject: (input: StudioProjectSaveInput): Promise<StudioSaveResult> =>
    ipcRenderer.invoke("ocp:studio:save-project", input) as Promise<StudioSaveResult>,
  savePackage: (input: StudioPackageSaveInput): Promise<StudioSaveResult> =>
    ipcRenderer.invoke("ocp:studio:save-package", input) as Promise<StudioSaveResult>,
  getSigningIdentity: (): Promise<StudioSigningIdentity> =>
    ipcRenderer.invoke("ocp:studio:get-signing-identity") as Promise<StudioSigningIdentity>,
  provisionSigningIdentity: (input: StudioSigningProvisionInput): Promise<StudioSigningIdentity> =>
    ipcRenderer.invoke("ocp:studio:provision-signing-identity", input) as Promise<StudioSigningIdentity>,
  signPackageDraft: (input: StudioPackageSignInput): Promise<StudioSignedPackageResult> =>
    ipcRenderer.invoke("ocp:studio:sign-package-draft", input) as Promise<StudioSignedPackageResult>,
  cloudRequest: (input: StudioCloudRequestInput): Promise<StudioCloudResponse> =>
    ipcRenderer.invoke("ocp:studio:cloud-request", input) as Promise<StudioCloudResponse>,
  uploadPresigned: (input: StudioPresignedUploadInput): Promise<StudioPresignedUploadResult> =>
    ipcRenderer.invoke("ocp:studio:upload-presigned", input) as Promise<StudioPresignedUploadResult>,
  revealLastOutput: (): Promise<StudioRevealResult> =>
    ipcRenderer.invoke("ocp:studio:reveal-last-output") as Promise<StudioRevealResult>,
  installLastBuildToRuntime: (): Promise<StudioRuntimeTestResult> =>
    ipcRenderer.invoke("ocp:studio:install-last-build-to-runtime") as Promise<StudioRuntimeTestResult>,
});

contextBridge.exposeInMainWorld("ocpStudio", studioApi);
