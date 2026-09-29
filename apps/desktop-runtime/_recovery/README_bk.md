# OCP Desktop Runtime (Godot reference implementation)

Status: **skeleton, unbuilt** (2026-07-19). Implements RUNTIME_API against ADR-0003 (Godot) / ADR-0005 (IPC transport). See `ocp-architecture/04-architecture/RUNTIME.md` → "Implementation notes (I2)" for the architecture split (Rust GDExtension = contract/security boundary, GDScript = presentation only).

```
apps/desktop-runtime/
  rust/            GDExtension crate (ocp-desktop-runtime-ext) — IPC + sanitization + signals
  godot/           Godot project — scenes, GDScript, .gdextension manifest
  build.ps1        Compiles the extension and stages the .dll where Godot expects it (Windows)
  build.sh         Same, for Linux/macOS (unverified — see status table)
  run_cs_rt.ps1    Automated CS-RT conformance run, headless (Windows, PROVEN green)
  run_cs_rt.sh     Same, for Linux/macOS (unverified — see status table)
```

## 1. Install Godot

Download the **Godot 4.7.1** (or newer 4.x) standard editor — not .NET/Mono, this project doesn't use C#:

- https://godotengine.org/download/windows/

Windows 11 ARM64 (Snapdragon) ships a native ARM64 editor build as of Godot 4.x; pick the arm64 zip if offered, otherwise the x86_64 build runs fine under Windows' built-in emulation. Unzip it anywhere (e.g. `C:\Godot\Godot_v4.7.1-stable_win64.exe`, or the arm64-named exe) — no installer, it's a single portable executable.

## 2. Install the Rust → GDExtension toolchain

You already have `rustup`/`cargo` from I1 (Windows ARM64, `aarch64-pc-windows-msvc`). Add the target if you haven't:

```powershell
rustup target add aarch64-pc-windows-msvc
```

**Open risk, unverified on this machine:** `gdext` (the Rust/Godot bindings) has a bindgen step that may or may not build cleanly for `aarch64-pc-windows-msvc` — ARM64 Windows GDExtension support is new enough that we couldn't confirm it in advance (see RUNTIME.md implementation notes). Try the native path first:

```powershell
cd D:\ocp-platform\apps\desktop-runtime
powershell -ExecutionPolicy Bypass -File build.ps1 -Arch arm64
```

**If that fails** (bindgen/libclang errors are the likely symptom), fall back to cross-compiling for x86_64 and running the x86_64 Godot editor under emulation:

```powershell
rustup target add x86_64-pc-windows-msvc
powershell -ExecutionPolicy Bypass -File build.ps1 -Arch x86_64
```
Then use the `x86_64` Godot editor download instead of the arm64 one, and change the `.gdextension` platform key Godot actually loads if needed (Godot picks the entry matching its own architecture automatically — using the x86_64 editor will pick `windows.debug.x86_64` on its own).

Paste whatever error you get from either path back and it'll get fixed the same way the wasmtime-wasi module path got fixed in I1 — this is genuinely a first-build-will-need-one-iteration situation, same as everything else in this repo so far.

## 3. Open the project in Godot

1. Launch the Godot editor executable.
2. "Import" → browse to `apps/desktop-runtime/godot/project.godot` → Import & Edit.
3. Godot will report a missing/failed GDExtension if `build.ps1` hasn't run yet for the platform it's on — run step 2 first.
4. Press **F5** (run project). You should see a small window with an empty label — that's `BubbleLabel`, waiting for events.

## 4. Wire it to the walking-skeleton kernel

`services/kernel` (`ocp-kernel`) is the minimal Native Core Service: it binds the socket, authenticates peers (SEC-040), and lets you drive RUNTIME_API verbs from stdin. Full run order:

```powershell
# Terminal 1 — start the kernel; it prints the session token to use:
cd D:\ocp-platform
cargo run -p ocp-kernel
```

```powershell
# Terminal 2 — set the env vars the kernel printed, THEN launch the editor
# from this same terminal (the bridge reads them at scene start):
$env:OCP_IPC_SOCKET = "ocp-runtime"
$env:OCP_IPC_TOKEN  = "<token printed by the kernel>"
C:\Godot_v4.7.1-stable_windows_arm64\Godot_v4.7.1-stable_windows_arm64.exe --path D:\ocp-platform\apps\desktop-runtime\godot -e
```

