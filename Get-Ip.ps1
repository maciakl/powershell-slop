<#
.SYNOPSIS
    Displays routable (public) IP, local LAN IP, subnet, default gateway and
    primary DNS server, MAC address and interface name for the network
    interface used to reach the internet. When that interface is a VPN, the
    local details come from the physical adapter the VPN runs over, and the
    VPN address and interface are shown separately.

.DESCRIPTION
    Output adapts to where it is going:
      * Console            -> colorized, human readable display
      * Piped / captured   -> PowerShell object (use -AsText for plain text)
      * Redirected to file -> plain text (">", "| Out-File", "| Set-Content",
                              "| Add-Content", or stdout redirected from cmd)
    Use -AsObject to always get a PowerShell object, wherever output goes.

    The -RoutableIP, -LocalIP, -Gateway, -Dns, -MacAddress and -VpnIP
    switches output only the address(es), with no labels, one per line in
    that order. Piped output is
    still an object unless -AsText is used.

    Requires only Windows PowerShell 5.1 as shipped with Windows 11.

.PARAMETER RoutableIP
    Show only the routable (public) IP address.

.PARAMETER LocalIP
    Show only the local LAN IP address.

.PARAMETER Gateway
    Show only the default gateway.

.PARAMETER Dns
    Show only the primary DNS server.

.PARAMETER MacAddress
    Show only the MAC (physical) address of the interface.

.PARAMETER VpnIP
    Show only the VPN IP address. If no VPN is in use, nothing is shown and
    the exit code is 1.

.PARAMETER AsText
    When piped or captured, emit plain text instead of a PowerShell object.

.PARAMETER AsObject
    Always emit a PowerShell object, even when output goes to the console or
    a file. Cannot be combined with -AsText.

.PARAMETER ApiUrl
    URL of a service that returns the caller's public IP address, either as
    plain text or as JSON with an "ip" property. Default: https://api.ipify.org

.PARAMETER TimeoutSec
    Timeout in seconds for the routable IP lookup. Default: 10.

.PARAMETER Version
    Show the script version.

.PARAMETER Help
    Show usage information.

.NOTES
    Version: 1.4.0

.EXAMPLE
    .\Get-Ip.ps1

.EXAMPLE
    .\Get-Ip.ps1 -RoutableIP -AsText | Set-Clipboard

.EXAMPLE
    .\Get-Ip.ps1 | Select-Object LocalIP, DefaultGateway

.EXAMPLE
    .\Get-Ip.ps1 -ApiUrl https://ifconfig.me/ip > ip.txt
