[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [switch]$Register,
    [switch]$Check,
    [switch]$Unregister,
    [string]$DesktopShellRoot = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$modeCount = @($Register, $Check, $Unregister | Where-Object { $_ }).Count
if ($modeCount -ne 1) {
    throw 'Specify exactly one action: -Register, -Check, or -Unregister.'
}

$root = Split-Path -Parent $MyInvocation.MyCommand.Path
if ([string]::IsNullOrWhiteSpace($DesktopShellRoot)) {
    $DesktopShellRoot = Join-Path $root 'apps\desktop-shell'
}
$DesktopShellRoot = [System.IO.Path]::GetFullPath($DesktopShellRoot)
$electronDist = Join-Path $DesktopShellRoot 'node_modules\electron\dist'
$electronExe = Join-Path $electronDist 'OCP-Desktop-Dev.exe'
if (-not (Test-Path -LiteralPath $electronExe -PathType Leaf)) {
    $electronExe = Join-Path $electronDist 'electron.exe'
}
$iconPath = Join-Path $root 'apps\desktop-runtime\godot\assets\icons\ocp.ico'
$schemeKey = 'HKCU:\Software\Classes\ocp'
$commandKey = Join-Path $schemeKey 'shell\open\command'
$applicationKey = Join-Path $schemeKey 'Application'
$defaultIconKey = Join-Path $schemeKey 'DefaultIcon'
$expectedCommand = '"{0}" "{1}" "%1"' -f $electronExe, $DesktopShellRoot

if (-not ('OcpDevProtocolNative' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;

public static class OcpDevProtocolNative
{
    [DllImport("shlwapi.dll", CharSet = CharSet.Unicode)]
    public static extern uint AssocQueryString(
        uint flags,
        uint str,
        string assoc,
        string extra,
        StringBuilder output,
        ref uint outputLength);

    [DllImport("shell32.dll")]
    public static extern void SHChangeNotify(
        uint eventId,
        uint flags,
        IntPtr item1,
        IntPtr item2);
}
'@
}

function Get-OcpProtocolFriendlyName {
    $capacity = [uint32]1024
    $buffer = [System.Text.StringBuilder]::new([int]$capacity)
    # ASSOCF_IS_PROTOCOL = 0x1000, ASSOCSTR_FRIENDLYAPPNAME = 4
    $result = [OcpDevProtocolNative]::AssocQueryString(
        [uint32]0x1000,
        [uint32]4,
        'ocp',
        $null,
        $buffer,
        [ref]$capacity
    )
    return [pscustomobject]@{
        Result = $result
        Name = if ($result -eq 0) { $buffer.ToString() } else { '' }
    }
}

function Get-OcpProtocolCommand {
    if (-not (Test-Path -LiteralPath $commandKey)) {
        return ''
    }
    return [string](Get-Item -LiteralPath $commandKey).GetValue('')
}

function Assert-OcpProtocolRegistration {
    $command = Get-OcpProtocolCommand
    $friendly = Get-OcpProtocolFriendlyName
    if ($command -ne $expectedCommand) {
        throw "ocp:// command registration mismatch. Expected: $expectedCommand ; Actual: $command"
    }
    if ($friendly.Result -ne 0 -or $friendly.Name -ne 'OCP Desktop') {
        throw ('Windows association query cannot resolve ocp:// to OCP Desktop (HRESULT 0x{0:X8}, name="{1}").' -f $friendly.Result, $friendly.Name)
    }
    Write-Host 'PASS: Windows resolves ocp:// to OCP Desktop for Chromium external-protocol dispatch.' -ForegroundColor Green
    Write-Host ("Command: {0}" -f $command)
}

if ($Check) {
    Assert-OcpProtocolRegistration
    return
}

if ($Register) {
    if (-not (Test-Path -LiteralPath $electronExe -PathType Leaf)) {
        throw "Electron executable not found: $electronExe. Run npm install in apps\desktop-shell first."
    }
    if (-not (Test-Path -LiteralPath $DesktopShellRoot -PathType Container)) {
        throw "Desktop Shell root not found: $DesktopShellRoot"
    }

    if ($PSCmdlet.ShouldProcess($schemeKey, 'Register explicit OCP Desktop development URL protocol')) {
        New-Item -Path $schemeKey -Force | Out-Null
        Set-Item -Path $schemeKey -Value 'URL:OCP Desktop Store Link'
        New-ItemProperty -Path $schemeKey -Name 'URL Protocol' -Value '' -PropertyType String -Force | Out-Null

        New-Item -Path $applicationKey -Force | Out-Null
        New-ItemProperty -Path $applicationKey -Name 'ApplicationName' -Value 'OCP Desktop' -PropertyType String -Force | Out-Null
        New-ItemProperty -Path $applicationKey -Name 'ApplicationDescription' -Value 'Open Companion Platform Desktop' -PropertyType String -Force | Out-Null
        New-ItemProperty -Path $applicationKey -Name 'ApplicationCompany' -Value 'Open Companion Platform' -PropertyType String -Force | Out-Null
        if (Test-Path -LiteralPath $iconPath -PathType Leaf) {
            New-ItemProperty -Path $applicationKey -Name 'ApplicationIcon' -Value $iconPath -PropertyType String -Force | Out-Null
            New-Item -Path $defaultIconKey -Force | Out-Null
            Set-Item -Path $defaultIconKey -Value $iconPath
        }

        New-Item -Path $commandKey -Force | Out-Null
        Set-Item -Path $commandKey -Value $expectedCommand

        # SHCNE_ASSOCCHANGED = 0x08000000, SHCNF_IDLIST = 0x0000.
        # Notify Explorer/Chromium that protocol association metadata changed.
        [OcpDevProtocolNative]::SHChangeNotify([uint32]0x08000000, [uint32]0, [IntPtr]::Zero, [IntPtr]::Zero)
    }

    Assert-OcpProtocolRegistration
    return
}

if ($Unregister) {
    $currentCommand = Get-OcpProtocolCommand
    if ([string]::IsNullOrWhiteSpace($currentCommand)) {
        Write-Host 'INFO: no user-scoped ocp:// development registration exists.' -ForegroundColor Cyan
        return
    }
    if ($currentCommand -ne $expectedCommand) {
        throw 'Refusing to remove ocp:// because the current handler is not this development Desktop Shell.'
    }
    if ($PSCmdlet.ShouldProcess($schemeKey, 'Remove OCP Desktop development URL protocol')) {
        Remove-Item -LiteralPath $schemeKey -Recurse -Force
        [OcpDevProtocolNative]::SHChangeNotify([uint32]0x08000000, [uint32]0, [IntPtr]::Zero, [IntPtr]::Zero)
    }
    Write-Host 'PASS: removed user-scoped OCP Desktop development protocol registration.' -ForegroundColor Green
}