Press **F5**. Within ~2 s (reconnect backoff) the kernel prints "runtime subscribed" and sends a greeting bubble — the label should show **"OCP walking skeleton online"**. Then, in the kernel terminal: any typed line → bubble; `/speech <text>`; `/emotion <name>`; `/window <transparent|opaque> <ontop|normal> <never|outside-sprite|always>`; `/quit`. Outcome facts (`ocp.runtime.bubble-shown`, `ocp.runtime.window-state-changed`, …) stream back into the kernel console with their `correlationId` (NFR-004) — for `/window`, check the `degraded` array in the reply against what you actually see happen to the window.

**Click in the running game window** (2026-07-20, unverified): the kernel now routes every inbound fact through a live `DeterministicEngine` (I3 Behavior Engine, `demo_rules()`). A click produces `ocp.runtime.input-captured`, which a rule matches to a **fixed, canned** reaction — bubble "I noticed that!" + a `wave` animation request + emotion → happy — printed as `[kernel] [behavior-engine] -> ...` and pushed back to the runtime. This is not an echo of anything you typed: the Behavior Engine never calls an LLM and has no templating (RFC-0001) — it's real rule arbitration choosing a pre-authored response, which is the actual point being demonstrated.

**Window policy status (2026-07-20, unbuilt/unverified):** applying transparency/always-on-top/click-through moved into the Rust bridge (`apply_window_policy`, not GDScript) since truthfully reporting `degraded` is a contract obligation (RUNTIME_API §3.1). Written against Godot 4's documented `DisplayServer` window-flag API; not yet confirmed against the real gdext binding, so expect a possible first-build fix-up. Separately, even if it compiles and `degraded` comes back empty, Godot 4 has a known engine bug where per-pixel transparency renders solid black on some version/renderer/resolution combinations (godotengine/godot#99903) — if you see black instead of transparent, try disabling "Embed Game" in the editor's run settings first.

Connection routing: the bridge declares an `intent` in the SEC-040 handshake (`subscribe` = kernel→runtime push channel, `publish` = one-shot outcome delivery) — see `packages/ipc` (`Hello.intent`, added I2, lockstep per TD-010). Token via env var is still skeleton-level; real provisioning is a follow-up (see `TODO` in `rust/src/lib.rs`).

## 5. What's proven vs. not yet

| | Status |
|---|---|
| CS-RT passes the headless stub (`packages/runtime-stub`) | done, automated (I2 slice 2) |
| CS-RT passes the Godot bridge | **done, automated, GREEN on Windows 2026-07-20** — `run_cs_rt.ps1` drives `cs_rt_live` against a headless Godot instance; all 5 steps `ok` |
| NFR-001 swap test (both runtimes pass identically) | **Proven** — stub and Godot bridge both pass the identical script |
| Window policy (transparent/always-on-top/click-through) | **Proven on Windows** (with Godot's "Embed Game" disabled — see step 4). macOS/Linux untested, no hardware |
| Cross-platform (Linux/macOS) build + CS-RT scripts | `build.sh` / `run_cs_rt.sh` written 2026-07-20, **unverified — nobody has run them yet** |
| CI runs the Godot CS-RT automatically | Not yet — needs a headless Godot binary installed on the GitHub runner (exact release asset URL not yet confirmed, so not wired in blind) |

## สรุปภาษาไทย

โครงร่าง Godot reference runtime: `rust/` คือ GDExtension ถือ logic ด้านความปลอดภัย/contract ทั้งหมด (IPC, SEC-040, sanitize ข้อความ §5) ส่ง signal ให้ `godot/` ซึ่งมีหน้าที่แสดงผลอย่างเดียว — ติดตั้ง Godot 4.7.1 (arm64 หรือ x86_64 รันผ่าน emulation), เพิ่ม rust target, รัน `build.ps1` แล้วเปิดโปรเจกต์ใน editor กด F5 — **จุดเสี่ยงที่ยังไม่ยืนยัน**: gdext build บน Windows ARM64 อาจมีปัญหา bindgen ถ้าเจอ error ให้ fallback ไป x86_64 cross-compile + รัน editor x86_64 ผ่าน emulation — ยังไม่ได้ต่อกับ kernel จริง (ต้องตั้ง env var เองชั่วคราว) และ CS-RT ยังไม่ได้รันอัตโนมัติกับ Godot (แค่ stub เท่านั้น) — งานเหล่านี้ยังค้างอยู่ตามตาราง
