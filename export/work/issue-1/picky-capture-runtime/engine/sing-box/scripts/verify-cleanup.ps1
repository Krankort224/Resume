[CmdletBinding()]
param(
    [ValidatePattern('^[a-z0-9-]+$')][string]$Profile = 'primary',
    [string]$RuntimeRoot = '',
    [ValidateSet('lan', 'external')][string]$Delivery = 'lan',
    [int]$OwnedProcessId = 0,
    [string]$OwnedBinaryPath = '',
    [switch]$AllowOwnedState,
    [ValidateRange(1, 10)][int]$CleanupTimeoutSeconds = 5
)

$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($RuntimeRoot)) { $RuntimeRoot = Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)) 'PickyVPN\app\runtime' }
$tunName = 'PickyVPN-VLESS-v0'
$statePath = ''
if (Test-Path -LiteralPath $RuntimeRoot -PathType Container) {
    $RuntimeRoot = (Resolve-Path -LiteralPath $RuntimeRoot -ErrorAction Stop).Path
    $stateDirectory = Join-Path $RuntimeRoot 'state'
    $statePath = Join-Path $stateDirectory 'active.json'
}
if ($env:OS -ne 'Windows_NT') { throw 'Run this script on the Windows client target.' }
if (-not $AllowOwnedState -and -not [string]::IsNullOrWhiteSpace($statePath) -and (Test-Path -LiteralPath $statePath)) { throw 'An owned active-state file still exists; cleanup is incomplete.' }
if ($OwnedProcessId -gt 0) {
    $ownedProcess = Get-Process -Id $OwnedProcessId -ErrorAction SilentlyContinue
    if ($ownedProcess) {
        $matchesOwnedBinary = $false
        if (-not [string]::IsNullOrWhiteSpace($OwnedBinaryPath)) {
            try { $matchesOwnedBinary = ((Resolve-Path -LiteralPath $ownedProcess.Path -ErrorAction Stop).Path -eq (Resolve-Path -LiteralPath $OwnedBinaryPath -ErrorAction Stop).Path) } catch { }
        }
        if ($ownedProcess.ProcessName -eq 'sing-box' -and $matchesOwnedBinary) { throw "Owned sing-box PID $OwnedProcessId is still running." }
        throw "Owned PID $OwnedProcessId was reused before cleanup verification; recovery requires explicit ownership reconciliation."
    }
}

$deadline = [DateTime]::UtcNow.AddSeconds($CleanupTimeoutSeconds)
do {
    $adapter = Get-NetAdapter -Name $tunName -ErrorAction SilentlyContinue
    $routeSnapshot = @(Get-NetRoute -ErrorAction Stop)
    $tunRoutes = @($routeSnapshot | Where-Object { $_.InterfaceAlias -eq $tunName })
    if ($null -eq $adapter -and $tunRoutes.Count -eq 0) {
        break
    }
    if ([DateTime]::UtcNow -ge $deadline) {
        $remaining = @()
        if ($adapter) { $remaining += 'adapter' }
        if ($tunRoutes.Count -gt 0) { $remaining += 'routes' }
        throw "Picky-owned cleanup timed out waiting for $($remaining -join ' and ') to disappear."
    }
    Start-Sleep -Milliseconds 50
} while ($true)
Write-Host 'PASS: the exact owned process, Picky TUN adapter, and all Picky TUN routes are absent.'
Write-Host 'This verifies Picky-owned cleanup only. Perform independent DIRECT DNS/HTTPS verification separately.'