#>
[CmdletBinding()]
param(
    [Alias('Routable', 'Public', 'PublicIP', 'External')]
    [switch]$RoutableIP,

    [Alias('Local', 'LAN')]
    [switch]$LocalIP,

    [Alias('GW', 'DefaultGateway')]
    [switch]$Gateway,

    [Alias('DnsServer')]
    [switch]$Dns,

    [Alias('Mac', 'PhysicalAddress')]
    [switch]$MacAddress,

    [Alias('Vpn')]
    [switch]$VpnIP,

    [switch]$AsText,

    [switch]$AsObject,

    [Alias('Url', 'Api')]
    [string]$ApiUrl,

    [ValidateRange(1, 300)]
    [int]$TimeoutSec = 10,

    [switch]$Version,

    [Alias('h')]
    [switch]$Help
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$ScriptVersion = '1.4.0'
$scriptInvocation = $MyInvocation
$defaultApiUrls = @(
    'https://api.ipify.org'
    'https://checkip.amazonaws.com'
    'https://ipv4.icanhazip.com'
)

# Field definitions, in display order. Optional fields are left out of the
# full text/console display when they have no value.
$fields = [ordered]@{
    RoutableIP     = @{ Label = 'Routable IP';     Color = 'Green' }
    LocalIP        = @{ Label = 'Local IP';        Color = 'Cyan' }
    Subnet         = @{ Label = 'Subnet';          Color = 'Yellow' }
    DefaultGateway = @{ Label = 'Default Gateway'; Color = 'Magenta' }
    DnsServer      = @{ Label = 'DNS Server';      Color = 'Magenta' }
    MacAddress     = @{ Label = 'MAC Address';     Color = 'DarkYellow' }
    Interface      = @{ Label = 'Interface';       Color = 'DarkGray' }
    VpnIP          = @{ Label = 'VPN IP';          Color = 'Cyan';     Optional = $true }
    VpnInterface   = @{ Label = 'VPN Interface';   Color = 'DarkGray'; Optional = $true }
}

function Show-Usage {
    $name = Split-Path -Leaf $PSCommandPath
    @"
$name version $ScriptVersion

Usage: $name [-RoutableIP] [-LocalIP] [-Gateway] [-Dns] [-MacAddress]
             [-VpnIP] [-AsText | -AsObject] [-ApiUrl <url>]
             [-TimeoutSec <seconds>] [-Version] [-Help]

Displays IP address information for the network interface used to reach
the internet.

With no switches, shows the routable IP, local LAN IP, subnet, default
gateway, primary DNS server, MAC address and interface name. Value
switches can be combined to show only those values.

If the internet is reached through a VPN, the local details are those of
the physical adapter the VPN runs over, followed by the VPN IP and VPN
interface.

Switches:
  -RoutableIP   Routable (public) IP only.  Aliases: -Routable, -Public
  -LocalIP      Local LAN IP only.          Aliases: -Local, -LAN
  -Gateway      Default gateway only.       Aliases: -GW
  -Dns          Primary DNS server only.    Aliases: -DnsServer
  -MacAddress   MAC address only.           Aliases: -Mac, -PhysicalAddress
  -VpnIP        VPN IP only (exit code 1 if no VPN).  Aliases: -Vpn
  -AsText       Emit plain text instead of an object when piped/captured.
  -AsObject     Always emit a PowerShell object, wherever output goes.
  -ApiUrl       Public IP lookup service URL (plain text or JSON {"ip":..}).
                Default: $($defaultApiUrls[0])
                (falls back to $($defaultApiUrls[1..($defaultApiUrls.Count - 1)] -join ', '))
  -TimeoutSec   Timeout for the public IP lookup. Default: 10
  -Version      Show the script version.
  -Help         Show this help.                Aliases: -h

Output:
  Console            Colorized display.
  Piped / captured   PowerShell object (plain text with -AsText).
  Redirected to file Plain text.
  -AsObject          PowerShell object, always.

  Value switches print the bare address(es) only, one per line.

Examples:
  $name
  $name -RoutableIP
  $name -LocalIP -Gateway
  $name -MacAddress
  $name -VpnIP
  $name | Select-Object LocalIP, DefaultGateway
  $name -RoutableIP -AsText | Set-Clipboard
  $name -AsObject
  $name > ipinfo.txt
  $name -ApiUrl https://ifconfig.me/ip
"@
}

# Works out where our output is going by inspecting how we were invoked.
# Returns 'Console', 'Object' (piped or captured) or 'Text' (file/stdout redirect).
function Get-OutputMode {
    param([System.Management.Automation.InvocationInfo]$Invocation)

    $consoleRedirected = $false
    try {
        $consoleRedirected = ($Host.Name -eq 'ConsoleHost') -and [Console]::IsOutputRedirected
    } catch { }

    $line = $Invocation.Line
    if ([string]::IsNullOrWhiteSpace($line)) {
        # Invoked directly by the host, e.g. powershell.exe -File Get-Ip.ps1
        if ($consoleRedirected) { return 'Text' } else { return 'Console' }
    }

    $fallback = if ($Invocation.PipelinePosition -lt $Invocation.PipelineLength) { 'Object' }
                elseif ($consoleRedirected) { 'Text' }
                else { 'Console' }

    $tokens = $null
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($line, [ref]$tokens, [ref]$parseErrors)
    $offset = $Invocation.OffsetInLine
    $command = $ast.FindAll({
            param($a)
            $a -is [System.Management.Automation.Language.CommandAst] -and
            $a.Extent.StartColumnNumber -eq $offset
        }, $true) | Sort-Object { $_.Extent.Text.Length } | Select-Object -First 1
    if (-not $command) { return $fallback }

    $fileWriters = 'Out-File', 'Set-Content', 'Add-Content', 'Out-Printer'
    $node = $command
    while ($node) {
        if ($node -is [System.Management.Automation.Language.CommandBaseAst]) {
            foreach ($r in $node.Redirections) {
                if ($r -is [System.Management.Automation.Language.FileRedirectionAst] -and
                    ($r.FromStream -eq 'Output' -or $r.FromStream -eq 'All')) {
                    return 'Text'
                }
            }
        }

        $parent = $node.Parent
        if ($null -eq $parent) { break }

        if ($parent -is [System.Management.Automation.Language.PipelineAst]) {
            $elements = $parent.PipelineElements
            $index = $elements.IndexOf($node)
            if ($index -ge 0 -and $index -lt $elements.Count - 1) {
                $next = $elements[$index + 1]
                if ($next -is [System.Management.Automation.Language.CommandAst]) {
                    $nextName = $next.GetCommandName()
                    if ($nextName) {
                        $cmdInfo = Get-Command $nextName -ErrorAction SilentlyContinue | Select-Object -First 1
                        if ($cmdInfo -and $cmdInfo.CommandType -eq 'Alias') { $nextName = $cmdInfo.ResolvedCommandName }
                        if ($fileWriters -contains $nextName) { return 'Text' }
                    }
                }
                return 'Object'
            }
        }
        elseif ($parent -is [System.Management.Automation.Language.CommandAst]) {
            # "& { ... }" or "ForEach-Object { ... }" pass output through; anything
            # else means our output is being used as an argument.
            if ($node -isnot [System.Management.Automation.Language.ScriptBlockExpressionAst]) { return 'Object' }
        }
        elseif ($parent -is [System.Management.Automation.Language.AssignmentStatementAst]) {
            return 'Object'
        }
        elseif ($parent -is [System.Management.Automation.Language.FunctionDefinitionAst]) {
            break
        }
        elseif ($parent -is [System.Management.Automation.Language.CommandExpressionAst] -or
                $parent -is [System.Management.Automation.Language.ParenExpressionAst] -or
                $parent -is [System.Management.Automation.Language.SubExpressionAst] -or
                $parent -is [System.Management.Automation.Language.ArrayExpressionAst] -or
                $parent -is [System.Management.Automation.Language.ScriptBlockExpressionAst] -or
                $parent -is [System.Management.Automation.Language.ScriptBlockAst] -or
                $parent -is [System.Management.Automation.Language.NamedBlockAst] -or
                $parent -is [System.Management.Automation.Language.StatementBlockAst]) {
            # Output passes straight through these.
        }
        elseif ($parent -is [System.Management.Automation.Language.StatementAst]) {
            # if/foreach/while/try/switch: bodies pass through, conditions capture.
            if ($node -isnot [System.Management.Automation.Language.StatementBlockAst]) { return 'Object' }
        }
        else {
            # Member access, operators, casts, etc. all consume our output.
            return 'Object'
        }
        $node = $parent
    }

    if ($consoleRedirected) { return 'Text' }
    return 'Console'
}

function ConvertTo-IpAddress {
    param($Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [psobject] -and $Value.PSObject.Properties['ip']) { $Value = $Value.ip }
    $text = ([string]$Value).Trim()
    $parsed = $null
    if ([System.Net.IPAddress]::TryParse($text, [ref]$parsed)) { return $parsed }
    # Fall back to finding an IPv4 address anywhere in the response.
    $m = [regex]::Match($text, '\b(?:(?:25[0-5]|2[0-4]\d|1?\d?\d)\.){3}(?:25[0-5]|2[0-4]\d|1?\d?\d)\b')
    if ($m.Success) { return [System.Net.IPAddress]::Parse($m.Value) }
    return $null
}

function Get-RoutableIp {
    param([string[]]$Urls, [int]$Timeout)
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    } catch { }

    foreach ($url in $Urls) {
        try {
            Write-Verbose "Querying $url"
            $response = Invoke-RestMethod -Uri $url -UseBasicParsing -TimeoutSec $Timeout -Headers @{ Accept = 'text/plain, application/json' }
            $ip = ConvertTo-IpAddress $response
            if ($ip) { return $ip }
            Write-Warning "No IP address found in response from $url"
        } catch {
            Write-Warning "Routable IP lookup via $url failed: $($_.Exception.Message)"
        }
    }
    return $null
}

