[CmdletBinding()]
param([switch]$Apply)

$ErrorActionPreference = 'Stop'
$programRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$controller = Join-Path $PSScriptRoot 'PickyVPN.Controller.exe'
if (-not (Test-Path -LiteralPath $controller -PathType Leaf)) { throw 'PickyVPN.Controller.exe is not present in the bundle controller directory.' }

if (-not $Apply) {
    Write-Output 'DRY RUN: would remove only the stable PickyVPN D.4 WFP provider/sublayer/filter identities, stop an owned primary sing-box runtime if present, and verify ordinary cleanup.'
    Write-Output "Run with -Apply to execute: $PSCommandPath"
    exit 0
}

$isAdministrator = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$arguments = @('--recover', "--program-root=$programRoot")
if ($isAdministrator) {
    & $controller @arguments
    if ($LASTEXITCODE -ne 0) { throw 'PickyVPN network-lock recovery failed.' }
} else {
    $argumentLine = ($arguments | ForEach-Object { '"' + $_.Replace('"', '\"') + '"' }) -join ' '
    $process = Start-Process -FilePath $controller -ArgumentList $argumentLine -Verb RunAs -WindowStyle Hidden -Wait -PassThru
    if ($process.ExitCode -ne 0) { throw 'PickyVPN network-lock recovery failed.' }
}
Write-Output 'PASS: exact Picky-owned WFP policy and owned runtime recovery completed.'
