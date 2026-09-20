[CmdletBinding()]
param(
    [ValidatePattern('^[a-z0-9-]+$')][string]$Profile = 'primary',
    [string]$RuntimeRoot = '',
    [string]$EngineRoot = '',
    [ValidateSet('lan', 'external')][string]$Delivery = 'lan',
    [string]$Endpoint = '192.168.1.160',
    [bool]$KillSwitchEnabled = $true,
    [string]$CredentialPath = '',
    [string]$PublicMetadataPath = '',
    [switch]$Apply
)

$ErrorActionPreference = 'Stop'
if ($Profile -ne 'primary') { throw 'VLESS v0 accepts only the primary profile.' }
if ([string]::IsNullOrWhiteSpace($RuntimeRoot)) { $RuntimeRoot = Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)) 'PickyVPN\app\runtime' }
$RuntimeRoot = [System.IO.Path]::GetFullPath($RuntimeRoot)
New-Item -ItemType Directory -Force -Path $RuntimeRoot | Out-Null
$RuntimeRoot = (Resolve-Path -LiteralPath $RuntimeRoot -ErrorAction Stop).Path
if ([string]::IsNullOrWhiteSpace($EngineRoot)) { $EngineRoot = Join-Path $PSScriptRoot '..' }
$EngineRoot = (Resolve-Path -LiteralPath $EngineRoot -ErrorAction Stop).Path
$materialize = Join-Path $PSScriptRoot 'materialize-profile.ps1'
$preflight = Join-Path $PSScriptRoot 'preflight.ps1'
$verifyCleanup = Join-Path $PSScriptRoot 'verify-cleanup.ps1'
$runtimeDirectory = (Resolve-Path -LiteralPath (Join-Path $EngineRoot 'runtime') -ErrorAction Stop).Path
$binary = (Resolve-Path -LiteralPath (Join-Path $runtimeDirectory 'sing-box.exe') -ErrorAction Stop).Path
$configDirectory = $RuntimeRoot
$configPath = Join-Path $configDirectory 'config.json'
$stateDirectory = Join-Path $RuntimeRoot 'state'
$statePath = Join-Path $stateDirectory 'active.json'
$pendingStatePath = Join-Path $stateDirectory 'active.pending.json'
$logPath = Join-Path $configDirectory 'logs\sing-box.log'
function Wait-PickyVPNTunReady([System.Diagnostics.Process]$StartedProcess) {
    $deadline = [DateTime]::UtcNow.AddSeconds(15)
    while ([DateTime]::UtcNow -lt $deadline) {
        if ($StartedProcess.HasExited) { throw "sing-box exited during startup with code $($StartedProcess.ExitCode)." }
        $adapter = Get-NetAdapter -Name 'PickyVPN-VLESS-v0' -ErrorAction SilentlyContinue
        if ($null -ne $adapter -and $adapter.Status -eq 'Up') { return }
        Start-Sleep -Milliseconds 50
    }
    throw 'PickyVPN TUN adapter did not become ready within 15 seconds.'
}

function Stop-JustStartedProcess([System.Diagnostics.Process]$StartedProcess, [string]$ExpectedBinary) {
    try {
        $candidate = Get-Process -Id $StartedProcess.Id -ErrorAction SilentlyContinue
        if ($null -eq $candidate) { return }
        $candidateBinary = (Resolve-Path -LiteralPath $candidate.Path -ErrorAction Stop).Path
        if ($candidate.ProcessName -ne 'sing-box' -or $candidateBinary -ne $ExpectedBinary -or $candidate.StartTime -ne $StartedProcess.StartTime) {
            throw 'Refusing transactional cleanup because the just-started PID no longer identifies the expected sing-box process.'
        }
        Stop-Process -Id $candidate.Id -ErrorAction Stop
        [void]$candidate.WaitForExit(15000)
        if (-not $candidate.HasExited) { throw 'Just-started sing-box process did not exit within 15 seconds.' }
    } catch { throw "Transactional cleanup could not stop only the just-started PickyVPN process: $($_.Exception.Message)" }
}

if ((Test-Path -LiteralPath $statePath) -or (Test-Path -LiteralPath $pendingStatePath)) { throw "Refusing start: an owned active or pending state file already exists under $stateDirectory" }
& $materialize -Profile $Profile -RuntimeRoot $RuntimeRoot -PublicMetadataPath $PublicMetadataPath -Delivery $Delivery -Endpoint $Endpoint -KillSwitchEnabled:$KillSwitchEnabled -CredentialPath $CredentialPath
$configPath = (Resolve-Path -LiteralPath $configPath -ErrorAction Stop).Path
& $preflight -ConfigPath $configPath -RuntimeDirectory $runtimeDirectory -RequireMaterializedConfig -LiveReadiness -NetworkMode $Delivery -ExpectedEndpoint $Endpoint -KillSwitchEnabled:$KillSwitchEnabled
& $binary check -c $configPath
if ($LASTEXITCODE -ne 0) { throw "sing-box check failed with exit code $LASTEXITCODE." }
if (-not $Apply) {
    Write-Host 'Dry run passed: materialization, runtime logging path, config validation, and read-only live readiness checks passed. No TUN, route, DNS, adapter, or WFP state was changed.'
    Write-Host 'Live start requires the reviewed explicit elevated operator command documented in the sing-box engine README.'
    exit 0
}
$identity = [Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $identity.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Live TUN start requires an elevated PowerShell session.' }
New-Item -ItemType Directory -Force -Path $stateDirectory | Out-Null
$process = $null
try {
    $process = Start-Process -FilePath $binary -ArgumentList @('run', '-c', $configPath) -WorkingDirectory $runtimeDirectory -WindowStyle Hidden -PassThru
    Wait-PickyVPNTunReady -StartedProcess $process
    $state = [ordered]@{
        format = 'pickyvpn-sing-box-vless-v0-state-1'
        profile = $Profile
        delivery = $Delivery
        process_id = $process.Id
        binary_path = $binary
        config_path = $configPath
        log_path = $logPath
        tun_name = 'PickyVPN-VLESS-v0'
        started_utc = [DateTime]::UtcNow.ToString('o')
    }
    [System.IO.File]::WriteAllText($pendingStatePath, ($state | ConvertTo-Json), [System.Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $pendingStatePath -Destination $statePath -ErrorAction Stop
    if (-not (Test-Path -LiteralPath $statePath)) { throw 'Owned active state was not committed after launch.' }
} catch {
    $startupError = $_
    if ($process) {
        try { Stop-JustStartedProcess -StartedProcess $process -ExpectedBinary $binary } catch { $cleanupError = $_.Exception.Message }
    }
    Remove-Item -LiteralPath $pendingStatePath, $statePath -Force -ErrorAction SilentlyContinue
    try { & $verifyCleanup -Profile $Profile -RuntimeRoot $RuntimeRoot -Delivery $Delivery -OwnedProcessId $(if ($process) { $process.Id } else { 0 }) -OwnedBinaryPath $binary } catch { if (-not $cleanupError) { $cleanupError = $_.Exception.Message } }
    if ($cleanupError) { throw "Live startup failed and PickyVPN rollback verification also failed: $($startupError.Exception.Message) Cleanup: $cleanupError" }
    throw "Live startup failed; the just-started PickyVPN process was stopped and owned partial state was removed: $($startupError.Exception.Message)"
}
Write-Host "PASS: started owned sing-box PID $($process.Id) for profile $Profile. Runtime authentication/error log: $logPath"
Write-Host 'This proves only local process/TUN startup; do not claim end-to-end data-plane PASS.'
