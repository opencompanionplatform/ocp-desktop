# Open Companion Platform — Desktop

This repository contains the public Desktop/client source for **Open Companion Platform (OCP)**.

OCP Desktop is an open-source desktop companion runtime with character packages, animation, native desktop interaction, a Desktop Shell, local runtime services, package verification, update verification, and the embedded Animation Studio used by the Desktop application.

## Official repositories

- Public Desktop source: https://github.com/opencompanionplatform/ocp-desktop
- Official releases: https://github.com/opencompanionplatform/ocp-releases/releases
- Production Store: https://ocp-store-dp4.pages.dev

The hosted Store/Creator/Operations backend is operated separately and is not part of this public Desktop source repository.

## Source layout

- `apps/desktop-runtime` — Godot Desktop Runtime and character presentation/runtime logic.
- `apps/desktop-shell` — Electron Desktop Shell.
- `apps/animation-studio` — Animation Studio bundled with the Desktop Shell.
- `services/kernel` — local OCP kernel service.
- `services/launcher` — launcher and `ocp://` protocol handoff.
- `packages` — public Desktop/runtime libraries, package contracts, SDKs, verification and update components.
- `spike/native-companion-window` — production native companion window implementation retained at its historical source path.
- `release` — Desktop build, validation, installer, update and release-gate scripts.

## Public source provenance

This repository is synchronized from the private OCP integration monorepo through a strict allowlist exporter. `PUBLIC-SOURCE-INFO.json` records the originating integration commit and export policy for each synchronization.

Production releases must be built from an approved public `ocp-desktop` revision. Public source synchronization does not automatically publish a production release.

## Build prerequisites

Core development uses Rust, Godot and Node.js/Electron. Windows release builds additionally require the Windows SDK, Inno Setup and the approved Godot build/runtime inputs documented by the release scripts.

Common checks include:

```powershell
cargo test --workspace

cd apps\desktop-shell
npm ci
npm run typecheck
npm run lint
npm test
npm run build
```

See the scripts under `release/` for publishable Windows bundle and release-gate workflows.

## Forks and hosted services

Apache-2.0 permits forks and modifications. A fork may use a different Store, update service or package trust root. Official OCP services, signing keys, marketplace approvals and update signatures are controlled server-side and are not included as private credentials in this repository.

To avoid confusing users, redistributed forks should use distinct product branding, application identifiers, signing identities, update keys and service endpoints rather than presenting themselves as an official OCP build.

See `FORKING.md` for the project boundary between open source code and official hosted services.

## Security

Do not report vulnerabilities through public issues. Follow `SECURITY.md` for coordinated disclosure.

## Code signing policy

See `CODE_SIGNING.md`. OCP-owned release binaries are signed only through the approved release process. The PMv2-patched Godot runtime keeps upstream Godot identity and is outside the OCP Authenticode signing scope.

**Free code signing provided by SignPath.io, certificate by SignPath Foundation.**

OCP is completing the SignPath Foundation onboarding process. No artifact is described as SignPath-signed unless it was actually processed by the approved OCP SignPath configuration.

## License

Apache License 2.0. See `LICENSE`.

## Contact

Project contact: **opencompanionplatform@gmail.com**
