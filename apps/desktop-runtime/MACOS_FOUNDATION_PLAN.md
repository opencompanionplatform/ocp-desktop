# macOS Foundation Plan

## Supported target

Start with:

```text
Apple Silicon: aarch64-apple-darwin
```

Add Intel/universal support after the Apple Silicon POC:

```text
Intel: x86_64-apple-darwin
Universal: arm64 + x86_64
```

## Native library

Windows currently loads:

```text
ocp_desktop_runtime_ext.dll
```

macOS must load:

```text
libocp_desktop_runtime_ext.dylib
```

Update `ocp_runtime.gdextension` with platform-specific library entries rather
than replacing the Windows path.

## Platform abstraction

Create:

```text
RuntimePlatformService
├── WindowsRuntimePlatformService
└── MacOSRuntimePlatformService
```

Responsibilities:

```text
System tray / menu bar
Click-through and input regions
Always-on-top behavior
Window focus behavior
Single instance
Notifications
Startup registration
Monitor and DPI information
Application data directories
Exit and restore behavior
```

Controllers must call `RuntimePlatformService`; they should not call Windows
APIs directly.

## macOS application packaging

Required later:

```text
OCP Desktop Runtime.app
Info.plist
application icon
entitlements
code signing
notarization
DMG or PKG distribution
```

## macOS POC acceptance checklist

- [ ] Godot project launches
- [ ] GDExtension loads
- [ ] Transparent window
- [ ] Always on top
- [ ] Companion drag
- [ ] Mouse passthrough
- [ ] Menu bar item
- [ ] Hide/restore
- [ ] Single instance
- [ ] Bible package
- [ ] Meowsom package
- [ ] CS-RT conformance
- [ ] Position persistence
- [ ] Multi-monitor basic movement
- [ ] Apple Silicon debug build