# Asks the OS which local address it would use to reach the given host. A UDP
# "connect" only selects a route; no packets are sent.
function Get-SourceAddress {
    param([string]$TargetHost)

    $targets = New-Object System.Collections.Generic.List[System.Net.IPAddress]
    try {
        $addresses = [System.Net.Dns]::GetHostAddresses($TargetHost)
        $addresses | Where-Object { $_.AddressFamily -eq 'InterNetwork' } | ForEach-Object { $targets.Add($_) }
        $addresses | Where-Object { $_.AddressFamily -eq 'InterNetworkV6' } | ForEach-Object { $targets.Add($_) }
    } catch {
        Write-Verbose "Could not resolve $TargetHost : $($_.Exception.Message)"
    }
    # Well-known public address as a fallback when DNS is unavailable.
    $targets.Add([System.Net.IPAddress]::Parse('1.1.1.1'))

    foreach ($target in $targets) {
        $socket = $null
        try {
            $socket = New-Object System.Net.Sockets.Socket($target.AddressFamily, [System.Net.Sockets.SocketType]::Dgram, [System.Net.Sockets.ProtocolType]::Udp)
            $socket.Connect($target, 443)
            $local = $socket.LocalEndPoint.Address
            if ($local -and -not [System.Net.IPAddress]::IsLoopback($local)) {
                Write-Verbose "Route to $target uses local address $local"
                return $local
            }
        } catch {
            Write-Verbose "No route to $target : $($_.Exception.Message)"
        } finally {
            if ($socket) { $socket.Close() }
        }
    }
    return $null
}

