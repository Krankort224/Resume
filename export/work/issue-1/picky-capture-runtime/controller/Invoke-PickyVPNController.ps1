[CmdletBinding()]
param(
    [ValidateSet('status', 'health', 'connect', 'disconnect')][string]$Action = 'status',
    [string]$RequestPath = '',
    [string]$ResponsePath = '',
    [string]$RuntimeRoot = '',
    [string]$EngineRoot = '',
    [string]$PublicMetadataPath = '',
    [string]$CredentialPath = '',
    [ValidateSet('lan', 'external')][string]$Delivery = 'lan',
    [ValidatePattern('^[a-z0-9-]+$')][string]$Profile = 'primary',
    [string]$Endpoint = '192.168.1.160',
    [bool]$KillSwitchEnabled = $false,
    [ValidateSet('Soft', 'Strict')][string]$KillSwitchMode = 'Soft',
    [bool]$DeferHealth = $false,
    [switch]$Apply
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'PickyVPN.Controller.psm1') -Force

if (-not [string]::IsNullOrWhiteSpace($RequestPath)) {
    $request = Get-Content -LiteralPath $RequestPath -Raw | ConvertFrom-Json
    $allowed = @('action', 'profile', 'delivery', 'endpoint', 'kill_switch_enabled', 'kill_switch_mode', 'defer_health')
    foreach ($property in $request.PSObject.Properties.Name) {
        if ($allowed -notcontains $property) { throw 'Controller request contains an unsupported field.' }
    }
    if ($request.PSObject.Properties['action']) { $Action = [string]$request.action }
    if ($request.PSObject.Properties['profile']) { $Profile = [string]$request.profile }
    if ($request.PSObject.Properties['delivery']) { $Delivery = [string]$request.delivery }
    if ($request.PSObject.Properties['endpoint']) { $Endpoint = [string]$request.endpoint }
    if ($request.PSObject.Properties['kill_switch_enabled']) { $KillSwitchEnabled = [bool]$request.kill_switch_enabled }
    if ($request.PSObject.Properties['kill_switch_mode']) { $KillSwitchMode = [string]$request.kill_switch_mode }
    if ($request.PSObject.Properties['defer_health']) { $DeferHealth = [bool]$request.defer_health }
}

$result = Invoke-PickyVPNControllerOperation -Action $Action -RuntimeRoot $RuntimeRoot -EngineRoot $EngineRoot -PublicMetadataPath $PublicMetadataPath -CredentialPath $CredentialPath -Delivery $Delivery -Profile $Profile -Endpoint $Endpoint -KillSwitchEnabled:$KillSwitchEnabled -KillSwitchMode $KillSwitchMode -DeferHealth:$DeferHealth -Apply:$Apply
$json = $result | ConvertTo-Json -Depth 4 -Compress
if ([string]::IsNullOrWhiteSpace($ResponsePath)) {
    Write-Output $json
}
else {
    $responseFullPath = [System.IO.Path]::GetFullPath($ResponsePath)
    $responseDirectory = [System.IO.Path]::GetDirectoryName($responseFullPath)
    if ([string]::IsNullOrWhiteSpace($responseDirectory) -or -not (Test-Path -LiteralPath $responseDirectory -PathType Container)) {
        throw 'Controller response directory does not exist.'
    }
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($responseFullPath, $json, $utf8NoBom)
}
