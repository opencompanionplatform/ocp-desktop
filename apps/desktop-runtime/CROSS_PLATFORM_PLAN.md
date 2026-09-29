# OCP Desktop Runtime Cross-platform Plan

## Shared core

Portable without OS-specific changes:

- RuntimeApp and RuntimeContext
- Event Bus and State Machine
- Character/Animation/Bubble controllers
- OCP package reader, validator and installer
- AI and Memory service boundaries
- most monitor geometry logic
- Runtime SDK contracts

## Platform adapters

```text
PlatformService
├── Windows
│   ├── tray
│   ├── native click-through
│   ├── startup
│   └── ARM64/x86_64 DLL
├── Linux
│   ├── X11/XWayland tray
│   ├── compositor-aware transparency
│   ├── .so GDExtension
│   └── AppImage/deb/rpm packaging
└── macOS
    ├── menu bar/status item
    ├── accessibility/input behavior
    ├── .dylib universal binary
    └── signing/notarization
```

## Rust targets

Typical initial targets:

```text
Windows ARM64: aarch64-pc-windows-msvc
Windows x64:   x86_64-pc-windows-msvc
Linux x64:     x86_64-unknown-linux-gnu
Linux ARM64:   aarch64-unknown-linux-gnu
macOS Intel:   x86_64-apple-darwin
macOS ARM64:   aarch64-apple-darwin
```

## Recommended Linux scope

Start with X11/XWayland because desktop-companion window behavior is more
predictable. Validate native Wayland after the single-window overlay is stable.

## Recommended macOS scope

Start on Apple Silicon, then create a universal application by combining
arm64 and x86_64 native libraries. Add signing and notarization before public
distribution.
