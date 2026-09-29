# OCP Animation Studio

OCP Animation Studio is the local-first authoring surface bundled with OCP Desktop. Production users open it from the Electron Desktop Shell; they do **not** run a separate local API service.

## Maintained authoring modes

### Character Animation

- Character/3 package authoring.
- Standard compatibility animation set plus optional directional/interaction clips.
- Custom animations/actions such as `charge_power`, `jump_scare`, or `bomb_drop`.
- MP4 import, timing, chroma cleanup, character standardization, sprite-sheet composition, Runtime preview, QC, package build, local Desktop signing, Runtime test, Creator Cloud upload/validation, and Creator Portal handoff.
- Backward-compatible Runtime selection keeps existing Bible/Sabai packages valid when optional clips are absent. `climb_top` and `drag_release` are optional transitions; directional `climb_up_left/right` and `climb_down_left/right` are recommended for text, logos, vehicles, or asymmetric costumes that must never be mirrored.

### Sprite Sheet FX

- Builds `effect-pack/1` packages from video-derived sprite sheets.
- Canonical slots: `bodyAura`, `groundRune`, `levelUpBurst`.
- Current release status: **Admin/Beta**.
- Local compose/build/sign/Runtime validation is enabled for allowlisted beta publishers.
- Public Creator Cloud publication remains disabled until the authenticated Effect Pack creator → moderation → Store → install E2E gate passes.

The legacy procedural **Effect Studio** has been removed. Sprite Sheet FX is the maintained Effect Pack authoring workflow.

## Production architecture

```text
OCP Desktop Installer
  └─ Electron Desktop Shell
      └─ resources/studio/
          └─ bundled React/Vite Animation Studio
```

Privileged desktop operations are exposed through the narrow Electron preload bridge:

- choose/save workspace
- save project/package
- provision protected Creator signing identity
- sign package with the bundled OCP signer
- OAuth loopback
- allowlisted Creator Cloud / R2 requests
- reveal build output
- install the last build into Runtime

There is no `apps/animation-studio/api` service in the current architecture. Browser development supports OCP Account authentication and Creator Cloud profile/session work, but package signing remains desktop-only because protected signing material is exposed only through the Electron bridge.

For browser OAuth development, Supabase Auth must allow the exact callback URL used by Vite. The default local callback is `http://localhost:5184/oauth/callback`; add that exact URL to the Auth redirect allowlist. The web flow exchanges the PKCE authorization code explicitly in the popup and then refreshes the opener session without reloading Studio work.

## Source layout

```text
apps/animation-studio/
├─ app/
│  ├─ src/
│  │  ├─ components/              # shared shell/account/navigation components
│  │  ├─ config/                  # feature gates
│  │  ├─ features/
│  │  │  ├─ character/            # catalog, subject fit, Store preview contract
│  │  │  └─ sprite-fx/            # Sprite Sheet FX UI + effect-pack model
│  │  ├─ creator-cloud.js         # Creator Cloud/auth workflow
│  │  ├─ desktop-bridge.js        # Electron preload adapter
│  │  ├─ main.jsx                 # Character authoring orchestration + processing core
│  │  └─ styles.css
│  └─ test/
└─ tools/
```

`main.jsx` intentionally retains the tightly coupled image-processing/chroma pipeline. Shared shell UI and independent features are split into components/features so normal UI changes do not require editing the processing core.

## Development

Browser preview:

```powershell
cd D:\ocp-platform\apps\animation-studio\app
npm install
npm run dev
```

The browser build can import/process/preview/export local artifacts, but production package signing is an OCP Desktop capability.

For the real packaged experience, build/run the Desktop Shell. It bundles `apps/animation-studio/app/dist` into Electron resources.

## Creator signing

End users do not configure `OCP_SIGNING_KEY_HEX`, `KEY_ID`, or `PUBLISHER_ID` manually.

The intended flow is:

1. Sign in with the user's OCP Account.
2. Reuse the existing Creator publisher identity, or create one once.
3. Electron creates a local Ed25519 signing identity for that PC.
4. The private seed is protected by Electron `safeStorage` / Windows DPAPI.
5. Only the public key is registered with Creator Cloud.
6. Packages are signed locally before private Cloud upload.

Private signing material never needs to be sent to Supabase, R2, Creator Portal, Operations, or browser JavaScript.

## Quality gates

Before release, run:

```powershell
cd D:\ocp-platform\apps\animation-studio\app
npm test
npm run lint
npm run build
```

Also run the Desktop Shell typecheck/tests/build whenever the Electron Studio bridge or packaged resource integration changes.

