[CmdletBinding()]
param(
    [ValidateRange(30, 3600)][int]$DelaySeconds = 300,
    [Parameter(DontShow)][string]$ResponsePath = ''
)

$ErrorActionPreference = 'Stop'
$isAdministrator = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdministrator) {
    $responsePath = Join-Path ([IO.Path]::GetTempPath()) ("pickyvpn-d4-watchdog-response-{0}.json" -f [guid]::NewGuid().Guid)
    $arguments = @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden',
        '-File', ('"' + $PSCommandPath + '"'),
        '-DelaySeconds', [string]$DelaySeconds,
        '-ResponsePath', ('"' + $responsePath + '"')
    )

    try {
        try {
            $elevatedProcess = Start-Process -FilePath 'powershell.exe' -ArgumentList ($arguments -join ' ') -Verb RunAs -WindowStyle Hidden -Wait -PassThru
        }
        catch [System.ComponentModel.Win32Exception] {
            if ($_.Exception.NativeErrorCode -eq 1223) {
                throw 'D.4 recovery watchdog elevation was cancelled at the UAC prompt.'
            }
            throw
        }

        if ($elevatedProcess.ExitCode -ne 0) {
            throw "Elevated D.4 recovery watchdog starter exited with code $($elevatedProcess.ExitCode)."
        }
        if (-not (Test-Path -LiteralPath $responsePath -PathType Leaf)) {
            throw 'Elevated D.4 recovery watchdog starter returned no response.'
        }
        Get-Content -LiteralPath $responsePath -Raw
    }
    finally {
        Remove-Item -LiteralPath $responsePath -Force -ErrorAction SilentlyContinue
    }
    return
}

$watchdogRoot = Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)) 'PickyVPN\app\runtime\watchdog'
New-Item -ItemType Directory -Force -Path $watchdogRoot | Out-Null
$identifier = [guid]::NewGuid().Guid
$cancelPath = Join-Path $watchdogRoot "$identifier.cancel"
$logPath = Join-Path $watchdogRoot "$identifier.log"
$watchdogScript = Join-Path $PSScriptRoot 'Invoke-PickyVPNRecoveryWatchdog.ps1'
$recoveryScript = Join-Path $PSScriptRoot 'Recover-PickyVPNNetworkLock.ps1'

$arguments = @(
    '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden',
    '-File', ('"' + $watchdogScript + '"'),
    '-RecoveryScript', ('"' + $recoveryScript + '"'),
    '-CancelPath', ('"' + $cancelPath + '"'),
    '-LogPath', ('"' + $logPath + '"'),
    '-DelaySeconds', [string]$DelaySeconds
)
$process = Start-Process -FilePath 'powershell.exe' -ArgumentList ($arguments -join ' ') -WindowStyle Hidden -PassThru
$response = [pscustomobject][ordered]@{
    schema = 'pickyvpn-d4-recovery-watchdog-v1'
    watchdog_pid = $process.Id
    delay_seconds = $DelaySeconds
    cancel_path = $cancelPath
    log_path = $logPath
    cancel_command = "New-Item -ItemType File -Force -Path '$cancelPath' | Out-Null"
} | ConvertTo-Json -Compress

if ([string]::IsNullOrWhiteSpace($ResponsePath)) {
    $response
    return
}

$fullResponsePath = [IO.Path]::GetFullPath($ResponsePath)
$temporaryRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
if (-not $fullResponsePath.StartsWith($temporaryRoot, [StringComparison]::OrdinalIgnoreCase) -or
    [IO.Path]::GetFileName($fullResponsePath) -notmatch '^pickyvpn-d4-watchdog-response-[0-9a-f-]+\.json$') {
    throw 'Internal watchdog response path is outside the current-user temporary directory.'
}
[IO.File]::WriteAllText($fullResponsePath, $response, (New-Object System.Text.UTF8Encoding($false)))
