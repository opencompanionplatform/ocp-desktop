# Contributing to OCP Desktop

Thank you for contributing to Open Companion Platform Desktop.

## Public contribution flow

The public `opencompanionplatform/ocp-desktop` repository accepts Desktop/client contributions. Pull requests are reviewed and tested publicly. Accepted changes are then imported into the private OCP integration monorepo, run through integration/security gates, and exported back to the public Desktop repository.

This prevents the public mirror from bypassing integration controls while keeping Desktop source reviewable and forkable.

## Scope

Public contributions should target Desktop/client code such as:

- Desktop Runtime and character behavior
- Desktop Shell
- Animation Studio bundled with Desktop
- Kernel and Launcher
- Native companion window
- package/runtime libraries and SDK contracts
- release/build/test tooling for Desktop

Hosted Store/Creator/Operations backend implementation is maintained separately and is not part of this repository.

## Before submitting

- Keep changes focused and reviewable.
- Add or update tests for behavior changes.
- Do not commit credentials, private keys, `.env` files, generated `node_modules`, build output, user-specific paths, or personal identifiers.
- Do not weaken package signature, update signature, credential broker, IPC, or release-signing validation to make a test pass.
- Keep official/private signing material out of the repository.

## Developer Certificate of Origin

OCP uses DCO sign-off for contributions. Sign commits with:

```text
Signed-off-by: Your Name <your-email@example.com>
```

Use `git commit -s` to add the sign-off automatically.

## Security issues

Do not open a public issue for a suspected vulnerability. Follow `SECURITY.md`.

## Contact

Project contact: `opencompanionplatform@gmail.com`.
