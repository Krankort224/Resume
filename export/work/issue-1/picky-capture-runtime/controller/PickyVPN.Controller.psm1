Set-StrictMode -Version Latest
# Windows PowerShell 5.1 does not automatically load System.Security, even
# though the app's CurrentUser-DPAPI credential is valid. Load it before the
# read-only Credential provider evaluates the local source.
Add-Type -AssemblyName System.Security -ErrorAction Stop
$script:PickyVPNEngineRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\engine\sing-box') -ErrorAction Stop).Path
$script:PickyVPNEngineScripts = Join-Path $script:PickyVPNEngineRoot 'scripts'

function Get-PickyVPNProcessExecutablePath {
    [CmdletBinding()]
    param([Parameter(Mandatory)][int]$ProcessId)

    if ($null -eq ('PickyVPNProcessQuery' -as [type])) {
        Add-Type @'
using System;
using System.Text;
using System.Runtime.InteropServices;
public static class PickyVPNProcessQuery {
    [DllImport("kernel32.dll", SetLastError=true)]
    public static extern IntPtr OpenProcess(uint access, bool inherit, int processId);
    [DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
    public static extern bool QueryFullProcessImageName(IntPtr process, uint flags, StringBuilder path, ref int size);
    [DllImport("kernel32.dll", SetLastError=true)]
    public static extern bool CloseHandle(IntPtr handle);
}
'@
    }
    $handle = [PickyVPNProcessQuery]::OpenProcess(0x1000, $false, $ProcessId)
    if ($handle -eq [IntPtr]::Zero) { throw 'Owned process path is unavailable.' }
    try {
        $buffer = [Text.StringBuilder]::new(32768)
        $length = $buffer.Capacity
        if (-not [PickyVPNProcessQuery]::QueryFullProcessImageName($handle, 0, $buffer, [ref]$length)) {
            throw 'Owned process path is unavailable.'
        }
        $path = $buffer.ToString()
        if ([string]::IsNullOrWhiteSpace($path)) { throw 'Owned process path is unavailable.' }
        return $path
    } finally {
        [void][PickyVPNProcessQuery]::CloseHandle($handle)
    }
}

function New-PickyVPNControllerEvidence {
    [CmdletBinding()]
    param(
        [bool]$Configured,
        [bool]$OwnedRuntimePresent,
        [bool]$OwnedRuntimeValid,
        [bool]$HealthPassed,
        [string]$HealthCode = 'DATA_PLANE_HEALTH_PENDING',
        [string]$FailureCode = ''
    )

    [pscustomobject][ordered]@{
        Configured = $Configured
        OwnedRuntimePresent = $OwnedRuntimePresent
        OwnedRuntimeValid = $OwnedRuntimeValid
        HealthPassed = $HealthPassed
        HealthCode = $HealthCode
        FailureCode = $FailureCode
    }
}

function Resolve-PickyVPNControllerState {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Evidence)

    if (-not [string]::IsNullOrWhiteSpace([string]$Evidence.FailureCode)) {
        return [pscustomobject][ordered]@{ State = 'Error'; Code = [string]$Evidence.FailureCode }
    }
    if (-not $Evidence.Configured) {
        return [pscustomobject][ordered]@{ State = 'Unconfigured'; Code = 'PROFILE_UNCONFIGURED' }
    }
    if ($Evidence.OwnedRuntimePresent -and -not $Evidence.OwnedRuntimeValid) {
        return [pscustomobject][ordered]@{ State = 'Error'; Code = 'OWNERSHIP_MISMATCH' }
    }
    if ($Evidence.OwnedRuntimePresent -and $Evidence.HealthPassed) {
        return [pscustomobject][ordered]@{ State = 'Connected'; Code = 'HEALTH_QUORUM_PASSED' }
    }
    if ($Evidence.OwnedRuntimePresent) {
        $healthCode = if ([string]::IsNullOrWhiteSpace([string]$Evidence.HealthCode)) { 'DATA_PLANE_HEALTH_PENDING' } else { [string]$Evidence.HealthCode }
        return [pscustomobject][ordered]@{ State = 'Degraded'; Code = $healthCode }
    }
    return [pscustomobject][ordered]@{ State = 'Ready'; Code = 'READY' }
}

