# OCP Update Core

Implements the first delivery gate of ADR-0024: signed `ocp-update/1`
metadata, target selection, staged download, and artifact verification.

It deliberately does **not** replace a running installation. Windows/macOS
replacement and rollback belong to later platform-adapter gates.

## POC commands

Sign an unsigned manifest without exposing the private key as an argument:

```powershell
$env:OCP_UPDATE_SIGNING_KEY_B64 = '<base64 32-byte Ed25519 seed>'
cargo run -p ocp-release-core --bin ocp-release-manifest -- `
  sign release/update-manifest.unsigned.json release/update-manifest.json
Remove-Item Env:OCP_UPDATE_SIGNING_KEY_B64
```

Check and stage an update:

```powershell
cargo run -p ocp-release-core --bin ocp-release-check -- check `
  --manifest-url https://github.com/opencompanionplatform/ocp-releases/releases/latest/download/update-manifest.json `
  --current-version 0.1.0 `
  --platform windows `
  --arch arm64 `
  --key-id ocp-update-dev-1 `
  --public-key-base64 '<base64 Ed25519 public key>' `
  --staging-dir "$env:LOCALAPPDATA\OCP\updates"
```
