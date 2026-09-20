[CmdletBinding()]
param(
    [string]$ConfigPath = '',
    [string]$RuntimeDirectory = '',
    [switch]$RequireMaterializedConfig,
    [switch]$LiveReadiness,
    [ValidateSet('lan', 'external')][string]$NetworkMode = 'lan',
    [string]$ExpectedEndpoint = '192.168.1.160',
    [bool]$KillSwitchEnabled = $true
)

$ErrorActionPreference = 'Stop'
$expectedTun = 'PickyVPN-VLESS-v0'

function Write-Result([string]$Level, [string]$Message) { Write-Host "[$Level] $Message" }
function Require([bool]$Condition, [string]$Message) { if (-not $Condition) { throw $Message }; Write-Result PASS $Message }
function Test-AddressInPrefix([string]$Address, [string]$Network, [int]$PrefixLength) {
    try {
        $addressBytes = [System.Net.IPAddress]::Parse(($Address -split '%')[0]).GetAddressBytes()
        $networkBytes = [System.Net.IPAddress]::Parse($Network).GetAddressBytes()
    } catch { return $false }
    if ($addressBytes.Length -ne $networkBytes.Length) { return $false }
    $wholeBytes = [Math]::Floor($PrefixLength / 8)
    $remainingBits = $PrefixLength % 8
    for ($index = 0; $index -lt $wholeBytes; $index++) { if ($addressBytes[$index] -ne $networkBytes[$index]) { return $false } }
    if ($remainingBits -eq 0) { return $true }
    $mask = [byte](0xFF -shl (8 - $remainingBits))
    return (($addressBytes[$wholeBytes] -band $mask) -eq ($networkBytes[$wholeBytes] -band $mask))
}
if ($env:OS -ne 'Windows_NT') { throw 'This preflight must run on the Windows client target.' }
try { $expectedEndpointAddress = [System.Net.IPAddress]::Parse($ExpectedEndpoint) } catch { throw 'Expected VLESS endpoint must be a resolved IPv4 address.' }
if ($expectedEndpointAddress.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork) { throw 'Expected VLESS endpoint must be IPv4.' }
if ($NetworkMode -eq 'lan' -and $ExpectedEndpoint -ne '192.168.1.160') { throw 'LAN readiness must use the accepted VLESS v0 LAN IPv4.' }
if ($NetworkMode -eq 'external' -and $ExpectedEndpoint -eq '192.168.1.160') { throw 'External readiness must not use the LAN endpoint.' }
if ([string]::IsNullOrWhiteSpace($ConfigPath)) { $ConfigPath = Join-Path $PSScriptRoot '..\config.example.json' }
$resolvedConfig = (Resolve-Path -LiteralPath $ConfigPath).Path
$content = Get-Content -LiteralPath $resolvedConfig -Raw
try { $config = $content | ConvertFrom-Json } catch { throw "Config is not JSON: $($_.Exception.Message)" }
Write-Result INFO "Windows version: $([System.Environment]::OSVersion.VersionString); 64-bit OS: $([Environment]::Is64BitOperatingSystem)"
Write-Result INFO "Elevated: $(([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator))"

if ($content -match '__PICKYVPN_') {
    if ($RequireMaterializedConfig) { throw 'Config still contains template placeholders.' }
    Write-Result INFO 'Template placeholders detected as expected; do not use this file for a live start.'
}
Require ($config.route.auto_detect_interface -eq $true) 'Loop prevention requires route.auto_detect_interface=true.'
Require ($config.inbounds[0].strict_route -eq $KillSwitchEnabled) "TUN strict_route matches the selected Kill switch state ($KillSwitchEnabled)."
Require (@($config.inbounds[0].route_exclude_address).Count -eq 1) 'TUN requires exactly one endpoint route exclusion.'
Require ($config.outbounds[0].packet_encoding -eq 'xudp') 'VLESS outbound must explicitly use XUDP.'
Require (-not $config.outbounds[0].PSObject.Properties['network']) 'VLESS network is unrestricted so TCP and UDP remain enabled.'
Require ($config.dns.servers[0].server -eq '1.1.1.1' -and $config.dns.servers[0].server_port -eq 443 -and $config.dns.servers[0].path -eq '/dns-query') 'DNS uses approved Cloudflare DoH IPv4 endpoint.'
Require ($config.dns.servers[0].tls.server_name -eq 'cloudflare-dns.com' -and $config.dns.servers[0].detour -eq 'vless-out' -and $config.dns.strategy -eq 'ipv4_only') 'DNS is IPv4-only and detoured through VLESS.'
Require (@($config.inbounds[0].address) -contains 'fdfe:dcba:9876::1/126') 'TUN has the dedicated IPv6 capture address.'
Require ((@($config.inbounds[0].route_address) -join '|') -eq '0.0.0.0/1|128.0.0.0/1|::/1|8000::/1') 'TUN captures IPv4 and IPv6 default ranges.'
$ipv6Rule = @($config.route.rules | Where-Object { $_.ip_version -eq 6 -and $_.action -eq 'reject' -and $_.method -eq 'default' })
Require ($ipv6Rule.Count -eq 1) 'IPv6 is fail-closed in TUN; no global DIRECT IPv6 bypass is allowed.'