function Test-PickyVPNDataPlaneHealth {
    [CmdletBinding()]
    param()

    try {
        $answers = Resolve-DnsName -Name 'www.cloudflare.com' -Type A -DnsOnly -ErrorAction Stop
        if (-not @($answers | Where-Object { $_.IPAddress }).Count) {
            return [pscustomobject]@{ Passed = $false; Code = 'HEALTH_DNS_FAILED' }
        }
    } catch {
        return [pscustomobject]@{ Passed = $false; Code = 'HEALTH_DNS_FAILED' }
    }

    try {
        $response = Invoke-WebRequest -Uri 'https://www.cloudflare.com/cdn-cgi/trace' -UseBasicParsing -TimeoutSec 15 -Headers @{ 'Cache-Control' = 'no-cache' } -ErrorAction Stop
        if ($response.StatusCode -ne 200) {
            return [pscustomobject]@{ Passed = $false; Code = 'HEALTH_HTTPS_FAILED' }
        }
        return [pscustomobject]@{ Passed = $true; Code = 'HEALTH_QUORUM_PASSED' }
    } catch {
        return [pscustomobject]@{ Passed = $false; Code = 'HEALTH_HTTPS_FAILED' }
    }
}

function Test-PickyVPNFocusedEgressProbe {
    [CmdletBinding()]
    param()

    try {
        $response = Invoke-WebRequest -Uri 'https://www.cloudflare.com/cdn-cgi/trace' -UseBasicParsing -TimeoutSec 15 -Headers @{ 'Cache-Control' = 'no-cache' } -ErrorAction Stop
        if ($response.StatusCode -ne 200) {
            return [pscustomobject]@{ Passed = $false; Code = 'ACCEPTANCE_HTTPS_FAILED' }
        }
        if ($response.Content -notmatch '(?m)^loc=KZ\r?$') {
            return [pscustomobject]@{ Passed = $false; Code = 'ACCEPTANCE_EGRESS_MISMATCH' }
        }
        return [pscustomobject]@{ Passed = $true; Code = 'ACCEPTANCE_EGRESS_PASSED' }
    } catch {
        return [pscustomobject]@{ Passed = $false; Code = 'ACCEPTANCE_HTTPS_FAILED' }
    }
}

function Get-PickyVPNRuntimeLayout {
    [CmdletBinding()]
    param(
        [string]$RuntimeRoot,
        [string]$PublicMetadataPath = '',
        [string]$CredentialPath = '',
        [ValidateSet('lan', 'external')][string]$Delivery = 'lan',
        [ValidatePattern('^[a-z0-9-]+$')][string]$Profile = 'primary'
    )

    if ([string]::IsNullOrWhiteSpace($RuntimeRoot)) {
        $RuntimeRoot = Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)) 'PickyVPN\app\runtime'
    }
    if ([string]::IsNullOrWhiteSpace($PublicMetadataPath)) {
        $PublicMetadataPath = Join-Path $script:PickyVPNEngineRoot 'public-vless-metadata.json'
    }
    if ([string]::IsNullOrWhiteSpace($CredentialPath)) {
        $CredentialPath = Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)) 'PickyVPN\app\credential.bin'
    }
    $configRoot = $RuntimeRoot
    $stateRoot = Join-Path $RuntimeRoot 'state'
    [pscustomobject][ordered]@{
        RuntimeRoot = $RuntimeRoot
        PublicMetadataPath = $PublicMetadataPath
        CredentialPath = $CredentialPath
        StatePath = Join-Path $stateRoot 'active.json'
        ConfigPath = Join-Path $configRoot 'config.json'
    }
}

function New-PickyVPNLocalProvisionedCredentialProvider {
    [CmdletBinding()]
    param()

    [pscustomobject]@{
        Name = 'LocalProvisionedCredentialProvider'
        GetCurrentProfile = {
            param(
                [string]$RuntimeRoot,
                [ValidateSet('lan', 'external')][string]$Delivery,
                [ValidatePattern('^[a-z0-9-]+$')][string]$Profile,
                [string]$PublicMetadataPath = '',
                [string]$CredentialPath = ''
            )

            $layout = Get-PickyVPNRuntimeLayout -RuntimeRoot $RuntimeRoot -PublicMetadataPath $PublicMetadataPath -CredentialPath $CredentialPath -Delivery $Delivery -Profile $Profile
            if ((Test-Path -LiteralPath $layout.PublicMetadataPath) -and $null -ne (Get-PickyVPNStoredCredential -CredentialPath $layout.CredentialPath)) {
                return [pscustomobject][ordered]@{ State = 'ProvisionedProfile'; Code = 'PROFILE_PROVISIONED' }
            }
            return [pscustomobject][ordered]@{ State = 'Unconfigured'; Code = 'PROFILE_UNCONFIGURED' }
        }
    }
}