function Get-NetworkPrefix {
    param([System.Net.IPAddress]$Address, [System.Net.IPAddress]$Mask)
    $a = $Address.GetAddressBytes()
    $m = $Mask.GetAddressBytes()
    $n = New-Object byte[] $a.Length
    for ($i = 0; $i -lt $a.Length; $i++) { $n[$i] = $a[$i] -band $m[$i] }
    return New-Object System.Net.IPAddress (, $n)
}

# Returns the interface GUIDs of physical (hardware) network adapters, or
# $null if they can't be determined.
function Get-PhysicalAdapterIds {
    try {
        $adapters = @(Get-NetAdapter -Physical -ErrorAction Stop | Where-Object { -not $_.Virtual })
        return @($adapters | ForEach-Object { ([string]$_.InterfaceGuid).ToUpperInvariant() })
    } catch {
        Write-Verbose "Could not list physical adapters: $($_.Exception.Message)"
        return $null
    }
}

function Get-IPv4DefaultGateway {
    param($Nic)
    return $Nic.GetIPProperties().GatewayAddresses |
        Where-Object { $_.Address.AddressFamily -eq 'InterNetwork' -and -not $_.Address.Equals([System.Net.IPAddress]::Any) } |
        Select-Object -First 1
}

# Picks the physical adapter that would carry traffic if the VPN were off:
# the one with an IPv4 address and gateway and the lowest default route metric.
function Get-PrimaryPhysicalAdapter {
    param($Nics, [string[]]$PhysicalIds)

    $candidates = @($Nics | Where-Object {
            $PhysicalIds -contains $_.Id.ToUpperInvariant() -and
            (Get-IPv4DefaultGateway $_) -and
            ($_.GetIPProperties().UnicastAddresses | Where-Object { $_.Address.AddressFamily -eq 'InterNetwork' })
        })
    if ($candidates.Count -le 1) { return $candidates | Select-Object -First 1 }

    $metrics = @{}
    try {
        Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction Stop | ForEach-Object {
            $metric = $_.RouteMetric + $_.InterfaceMetric
            if (-not $metrics.ContainsKey($_.ifIndex) -or $metric -lt $metrics[$_.ifIndex]) { $metrics[$_.ifIndex] = $metric }
        }
    } catch {
        Write-Verbose "Could not read default routes: $($_.Exception.Message)"
    }
    return $candidates | Sort-Object {
        $index = $_.GetIPProperties().GetIPv4Properties().Index
        if ($metrics.ContainsKey($index)) { $metrics[$index] } else { [int]::MaxValue }
    } | Select-Object -First 1
}

function Get-InterfaceName {
    param($Nic)
    if ($Nic.Description -and $Nic.Description -ne $Nic.Name) { return "$($Nic.Name) ($($Nic.Description))" }
    return $Nic.Name
}

