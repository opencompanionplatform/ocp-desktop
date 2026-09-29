# Windows and macOS Runtime Architecture

```text
RuntimeApp
├── RuntimeContext
├── RuntimeEventBus
├── RuntimeStateMachine
├── Services
├── Controllers
├── UI
└── RuntimePlatformService
    ├── WindowsRuntimePlatformService
    └── MacOSRuntimePlatformService
```

## Shared

The following remain platform neutral:

```text
CharacterService
PackageService
RegistryService
SettingsService
AIService
MemoryService
CharacterController
AnimationController
BubbleController
HoverController
ContextMenuController
QuickPanelController
RuntimeEventBus
RuntimeStateMachine
Runtime SDK
OCP package format
```

## Platform-dependent

```text
WindowController implementation
ClickThrough implementation
Tray/menu bar implementation
Single Instance implementation
Native notifications
Startup registration
Monitor/DPI adapters
GDExtension binary path
Build/export scripts
Signing and packaging
```

## Build matrix

```text
Windows ARM64
  Rust: aarch64-pc-windows-msvc
  Native library: .dll
  Runner: PowerShell

Windows x64
  Rust: x86_64-pc-windows-msvc
  Native library: .dll
  Runner: PowerShell

macOS Apple Silicon
  Rust: aarch64-apple-darwin
  Native library: .dylib
  Runner: shell/zsh

macOS Intel
  Rust: x86_64-apple-darwin
  Native library: .dylib
  Runner: shell/zsh
```
