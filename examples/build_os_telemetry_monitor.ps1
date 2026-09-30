# Build the os-telemetry-monitor example plugin to wasm (PLUGIN_ABI v1,
# PLUGIN_API §7a). ASCII-only (Windows PowerShell 5.1 BOM-less UTF-8 parsing).
$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot
rustup target add wasm32-wasip1 | Out-Null
cargo build -p os-telemetry-monitor --target wasm32-wasip1 --release --manifest-path os-telemetry-monitor/Cargo.toml
$wasm = "os-telemetry-monitor/target/wasm32-wasip1/release/os_telemetry_monitor.wasm"
if (Test-Path $wasm) {
    Write-Host "Built: $wasm"
} else {
    Write-Host "Build produced no wasm at $wasm"
    exit 1
}
