[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$RecoveryScript,
    [Parameter(Mandatory)][string]$CancelPath,
    [Parameter(Mandatory)][string]$LogPath,
    [ValidateRange(30, 3600)][int]$DelaySeconds = 300
)

$ErrorActionPreference = 'Stop'
Start-Sleep -Seconds $DelaySeconds
if (Test-Path -LiteralPath $CancelPath) { exit 0 }
try {
    & $RecoveryScript -Apply *> $LogPath
    if ($LASTEXITCODE -ne 0) { throw 'Recovery helper returned a failure exit code.' }
} catch {
    $message = "WATCHDOG_RECOVERY_FAILED: $($_.Exception.Message)"
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($LogPath, $message, $utf8NoBom)
    exit 1
}