function Get-LocalNetworkInfo {
    param([string]$RouteHost)

    $result = [ordered]@{ LocalIP = $null; Subnet = $null; DefaultGateway = $null; DnsServer = $null; MacAddress = $null; Interface = $null; VpnIP = $null; VpnInterface = $null }
    $source = Get-SourceAddress -TargetHost $RouteHost

    $nics = [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces() |
        Where-Object { $_.OperationalStatus -eq 'Up' -and $_.NetworkInterfaceType -ne 'Loopback' }

    $nic = $null
    $unicast = $null
    if ($source) {
        foreach ($candidate in $nics) {
            $match = $candidate.GetIPProperties().UnicastAddresses | Where-Object { $_.Address.Equals($source) } | Select-Object -First 1
            if ($match) { $nic = $candidate; $unicast = $match; break }
        }
    }
    if (-not $nic) {
        # No route found: fall back to the first interface with an IPv4 gateway.
        Write-Verbose 'Falling back to first interface with an IPv4 default gateway'
        $nic = $nics | Where-Object { Get-IPv4DefaultGateway $_ } | Select-Object -First 1
        if ($nic) {
            $unicast = $nic.GetIPProperties().UnicastAddresses | Where-Object { $_.Address.AddressFamily -eq 'InterNetwork' } | Select-Object -First 1
        }
    }
    if (-not $nic -or -not $unicast) { return $result }

    # If the route goes through a virtual adapter (VPN), report the physical
    # adapter underneath instead and keep the VPN details separately.
    $physicalIds = Get-PhysicalAdapterIds
    if ($physicalIds -and $physicalIds -notcontains $nic.Id.ToUpperInvariant()) {
        $physical = Get-PrimaryPhysicalAdapter -Nics $nics -PhysicalIds $physicalIds
        if ($physical) {
            Write-Verbose "Route uses virtual adapter $($nic.Name); reporting physical adapter $($physical.Name)"
            $result.VpnIP = $unicast.Address.ToString()
            $result.VpnInterface = Get-InterfaceName $nic
            $nic = $physical
            $unicast = $nic.GetIPProperties().UnicastAddresses | Where-Object { $_.Address.AddressFamily -eq 'InterNetwork' } | Select-Object -First 1
        }
    }

    $family = $unicast.Address.AddressFamily
    $props = $nic.GetIPProperties()

    $result.LocalIP = $unicast.Address.ToString()
    $macBytes = $nic.GetPhysicalAddress().GetAddressBytes()
    if ($macBytes.Length -gt 0) { $result.MacAddress = ($macBytes | ForEach-Object { $_.ToString('X2') }) -join '-' }
    $result.Interface = Get-InterfaceName $nic

    $prefixLength = $null
    try { $prefixLength = $unicast.PrefixLength } catch { }
    if ($family -eq 'InterNetwork' -and $unicast.IPv4Mask -and -not $unicast.IPv4Mask.Equals([System.Net.IPAddress]::Any)) {
        $network = Get-NetworkPrefix -Address $unicast.Address -Mask $unicast.IPv4Mask
        if ($null -eq $prefixLength) {
            $prefixLength = 0
            foreach ($b in $unicast.IPv4Mask.GetAddressBytes()) { $prefixLength += ([Convert]::ToString($b, 2) -replace '0').Length }
        }
        $result.Subnet = "$network/$prefixLength ($($unicast.IPv4Mask))"
    } elseif ($null -ne $prefixLength) {
        $result.Subnet = "$($unicast.Address)/$prefixLength"
    }

    $gateway = $props.GatewayAddresses |
        Where-Object { $_.Address.AddressFamily -eq $family -and -not $_.Address.Equals([System.Net.IPAddress]::Any) -and -not $_.Address.Equals([System.Net.IPAddress]::IPv6Any) } |
        Select-Object -First 1
    if ($gateway) { $result.DefaultGateway = $gateway.Address.ToString() }

    $dnsServers = @($props.DnsAddresses)
    $dnsServer = $dnsServers | Where-Object { $_.AddressFamily -eq $family } | Select-Object -First 1
    if (-not $dnsServer) { $dnsServer = $dnsServers | Select-Object -First 1 }
    if ($dnsServer) { $result.DnsServer = $dnsServer.ToString() }

    return $result
}

# ---------------------------------------------------------------------------

if ($Help) {
    Show-Usage
    return
}

if ($Version) {
    $ScriptVersion
    return
}

if ($AsText -and $AsObject) {
    Write-Error '-AsText and -AsObject cannot be used together.' -ErrorAction Continue
    exit 2
}

$mode = if ($AsObject) { 'Object' } else { Get-OutputMode -Invocation $scriptInvocation }
if ($mode -eq 'Object' -and $AsText) { $mode = 'Text' }
Write-Verbose "Output mode: $mode"

$selected = @()
if ($RoutableIP) { $selected += 'RoutableIP' }
if ($LocalIP)    { $selected += 'LocalIP' }
if ($Gateway)    { $selected += 'DefaultGateway' }
if ($Dns)        { $selected += 'DnsServer' }
if ($MacAddress) { $selected += 'MacAddress' }
if ($VpnIP)      { $selected += 'VpnIP' }
$showAll = $selected.Count -eq 0
if ($showAll) { $selected = @($fields.Keys) }

$apiUrls = @(if ($ApiUrl) { $ApiUrl } else { $defaultApiUrls })
try {
    $routeHost = ([Uri]$apiUrls[0]).Host
    if (-not $routeHost) { throw 'no host' }
} catch {
    Write-Error "Invalid -ApiUrl '$($apiUrls[0])'. Expected an absolute URL such as https://api.ipify.org" -ErrorAction Continue
    exit 2
}

$info = [ordered]@{}
foreach ($key in $fields.Keys) { $info[$key] = $null }

if ($selected -contains 'RoutableIP') {
    $ip = Get-RoutableIp -Urls $apiUrls -Timeout $TimeoutSec
    if ($ip) { $info.RoutableIP = $ip.ToString() }
}
if ($selected | Where-Object { $_ -ne 'RoutableIP' }) {
    $local = Get-LocalNetworkInfo -RouteHost $routeHost
    foreach ($key in $local.Keys) { $info[$key] = $local[$key] }
}

# In the full display, optional fields without a value are only kept in
# object output. A switch that asks for one explicitly still reports it missing.
$objectFields = $selected
if ($showAll) { $selected = @($selected | Where-Object { $info[$_] -or -not $fields[$_].Optional }) }

$missing = @($selected | Where-Object { -not $info[$_] })
$labelWidth = ($selected | ForEach-Object { $fields[$_].Label.Length } | Measure-Object -Maximum).Maximum

switch ($mode) {
    'Console' {
        if ($showAll) {
            Write-Host ''
            Write-Host ' IP Address Information' -ForegroundColor White
            Write-Host (' ' + ('-' * 22)) -ForegroundColor DarkGray
            foreach ($key in $selected) {
                Write-Host (' {0} : ' -f $fields[$key].Label.PadRight($labelWidth)) -ForegroundColor Gray -NoNewline
                if ($info[$key]) {
                    Write-Host $info[$key] -ForegroundColor $fields[$key].Color
                } else {
                    Write-Host 'unavailable' -ForegroundColor Red
                }
            }
            Write-Host ''
        } else {
            # Value switches: bare values only, one per line.
            foreach ($key in $selected) {
                if ($info[$key]) {
                    Write-Host $info[$key] -ForegroundColor $fields[$key].Color
                } else {
                    Write-Warning "$($fields[$key].Label) unavailable"
                }
            }
        }
    }
    'Text' {
        if ($showAll) {
            foreach ($key in $selected) {
                $value = if ($info[$key]) { $info[$key] } else { 'unavailable' }
                '{0} : {1}' -f $fields[$key].Label.PadRight($labelWidth), $value
            }
        } else {
            # Value switches: bare values only, one per line. A missing value is
            # an empty line when several are requested, so line positions hold.
            foreach ($key in $selected) {
                if ($info[$key]) { [string]$info[$key] }
                elseif ($selected.Count -gt 1) { '' }
            }
        }
    }
    'Object' {
        $out = [ordered]@{}
        foreach ($key in $objectFields) { $out[$key] = $info[$key] }
        [pscustomobject]$out
    }
}

if ($missing.Count -gt 0) { exit 1 }
