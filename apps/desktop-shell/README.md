# OCP Desktop Shell

Opaque Electron application-window foundation for OCP. The transparent desktop
companion remains in `apps/desktop-runtime`; this module does not own Physics or
canonical companion state.

## Development

Use Node.js 22.12 or newer for Electron's supported package-install toolchain.

```powershell
npm install
npm run dev
```

Open an allowlisted view in a new or existing single instance:

```powershell
npx electron . --ocp-open=characters --ocp-source=command-line
```

Supported views are `home`, `characters`, `chat`, and `settings`. Runtime/hover-
menu integration is intentionally not connected in G16.4A.

## Verification

```powershell
npm run typecheck
npm run lint
npm test
npm run build
npm audit
```

Manual Windows checks: launch, second-instance routing, maximize/restore,
minimize/restore, all resize edges/corners, high-DPI monitor placement, locale and
theme switching, reduced-motion mode, character-switch effect, and WebGL context
loss fallback.