function Get-PickyVPNStoredCredential {
    [CmdletBinding()]
    param([string]$CredentialPath = (Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)) 'PickyVPN\app\credential.bin'))

    try {
        if (-not (Test-Path -LiteralPath $CredentialPath -PathType Leaf)) { return $null }
        $ciphertext = [System.IO.File]::ReadAllBytes($CredentialPath)
        $plaintext = [System.Security.Cryptography.ProtectedData]::Unprotect($ciphertext, $null, [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
        $credential = [System.Text.Encoding]::UTF8.GetString($plaintext)
        if ($credential -notmatch '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$') { return $null }
        return $credential
    } catch {
        return $null
    }
}

function Get-PickyVPNCredentialProviderResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$CredentialProvider,
        [string]$RuntimeRoot,
        [string]$PublicMetadataPath = '',
        [string]$CredentialPath = '',
        [ValidateSet('lan', 'external')][string]$Delivery,
        [ValidatePattern('^[a-z0-9-]+$')][string]$Profile
    )

    if ($null -eq $CredentialProvider.PSObject.Properties['GetCurrentProfile'] -or $CredentialProvider.GetCurrentProfile -isnot [scriptblock]) {
        throw 'Credential provider does not expose a GetCurrentProfile adapter.'
    }

    $result = & $CredentialProvider.GetCurrentProfile $RuntimeRoot $Delivery $Profile $PublicMetadataPath $CredentialPath
    if ($null -eq $result -or $null -eq $result.PSObject.Properties['State']) {
        throw 'Credential provider returned an invalid profile result.'
    }
    if ($result.State -notin @('ProvisionedProfile', 'Unconfigured')) {
        throw 'Credential provider returned an unsupported profile state.'
    }
    return $result
}

function New-PickyVPNDisconnectedStatus {
    [CmdletBinding()]
    param(
        [ValidateSet('lan', 'external')][string]$Delivery,
        [ValidatePattern('^[a-z0-9-]+$')][string]$Profile
    )

    [pscustomobject][ordered]@{
        schema = 'pickyvpn-controller-status-v1'
        profile = $Profile
        delivery = $Delivery
        state = 'Disconnected'
        code = 'DISCONNECTED'
        observed_utc = [DateTime]::UtcNow.ToString('o')
    }
}