if ($RequireMaterializedConfig) {
    try { $endpoint = [System.Net.IPAddress]::Parse([string]$config.outbounds[0].server) } catch { throw 'VLESS server must be a resolved IPv4 address, not a hostname.' }
    Require ($endpoint.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork -and $endpoint.IPAddressToString -eq $ExpectedEndpoint) 'VLESS endpoint matches the selected delivery IPv4.'
    Require ($config.outbounds[0].server_port -eq 443 -and $config.outbounds[0].flow -eq 'xtls-rprx-vision') 'VLESS port and Vision flow match the frozen v0 contract.'
    Require ($config.outbounds[0].tls.server_name -eq 'dl.google.com' -and $config.outbounds[0].tls.reality.enabled -eq $true) 'REALITY SNI and enablement match the frozen v0 contract.'
    Require ($config.inbounds[0].route_exclude_address[0] -eq "$ExpectedEndpoint/32") 'TUN exclusion exactly matches the VLESS endpoint.'
}
if ($RuntimeDirectory) {
    $binary = (Resolve-Path -LiteralPath (Join-Path (Resolve-Path -LiteralPath $RuntimeDirectory).Path 'sing-box.exe') -ErrorAction Stop).Path
    $versionText = (& $binary version 2>&1 | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or $versionText -notmatch '(?m)^sing-box version 1\.13\.19\b') { throw 'Expected pinned sing-box 1.13.19 runtime.' }
    Write-Result PASS 'Pinned sing-box 1.13.19 runtime is present.'
}
if ($LiveReadiness) {
    $routeSnapshot = @(Get-NetRoute -ErrorAction Stop)
    $defaultV4 = @($routeSnapshot | Where-Object { $_.DestinationPrefix -eq '0.0.0.0/0' -and $_.State -ne 'Unreachable' } | Sort-Object RouteMetric | Select-Object -First 1)
    if (-not $defaultV4) { throw 'No physical/default IPv4 route is available.' }
    $localV4 = Get-NetIPAddress -AddressFamily IPv4 -InterfaceIndex $defaultV4.InterfaceIndex -ErrorAction Stop | Where-Object { $_.IPAddress -notmatch '^169\.254\.' } | Select-Object -First 1
    if (-not $localV4) { throw 'No usable local IPv4 address is present on the physical default interface.' }
    if ($NetworkMode -eq 'lan' -and $localV4.IPAddress -notmatch '^192\.168\.1\.') { throw 'Windows client is not on the required 192.168.1.0/24 LAN.' }
    Write-Result INFO "Physical/default IPv4 interface: $($defaultV4.InterfaceAlias) (index $($defaultV4.InterfaceIndex)); local IPv4: $($localV4.IPAddress)/$($localV4.PrefixLength)"
    if (Get-Process -Name 'sing-box' -ErrorAction SilentlyContinue) { throw 'An existing sing-box process is running.' }
    if (Get-NetAdapter -Name $expectedTun -ErrorAction SilentlyContinue) { throw "Expected TUN adapter $expectedTun already exists." }
    if ($routeSnapshot | Where-Object { $_.InterfaceAlias -eq $expectedTun }) { throw "Existing routes reference $expectedTun." }
    $tunPrefixes = @(
        [pscustomobject]@{ Network = '172.19.0.0'; PrefixLength = 30; AddressFamily = 'IPv4' },
        [pscustomobject]@{ Network = 'fdfe:dcba:9876::'; PrefixLength = 126; AddressFamily = 'IPv6' }
    )
    $addressCollisions = @()
    foreach ($prefix in $tunPrefixes) {
        $existingAddresses = Get-NetIPAddress -AddressFamily $prefix.AddressFamily -ErrorAction Stop
        $addressCollisions += @($existingAddresses | Where-Object { Test-AddressInPrefix -Address $_.IPAddress -Network $prefix.Network -PrefixLength $prefix.PrefixLength })
    }
    $routeCollisions = @()
    foreach ($route in $routeSnapshot) {
        $parts = $route.DestinationPrefix -split '/'
        if ($parts.Count -ne 2) { continue }
        foreach ($prefix in $tunPrefixes) {
            $routeAddress = $parts[0]
            $routePrefixLength = [int]$parts[1]
            $routeFamily = if ($routeAddress -match ':') { 'IPv6' } else { 'IPv4' }
            if ($routeFamily -eq $prefix.AddressFamily -and $routePrefixLength -ge $prefix.PrefixLength -and (Test-AddressInPrefix -Address $routeAddress -Network $prefix.Network -PrefixLength $prefix.PrefixLength)) { $routeCollisions += $route }
        }
    }
    if ($addressCollisions.Count -gt 0 -or $routeCollisions.Count -gt 0) {
        $addressDetails = @($addressCollisions | ForEach-Object { "$($_.IPAddress)/$($_.PrefixLength) on $($_.InterfaceAlias)" }) -join '; '
        $routeDetails = @($routeCollisions | ForEach-Object { "$($_.DestinationPrefix) via $($_.NextHop) on $($_.InterfaceAlias)" }) -join '; '
        throw "Intended PickyVPN TUN address/route collision detected. Addresses: $addressDetails. Routes: $routeDetails. Do not mutate networking; choose a reviewed non-conflicting TUN range."
    }
    Write-Result INFO 'No existing address or equal/more-specific route conflicts with the intended PickyVPN TUN prefixes.'
    Write-Result INFO 'Foreign VPN presence is not a preflight gate; Windows effective routes remain authoritative and Picky preserves only its endpoint exclusion.'
    Write-Result PASS "Physical IPv4 default route and $NetworkMode client address are ready."
}
Write-Result PASS 'VLESS v0 preflight completed without changing Windows networking.'
