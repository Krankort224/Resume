[CmdletBinding()]
param(
    [ValidatePattern('^[a-z0-9-]+$')][string]$Profile = 'primary',
    [string]$RuntimeRoot = '',
    [ValidateSet('lan', 'external')][string]$Delivery = 'lan',
    [switch]$Apply
)

$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($RuntimeRoot)) { $RuntimeRoot = Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)) 'PickyVPN\app\runtime' }
$RuntimeRoot = (Resolve-Path -LiteralPath $RuntimeRoot -ErrorAction Stop).Path
$stateDirectory = Join-Path $RuntimeRoot 'state'
$statePath = Join-Path $stateDirectory 'active.json'
$lastSessionPath = Join-Path $stateDirectory 'last-session.json'
$verifyCleanup = Join-Path $PSScriptRoot 'verify-cleanup.ps1'
if ($Profile -ne 'primary') { throw 'VLESS v0 accepts only the primary profile.' }
if (-not (Test-Path -LiteralPath $statePath)) { throw "No owned active-state file exists: $statePath" }
try { $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json } catch { throw 'Owned active-state file is not valid JSON.' }
if ($state.format -ne 'pickyvpn-sing-box-vless-v0-state-1' -or $state.profile -ne $Profile -or -not $state.process_id -or -not $state.binary_path) { throw 'Owned active-state file is incomplete or not recognized.' }
if ($state.PSObject.Properties['delivery'] -and $state.delivery -ne $Delivery) { throw 'Owned active-state delivery does not match the requested stop target.' }
$ownedBinary = (Resolve-Path -LiteralPath $state.binary_path -ErrorAction Stop).Path
$state.binary_path = $ownedBinary
$process = Get-Process -Id ([int]$state.process_id) -ErrorAction SilentlyContinue
$alreadyStopped = $null -eq $process
if (-not $alreadyStopped) {
    $processBinary = (Resolve-Path -LiteralPath $process.Path -ErrorAction Stop).Path
    if ($process.ProcessName -ne 'sing-box' -or $processBinary -ne $ownedBinary) { throw 'Refusing to stop a process that does not exactly match PickyVPN owned state.' }
}
if (-not $Apply) {
    if ($alreadyStopped) { Write-Host "Dry run: owned sing-box PID $($state.process_id) has already exited; -Apply would archive owned state and require cleanup verification." }
    else { Write-Host "Dry run: would stop only owned sing-box PID $($state.process_id) for profile $Profile, then require cleanup verification." }
    exit 0
}
$identity = [Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $identity.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Stopping the elevated TUN process requires an elevated PowerShell session.' }
if (-not $alreadyStopped) {
    Stop-Process -Id ([int]$state.process_id) -ErrorAction Stop
    $processExited = $process.WaitForExit(15000)
    if (-not $processExited -or -not $process.HasExited) { throw 'OWNED_PROCESS_EXIT_TIMEOUT: owned sing-box process did not exit within 15 seconds; active state was retained for recovery.' }
}
try { & $verifyCleanup -Profile $Profile -RuntimeRoot $RuntimeRoot -Delivery $Delivery -OwnedProcessId ([int]$state.process_id) -OwnedBinaryPath $ownedBinary -AllowOwnedState } catch { throw "OWNED_CLEANUP_VERIFICATION_FAILED: $($_.Exception.Message)" }
try {
    $state | Add-Member -NotePropertyName stopped_utc -NotePropertyValue ([DateTime]::UtcNow.ToString('o')) -Force
    $state | Add-Member -NotePropertyName stop_outcome -NotePropertyValue $(if ($alreadyStopped) { 'already-exited' } else { 'stopped-by-pickyvpn' }) -Force
    [System.IO.File]::WriteAllText($lastSessionPath, ($state | ConvertTo-Json), [System.Text.UTF8Encoding]::new($false))
    Remove-Item -LiteralPath $statePath -Force -ErrorAction Stop
} catch { throw "OWNED_CLEANUP_STATE_FINALIZATION_FAILED: $($_.Exception.Message)" }
if ($alreadyStopped) { Write-Host "PASS: owned sing-box PID $($state.process_id) was already stopped; stale owned state was archived and cleanup verification passed." }
else { Write-Host "PASS: stopped owned sing-box PID $($state.process_id) and cleanup verification passed." }