function Get-PickyVPNControllerStatus {
    [CmdletBinding()]
    param(
        [string]$RuntimeRoot = '',
        [string]$PublicMetadataPath = '',
        [string]$CredentialPath = '',
        [ValidateSet('lan', 'external')][string]$Delivery = 'lan',
        [ValidatePattern('^[a-z0-9-]+$')][string]$Profile = 'primary',
        $CredentialProvider = $null,
        [switch]$EvaluateHealth,
        [scriptblock]$HealthProbe = $null
    )

    if ($null -eq $CredentialProvider) {
        $CredentialProvider = New-PickyVPNLocalProvisionedCredentialProvider
    }
    $layout = Get-PickyVPNRuntimeLayout -RuntimeRoot $RuntimeRoot -PublicMetadataPath $PublicMetadataPath -CredentialPath $CredentialPath -Delivery $Delivery -Profile $Profile
    $providerFailureCode = ''
    try {
        $profileResult = Get-PickyVPNCredentialProviderResult -CredentialProvider $CredentialProvider -RuntimeRoot $RuntimeRoot -PublicMetadataPath $PublicMetadataPath -CredentialPath $CredentialPath -Delivery $Delivery -Profile $Profile
        $configured = $profileResult.State -eq 'ProvisionedProfile'
    } catch {
        $configured = $false
        $providerFailureCode = 'CREDENTIAL_PROVIDER_INVALID'
    }
    $runtimePresent = Test-Path -LiteralPath $layout.StatePath
    $runtimeValid = $false
    $healthPassed = $false
    $healthCode = 'DATA_PLANE_HEALTH_PENDING'
    $failureCode = if ($providerFailureCode) { $providerFailureCode } else { '' }

    if ($runtimePresent) {
        try {
            $owned = Get-Content -LiteralPath $layout.StatePath -Raw | ConvertFrom-Json
            if ($owned.format -ne 'pickyvpn-sing-box-vless-v0-state-1' -or $owned.profile -ne $Profile -or -not $owned.process_id -or -not $owned.binary_path) {
                $failureCode = 'OWNERSHIP_MISMATCH'
            } else {
                $process = Get-Process -Id ([int]$owned.process_id) -ErrorAction SilentlyContinue
                if ($null -eq $process) {
                    $failureCode = 'OWNED_RUNTIME_MISSING'
                } else {
                    $observedPath = (Resolve-Path -LiteralPath (Get-PickyVPNProcessExecutablePath -ProcessId ([int]$owned.process_id)) -ErrorAction Stop).Path
                    $expectedPath = (Resolve-Path -LiteralPath $owned.binary_path -ErrorAction Stop).Path
                    if ($process.ProcessName -ne 'sing-box' -or $observedPath -ne $expectedPath) {
                        $failureCode = 'OWNERSHIP_MISMATCH'
                    } else {
                        $runtimeValid = $true
                    }
                }
            }
        } catch {
            $failureCode = 'OWNERSHIP_MISMATCH'
        }
    }

    if ($EvaluateHealth -and $runtimeValid -and -not $failureCode) {
        try {
            $health = if ($null -eq $HealthProbe) { Test-PickyVPNDataPlaneHealth } else { & $HealthProbe }
            if ($null -eq $health -or $null -eq $health.PSObject.Properties['Passed'] -or $null -eq $health.PSObject.Properties['Code']) {
                $healthCode = 'HEALTH_PROBE_INVALID'
            } else {
                $healthPassed = [bool]$health.Passed
                $healthCode = [string]$health.Code
            }
        } catch {
            $healthCode = 'HEALTH_PROBE_FAILED'
        }
    }

    $evidence = New-PickyVPNControllerEvidence -Configured $configured -OwnedRuntimePresent $runtimePresent -OwnedRuntimeValid $runtimeValid -HealthPassed $healthPassed -HealthCode $healthCode -FailureCode $failureCode
    $resolved = Resolve-PickyVPNControllerState -Evidence $evidence
    [pscustomobject][ordered]@{
        schema = 'pickyvpn-controller-status-v1'
        profile = $Profile
        delivery = $Delivery
        state = $resolved.State
        code = $resolved.Code
        observed_utc = [DateTime]::UtcNow.ToString('o')
    }
}

