# Open Companion Platform Code Signing Policy

This document defines the code-signing policy for official Open Companion Platform (OCP) Windows releases.

## Code signing policy

**Free code signing provided by SignPath.io, certificate by SignPath Foundation.**

This is the project's target Production signing policy while the SignPath Foundation application is being completed. No OCP artifact may be described as SignPath-signed until it has actually been processed by the approved OCP SignPath configuration.

The purpose of code signing is to give users a verifiable connection between the public OCP source repository, the automated build that produced a release, and the Windows binaries distributed by the project.

## Covered project

- Project: **Open Companion Platform (OCP)**
- Source repository: https://github.com/opencompanionplatform/ocp-desktop
- Official release repository: https://github.com/opencompanionplatform/ocp-releases
- Official releases: https://github.com/opencompanionplatform/ocp-releases/releases
- License: Apache License 2.0

Only OCP artifacts built from source controlled by the Open Companion Platform project may be submitted under the OCP signing configuration.

## Release provenance

Official signed artifacts must:

1. originate from the public OCP source repository;
2. correspond to an approved release revision/tag;
3. be built by the project's approved automated GitHub Actions workflow;
4. preserve enough build metadata to trace the artifact to its source revision and build run;
5. pass the release validation gates required by the repository;
6. be manually approved for signing by an authorized OCP approver;
7. be published only through an official Open Companion Platform release channel.

Release and signing workflow changes are security-sensitive changes and must be reviewed accordingly.

## Signing roles

OCP is currently maintained as an independent community project.

### Committer and reviewer

**Watchara Warin** — project maintainer.

Committers are trusted to make changes to the OCP source repository. Contributions from people who are not trusted committers must be reviewed by an OCP maintainer before they are merged.

GitHub organization:

https://github.com/opencompanionplatform

### Approver

**Watchara Warin** — project maintainer and current release signing approver.

The approver is responsible for checking that a signing request corresponds to the intended OCP release source revision and approved build before authorizing signing.

As the maintainer team grows, these roles may be delegated to documented GitHub organization teams. This policy must be updated when signing responsibilities change.

## Account security

Maintainers with source-code or signing access must use multi-factor authentication for GitHub and SignPath accounts.

Signing credentials or approval secrets must not be committed to the source repository.

## Artifact identity

Signed OCP binaries must use project/product metadata identifying them as **Open Companion Platform** and must use the release version associated with the approved build.

Third-party/upstream binaries must not be presented as if they were built or authored by OCP. Any upstream components included in OCP distributions remain subject to their own licenses and provenance.

### Godot Runtime boundary

OCP uses the official Godot Windows executable as the process that hosts the OCP Godot project/PCK. The release build copies that upstream executable and applies only the Windows Per-Monitor-V2 manifest required by OCP's multi-monitor DPI behavior. Because a PE resource edit invalidates the original upstream Authenticode signature, the copied derivative is stripped of that invalid signature before the PMv2 manifest is embedded.

The resulting `ocp-runtime.exe`:

- retains the upstream `Godot Engine` FileDescription, ProductName, and CompanyName;
- is recorded in release metadata as `godot-upstream-derivative-pmv2`;
- remains unsigned after the PMv2 patch; and
- is explicitly excluded from the OCP/SignPath Authenticode signing selection.

The OCP signing identity is reserved for OCP-owned binaries: the native launcher, kernel, native companion host, update checker, OCP GDExtension, Desktop Shell executable, and final Windows installer. This boundary prevents OCP from presenting the upstream Godot executable as an OCP-authored binary while preserving the PMv2 behavior required by the product.

## Privacy

OCP's privacy policy is documented in [PRIVACY.md](PRIVACY.md).

Public privacy policy:

https://ocp-store-prd.pages.dev/privacy/

OCP may communicate with network services when the user specifically requests or enables online functions such as account sign-in, the Store, cloud synchronization, updates, purchases, or optional AI/voice services. The privacy policy describes these behaviors and the relevant categories of third-party services.

## Installation and uninstallation

The official download location must describe the application and provide an installable or portable release as appropriate.

Installed builds must support normal Windows uninstallation. Portable builds can be removed by exiting OCP and deleting the extracted application directory; user data may be removed separately if the user wants a complete reset.

## Publication

Signed artifacts must be published through the official release repository:

https://github.com/opencompanionplatform/ocp-releases/releases

Release pages should include or link to this **Code signing policy** and retain the required SignPath attribution above.

## Policy changes

Changes to this document, release workflows, or signing configuration are treated as security-sensitive project changes and should be reviewed before they take effect.
