[CmdletBinding()]
param(
    [ValidatePattern('^[a-z0-9-]+$')][string]$Profile = 'primary',
    [string]$RuntimeRoot = '',
    [ValidateSet('lan', 'external')][string]$Delivery = 'lan',
    [string]$Endpoint = '192.168.1.160',
    [bool]$KillSwitchEnabled = $true,
    [string]$CredentialPath = '',
    [string]$PublicMetadataPath = ''
)

$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($RuntimeRoot)) { $RuntimeRoot = Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)) 'PickyVPN\app\runtime' }
$RuntimeRoot = [System.IO.Path]::GetFullPath($RuntimeRoot)
New-Item -ItemType Directory -Force -Path $RuntimeRoot | Out-Null
$RuntimeRoot = (Resolve-Path -LiteralPath $RuntimeRoot -ErrorAction Stop).Path
$expectedProfile = 'primary'
$template = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\config.example.json')).Path
if ([string]::IsNullOrWhiteSpace($PublicMetadataPath)) { $PublicMetadataPath = Join-Path $PSScriptRoot '..\public-vless-metadata.json' }
$outputDirectory = $RuntimeRoot
$outputPath = Join-Path $outputDirectory 'config.json'
$logDirectory = Join-Path $outputDirectory 'logs'
$logPath = Join-Path $logDirectory 'sing-box.log'

function Assert-ExactProperties($Value, [string[]]$Names) {
    $actual = @($Value.PSObject.Properties.Name | Sort-Object)
    $expected = @($Names | Sort-Object)
    if (($actual -join '|') -ne ($expected -join '|')) { throw 'Client material has missing, unexpected, or ambiguous fields.' }
}
function Assert-NonEmpty([string]$Value, [string]$Name) {
    if ([string]::IsNullOrWhiteSpace($Value) -or $Value -match '__PICKYVPN_') { throw "Client material field $Name is missing or unresolved." }
}

if ($Profile -ne $expectedProfile) { throw 'VLESS v0 accepts only the primary profile.' }
try { $endpointAddress = [System.Net.IPAddress]::Parse($Endpoint) } catch { throw 'VLESS endpoint must be a resolved IPv4 address.' }
if ($endpointAddress.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork) { throw 'VLESS endpoint must be IPv4.' }
if ($Delivery -eq 'lan' -and $Endpoint -ne '192.168.1.160') { throw 'LAN delivery must use the accepted VLESS v0 LAN IPv4.' }
if ($Delivery -eq 'external' -and $Endpoint -eq '192.168.1.160') { throw 'External delivery must not reuse the LAN endpoint.' }
if (-not (Test-Path -LiteralPath $PublicMetadataPath)) { throw 'Public VLESS package metadata is absent.' }
$materialText = Get-Content -LiteralPath $PublicMetadataPath -Raw
try { $material = $materialText | ConvertFrom-Json } catch { throw 'Public VLESS package metadata is not valid JSON.' }
$publicFields = @('schema', 'profile', 'reality_public_key', 'reality_short_id')
$actualFields = @($material.PSObject.Properties.Name | Sort-Object) -join '|'
Assert-ExactProperties $material $publicFields
if ($material.schema -ne 'pickyvpn-public-vless-metadata-v1') { throw 'Public VLESS package metadata schema is not recognized.' }
if ($material.profile -ne $expectedProfile) { throw 'Client material profile does not match the selected primary profile.' }
Assert-NonEmpty ([string]$material.reality_public_key) 'reality_public_key'
Assert-NonEmpty ([string]$material.reality_short_id) 'reality_short_id'
if ([string]$material.reality_short_id -notmatch '^[0-9a-fA-F]{2,16}$') { throw 'Client material REALITY short ID is malformed.' }
if ([string]$material.reality_public_key -notmatch '^[A-Za-z0-9_-]{43,44}$') { throw 'Client material REALITY public key is malformed.' }

$material | Add-Member -NotePropertyName vless_uuid -NotePropertyValue ''

if (-not [string]::IsNullOrWhiteSpace($CredentialPath)) {
    try {
        $credentialCiphertext = [System.IO.File]::ReadAllBytes((Resolve-Path -LiteralPath $CredentialPath -ErrorAction Stop).Path)
        $credentialPlaintext = [System.Security.Cryptography.ProtectedData]::Unprotect($credentialCiphertext, $null, [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
        $credential = [System.Text.Encoding]::UTF8.GetString($credentialPlaintext)
    } catch {
        throw 'Stored Windows credential is unavailable.'
    }
    if ($credential -notmatch '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$') { throw 'Stored Windows credential is malformed.' }
    $material.vless_uuid = $credential
}
if ([string]$material.vless_uuid -notmatch '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$') { throw 'Stored Windows credential is unavailable.' }

$configText = Get-Content -LiteralPath $template -Raw
$configText = $configText.Replace('"strict_route": true', ('"strict_route": ' + $KillSwitchEnabled.ToString().ToLowerInvariant()))
$configText = $configText.Replace(([string][char]34 + '__PICKYVPN_VLESS_PORT__' + [char]34), '443')
$jsonLogPath = '"' + $logPath.Replace('\', '\\').Replace('"', '\"') + '"'
$configText = $configText.Replace(([string][char]34 + '__PICKYVPN_RUNTIME_LOG_PATH__' + [char]34), $jsonLogPath)
$replacements = [ordered]@{
    '__PICKYVPN_VPN_SERVER_IPV4__' = $Endpoint
    '__PICKYVPN_REALITY_SERVER_NAME__' = 'dl.google.com'
    '__PICKYVPN_DNS_RESOLVER_IPV4__' = '1.1.1.1'
    '__PICKYVPN_DNS_RESOLVER_SERVER_NAME__' = 'cloudflare-dns.com'
    '__PICKYVPN_VLESS_UUID__' = [string]$material.vless_uuid
    '__PICKYVPN_REALITY_PUBLIC_KEY__' = [string]$material.reality_public_key
    '__PICKYVPN_REALITY_SHORT_ID__' = [string]$material.reality_short_id
}
foreach ($pair in $replacements.GetEnumerator()) { $configText = $configText.Replace($pair.Key, $pair.Value) }
if ($configText -match '__PICKYVPN_') { throw 'Template materialization left unresolved placeholders.' }
try { $null = $configText | ConvertFrom-Json } catch { throw 'Materialization produced invalid JSON.' }
New-Item -ItemType Directory -Force -Path $outputDirectory, $logDirectory | Out-Null
[System.IO.File]::WriteAllText($outputPath, $configText, [System.Text.UTF8Encoding]::new($false))
Write-Host "PASS: materialized nontracked $Delivery config for profile $Profile at $outputPath with ignored runtime log $logPath. Credential values were not printed."