function Invoke-PickyVPNControllerOperation {
    [CmdletBinding()]
    param(
        [ValidateSet('status', 'health', 'connect', 'disconnect')][string]$Action = 'status',
        [string]$RuntimeRoot = '',
        [string]$EngineRoot = '',
        [string]$PublicMetadataPath = '',
        [string]$CredentialPath = '',
        [ValidateSet('lan', 'external')][string]$Delivery = 'lan',
        [ValidatePattern('^[a-z0-9-]+$')][string]$Profile = 'primary',
        [string]$Endpoint = '192.168.1.160',
        [bool]$KillSwitchEnabled = $false,
        [ValidateSet('Soft', 'Strict')][string]$KillSwitchMode = 'Soft',
        [switch]$DeferHealth,
        [switch]$Apply,
        $CredentialProvider = $null,
        [scriptblock]$EngineOperation = $null,
        [scriptblock]$HealthProbe = $null
    )

    if ($Action -eq 'status') {
        return Get-PickyVPNControllerStatus -RuntimeRoot $RuntimeRoot -PublicMetadataPath $PublicMetadataPath -CredentialPath $CredentialPath -Delivery $Delivery -Profile $Profile -CredentialProvider $CredentialProvider -HealthProbe $HealthProbe
    }
    if ($Action -eq 'health') {
        return Get-PickyVPNControllerStatus -RuntimeRoot $RuntimeRoot -PublicMetadataPath $PublicMetadataPath -CredentialPath $CredentialPath -Delivery $Delivery -Profile $Profile -CredentialProvider $CredentialProvider -EvaluateHealth -HealthProbe $HealthProbe
    }
    if (-not $Apply) {
        return [pscustomobject][ordered]@{
            schema = 'pickyvpn-controller-status-v1'; profile = $Profile; delivery = $Delivery
            state = 'Ready'; code = 'APPLY_REQUIRED'; observed_utc = [DateTime]::UtcNow.ToString('o')
        }
    }

    $layout = Get-PickyVPNRuntimeLayout -RuntimeRoot $RuntimeRoot -PublicMetadataPath $PublicMetadataPath -CredentialPath $CredentialPath -Delivery $Delivery -Profile $Profile
    if ($Action -eq 'disconnect' -and -not (Test-Path -LiteralPath $layout.StatePath)) {
        return New-PickyVPNDisconnectedStatus -Delivery $Delivery -Profile $Profile
    }

    try {
        if ($null -eq $EngineOperation) {
            # The accepted engine scripts predate this module and intentionally read optional
            # JSON properties. Do not leak the module's StrictMode into their child scope.
            Set-StrictMode -Off
            if ($Action -eq 'connect') {
                if ([string]::IsNullOrWhiteSpace($EngineRoot)) { $EngineRoot = $script:PickyVPNEngineRoot }
                & (Join-Path $script:PickyVPNEngineScripts 'start-v0.ps1') -Profile $Profile -RuntimeRoot $RuntimeRoot -EngineRoot $EngineRoot -PublicMetadataPath $layout.PublicMetadataPath -Delivery $Delivery -Endpoint $Endpoint -KillSwitchEnabled:$KillSwitchEnabled -CredentialPath $layout.CredentialPath -Apply 6>$null | Out-Null
            } else {
                & (Join-Path $script:PickyVPNEngineScripts 'stop-v0.ps1') -Profile $Profile -RuntimeRoot $RuntimeRoot -Delivery $Delivery -Apply 6>$null | Out-Null
            }
        } else {
            & $EngineOperation $Action $RuntimeRoot $Delivery $Profile $Endpoint
        }
    } catch {
        $failureCode = if ($Action -eq 'disconnect' -and $_.Exception.Message -match '^OWNED_PROCESS_EXIT_TIMEOUT:') { 'OWNED_PROCESS_EXIT_TIMEOUT' }
        elseif ($Action -eq 'disconnect' -and $_.Exception.Message -match '^OWNED_CLEANUP_VERIFICATION_FAILED:') { 'OWNED_CLEANUP_VERIFICATION_FAILED' }
        elseif ($Action -eq 'disconnect' -and $_.Exception.Message -match '^OWNED_CLEANUP_STATE_FINALIZATION_FAILED:') { 'OWNED_CLEANUP_STATE_FINALIZATION_FAILED' }
        else { 'CONTROLLER_OPERATION_FAILED' }
        return [pscustomobject][ordered]@{
            schema = 'pickyvpn-controller-status-v1'; profile = $Profile; delivery = $Delivery
            state = 'Error'; code = $failureCode; observed_utc = [DateTime]::UtcNow.ToString('o')
        }
    }
    if ($Action -eq 'disconnect') {
        if (Test-Path -LiteralPath $layout.StatePath) {
            return [pscustomobject][ordered]@{
                schema = 'pickyvpn-controller-status-v1'; profile = $Profile; delivery = $Delivery
                state = 'Error'; code = 'OWNED_CLEANUP_INCOMPLETE'; observed_utc = [DateTime]::UtcNow.ToString('o')
            }
        }
        return New-PickyVPNDisconnectedStatus -Delivery $Delivery -Profile $Profile
    }
    if ($DeferHealth) {
        return [pscustomobject][ordered]@{
            schema = 'pickyvpn-controller-status-v1'; profile = $Profile; delivery = $Delivery
            state = 'Degraded'; code = 'DATA_PLANE_HEALTH_PENDING'; observed_utc = [DateTime]::UtcNow.ToString('o')
        }
    }
    $status = Get-PickyVPNControllerStatus -RuntimeRoot $RuntimeRoot -PublicMetadataPath $PublicMetadataPath -CredentialPath $CredentialPath -Delivery $Delivery -Profile $Profile -CredentialProvider $CredentialProvider -EvaluateHealth -HealthProbe $HealthProbe
    return $status
}

Export-ModuleMember -Function New-PickyVPNControllerEvidence, Resolve-PickyVPNControllerState, Test-PickyVPNDataPlaneHealth, Test-PickyVPNFocusedEgressProbe, New-PickyVPNLocalProvisionedCredentialProvider, Get-PickyVPNStoredCredential, Get-PickyVPNCredentialProviderResult, New-PickyVPNDisconnectedStatus, Get-PickyVPNControllerStatus, Invoke-PickyVPNControllerOperation
