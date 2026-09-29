# Build the hello-companion example plugin to wasm (PLUGIN_ABI v1).
# ASCII-only (Windows PowerShell 5.1 BOM-less UTF-8 parsing).
$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot
rustup target add wasm32-wasip1 | Out-Null
cargo build -p hello-companion --target wasm32-wasip1 --release --manifest-path hello-companion/Cargo.toml
$wasm = "hello-companion/target/wasm32-wasip1/release/hello_companion.wasm"
if (Test-Path $wasm) {
    Write-Host "Built: $wasm"
} else {
    Write-Host "Build produced no wasm at $wasm"
    exit 1
}
