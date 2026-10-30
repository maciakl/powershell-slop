#Requires -Version 5.1
<#
.SYNOPSIS
    DNS Switcher - a keyboard-driven terminal UI for switching DNS servers on Windows 11.

.DESCRIPTION
    DNS Switcher shows the DNS configuration of a network adapter and lets you switch it
    with a single key press to one of these options:

        1  DHCP Default    (automatic, provided by your router / DHCP server)
        2  Google DNS
        3  Cloudflare DNS
        4  OpenDNS
        5  Quad9 DNS
        6  AdGuard DNS
        7  Custom DNS      (enter your own IPv4 and/or IPv6 addresses)

    The current configuration is identified as DHCP, one of the presets, or custom. Manually
    entered addresses that belong to a known provider are recognised as that provider.

    Before the first change to an adapter, its original DNS settings are saved to
    %LOCALAPPDATA%\DNS-Switcher\original-dns.json so they can be restored later with the
    "Restore original" option, even after the script has been closed.

    Only DNS server settings are changed. IP addresses, gateways and every other network
    setting are left untouched.

    Changing DNS requires administrator rights. When started without them the script
    relaunches itself elevated (UAC prompt) in the same kind of terminal it was started from.

.PARAMETER Version
    Display the version number and exit.

.PARAMETER Help
    Display usage information and exit.

.PARAMETER Elevated
    Internal switch used when the script relaunches itself with administrator rights.

.EXAMPLE
    .\DNS-Switcher.ps1

    Starts the interactive DNS Switcher.

.EXAMPLE
    .\DNS-Switcher.ps1 -Version

    Prints the version number, e.g. "DNS Switcher 0.1.0".

.EXAMPLE
    .\DNS-Switcher.ps1 -Help

    Prints usage information.

.NOTES
    Version : 0.1.0  (keep in sync with $script:AppVersion below)
    Requires: Windows 11, Windows PowerShell 5.1 or PowerShell 7+
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Interactive console UI must write directly to the host.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'New-* helpers only build in-memory UI objects.')]
[CmdletBinding()]
param(
    [switch]$Version,

    [switch]$Help,

    [Parameter(DontShow)]
    [switch]$Elevated
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# NOTE: This file is intentionally pure ASCII so Windows PowerShell 5.1 reads it correctly
# regardless of file encoding. Box drawing and symbol characters are created from code points.

#region Configuration ---------------------------------------------------------------------------

$script:AppName    = 'DNS Switcher'
$script:AppVersion = '0.1.0'
$script:ScriptPath = $PSCommandPath

# Characters used by the UI (all present in Cascadia Mono / Consolas).
$script:Glyph = @{
    Pointer = [string][char]0x25BA   # black right-pointing pointer
    Current = [string][char]0x25CF   # black circle
    Line    = [string][char]0x2500   # box drawings light horizontal
    Up      = [string][char]0x2191   # upwards arrow
    Down    = [string][char]0x2193   # downwards arrow
}

# Preset DNS providers. IPv4/IPv6 are the servers that get applied. Variants are additional
# addresses of the same provider (e.g. filtered resolvers) that are only used to recognise
# a provider when its addresses were entered manually.
$script:DnsPresets = @(
    [pscustomobject]@{
        Id       = 'Google'
        Name     = 'Google DNS'
        Hotkey   = '2'
        IPv4     = @('8.8.8.8', '8.8.4.4')
        IPv6     = @('2001:4860:4860::8888', '2001:4860:4860::8844')
        Variants = @()
    }
    [pscustomobject]@{
        Id       = 'Cloudflare'
        Name     = 'Cloudflare DNS'
        Hotkey   = '3'
        IPv4     = @('1.1.1.1', '1.0.0.1')
        IPv6     = @('2606:4700:4700::1111', '2606:4700:4700::1001')
        Variants = @(
            [pscustomobject]@{ Name = 'Malware blocking'; Addresses = @('1.1.1.2', '1.0.0.2', '2606:4700:4700::1112', '2606:4700:4700::1002') }
            [pscustomobject]@{ Name = 'Families'; Addresses = @('1.1.1.3', '1.0.0.3', '2606:4700:4700::1113', '2606:4700:4700::1003') }
        )
    }
    [pscustomobject]@{
        Id       = 'OpenDNS'
        Name     = 'OpenDNS'
        Hotkey   = '4'
        IPv4     = @('208.67.222.222', '208.67.220.220')
        IPv6     = @('2620:119:35::35', '2620:119:53::53')
        Variants = @(
            [pscustomobject]@{ Name = 'FamilyShield'; Addresses = @('208.67.222.123', '208.67.220.123', '2620:119:35::123', '2620:119:53::123') }
        )
    }
    [pscustomobject]@{
        Id       = 'Quad9'
        Name     = 'Quad9 DNS'
        Hotkey   = '5'
        IPv4     = @('9.9.9.9', '149.112.112.112')
        IPv6     = @('2620:fe::fe', '2620:fe::9')
        Variants = @(
            [pscustomobject]@{ Name = 'Unsecured'; Addresses = @('9.9.9.10', '149.112.112.10', '2620:fe::10', '2620:fe::fe:10') }
            [pscustomobject]@{ Name = 'ECS'; Addresses = @('9.9.9.11', '149.112.112.11', '2620:fe::11', '2620:fe::fe:11') }
        )
    }
    [pscustomobject]@{
        Id       = 'AdGuard'
        Name     = 'AdGuard DNS'
        Hotkey   = '6'
        IPv4     = @('94.140.14.14', '94.140.15.15')
        IPv6     = @('2a10:50c0::ad1:ff', '2a10:50c0::ad2:ff')
        Variants = @(
            [pscustomobject]@{ Name = 'Family protection'; Addresses = @('94.140.14.15', '94.140.15.16', '2a10:50c0::bad1:ff', '2a10:50c0::bad2:ff') }
            [pscustomobject]@{ Name = 'Non-filtering'; Addresses = @('94.140.14.140', '94.140.14.141', '2a10:50c0::1:ff', '2a10:50c0::2:ff') }
        )
    }
)

# Message shown above the key help line. Updated by Set-Status.
$script:Status = $null

# Size of the last frame drawn, used to redraw efficiently without flicker.
$script:FrameWidth  = -1
$script:FrameHeight = -1
$script:FrameLines  = 0

#endregion

#region Help and environment checks -------------------------------------------------------------

function Show-Usage {
    <#
    .SYNOPSIS
        Writes the command line usage text.
    #>
    [CmdletBinding()]
    param()

    @"
$($script:AppName) $($script:AppVersion)
Switch the DNS servers of a network adapter from an interactive terminal UI.

USAGE
    .\DNS-Switcher.ps1            Start the interactive UI (elevates automatically)
    .\DNS-Switcher.ps1 -Version   Show the version number and exit
    .\DNS-Switcher.ps1 -Help      Show this help and exit

KEYS
    Up/Down, Home/End   Move the selection
    Enter               Apply the selected option
    1-7                 Apply an option directly
    R                   Restore the DNS settings from before the first change
    A                   Choose another network adapter
    F5                  Refresh the current settings
    Q / Esc             Quit

PRESETS
    1  DHCP Default     Automatic DNS from your router / DHCP server
    2  Google DNS       8.8.8.8, 8.8.4.4
    3  Cloudflare DNS   1.1.1.1, 1.0.0.1
    4  OpenDNS          208.67.222.222, 208.67.220.220
    5  Quad9 DNS        9.9.9.9, 149.112.112.112
    6  AdGuard DNS      94.140.14.14, 94.140.15.15
    7  Custom DNS       Your own IPv4 and/or IPv6 addresses

IPv6 servers of a preset are applied as well when IPv6 is enabled on the adapter.
Original settings are saved to %LOCALAPPDATA%\DNS-Switcher\original-dns.json.

For full help run: Get-Help .\DNS-Switcher.ps1 -Full
"@
}

function Test-IsAdministrator {
    <#
    .SYNOPSIS
        Returns $true when the current process runs with administrator rights.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    $identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object -TypeName Security.Principal.WindowsPrincipal -ArgumentList $identity
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Assert-Environment {
    <#
    .SYNOPSIS
        Stops with a clear message when the script cannot run in the current environment.
    #>
    [CmdletBinding()]
    param()

    if ($PSVersionTable.PSEdition -eq 'Core' -and -not $IsWindows) {
        throw "$($script:AppName) only works on Windows."
    }
    if ($Host.Name -eq 'Windows PowerShell ISE Host') {
        throw "$($script:AppName) needs a real console. Run it from Windows Terminal or a PowerShell window instead of the ISE."
    }
    if ([Console]::IsInputRedirected -or [Console]::IsOutputRedirected) {
        throw "$($script:AppName) is interactive and cannot run with redirected input or output."
    }
}

function Test-ElevationCancelled {
    <#
    .SYNOPSIS
        Returns $true when an error record was caused by the user declining the UAC prompt.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [System.Management.Automation.ErrorRecord]$ErrorRecord
    )

    # Win32 error 1223 = ERROR_CANCELLED ("The operation was canceled by the user").
    $exception = $ErrorRecord.Exception
    while ($null -ne $exception) {
        if ($exception -is [System.ComponentModel.Win32Exception] -and $exception.NativeErrorCode -eq 1223) {
            return $true
        }
        $exception = $exception.InnerException
    }
    return ($ErrorRecord.Exception.Message -match 'cancel+ed by the user')
}

function Start-ElevatedInstance {
    <#
    .SYNOPSIS
        Relaunches this script with administrator rights in the same kind of terminal.
    .DESCRIPTION
        Uses the same PowerShell executable (powershell.exe or pwsh.exe) as the current
        session. When running inside Windows Terminal the elevated copy is opened in
        Windows Terminal as well. Returns $true when the elevated copy was started.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    if (-not $script:ScriptPath) {
        throw "$($script:AppName) needs administrator rights and could not relaunch itself because it is not running from a file. Open PowerShell as administrator and run it again."
    }

    $hostExecutable = (Get-Process -Id $PID).Path
    $powerShellArgs = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -Elevated' -f $script:ScriptPath

    # WT_SESSION is set by Windows Terminal for every shell running inside it.
    $useWindowsTerminal = $false
    if ($env:WT_SESSION -and (Get-Command -Name 'wt.exe' -CommandType Application -ErrorAction SilentlyContinue)) {
        $useWindowsTerminal = $true
    }

    if ($useWindowsTerminal) {
        $filePath = 'wt.exe'
        # Windows Terminal treats ';' as a command separator, so escape it in paths.
        $argumentLine = ('"{0}" {1}' -f $hostExecutable, $powerShellArgs) -replace ';', '\;'
    }
    else {
        $filePath     = $hostExecutable
        $argumentLine = $powerShellArgs
    }

    try {
        Start-Process -FilePath $filePath -ArgumentList $argumentLine -Verb RunAs -ErrorAction Stop | Out-Null
        return $true
    }
    catch {
        if (Test-ElevationCancelled -ErrorRecord $_) {
            Write-Host ''
            Write-Host '  Administrator rights were not granted.' -ForegroundColor Red
            Write-Host "  $($script:AppName) needs administrator rights to change DNS settings." -ForegroundColor Red
            Write-Host '  Run the script again and choose "Yes" when Windows asks for permission.' -ForegroundColor Yellow
            Write-Host ''
            return $false
        }
        throw "Could not start $($script:AppName) with administrator rights: $($_.Exception.Message)"
    }
}

#endregion

#region DNS addresses and identification --------------------------------------------------------

function ConvertTo-NormalizedAddress {
    <#
    .SYNOPSIS
        Returns the canonical, lower-case text form of an IP address (e.g. compressed IPv6).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$Address
    )

    return ([System.Net.IPAddress]::Parse($Address.Trim())).ToString().ToLowerInvariant()
}

function Test-DnsServerAddress {
    <#
    .SYNOPSIS
        Validates a DNS server address typed by the user.
    .OUTPUTS
        An object with IsValid, Address (normalized), Family ('IPv4'/'IPv6') and Reason.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Address
    )

    $text   = $Address.Trim()
    $result = [pscustomobject]@{ IsValid = $false; Address = $text; Family = $null; Reason = $null }

    # Strict dotted quad: four numbers 0-255 without leading zeros. IPAddress.TryParse alone
    # would also accept things like "1" or "1.2.3" which are almost certainly typos.
    $octet = '(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])'
    $ipv4Pattern = "^$octet(\.$octet){3}$"

    if ($text -match $ipv4Pattern) {
        $parsed = [System.Net.IPAddress]::Parse($text)
        $first  = [int]$parsed.GetAddressBytes()[0]
        if ($text -eq '0.0.0.0') {
            $result.Reason = 'is the unspecified address and cannot be used as a DNS server.'
        }
        elseif ($first -ge 224) {
            $result.Reason = 'is a multicast, broadcast or reserved address and cannot be used as a DNS server.'
        }
        else {
            $result.IsValid = $true
            $result.Family  = 'IPv4'
            $result.Address = $parsed.ToString()
        }
        return $result
    }

    $parsedV6 = $null
    if ($text -match '^[0-9A-Fa-f:.]+$' -and $text.Contains(':') -and
        [System.Net.IPAddress]::TryParse($text, [ref]$parsedV6) -and
        $parsedV6.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetworkV6) {

        if ($parsedV6.Equals([System.Net.IPAddress]::IPv6None)) {
            $result.Reason = 'is the unspecified address and cannot be used as a DNS server.'
        }
        elseif ($parsedV6.IsIPv6Multicast) {
            $result.Reason = 'is a multicast address and cannot be used as a DNS server.'
        }
        else {
            $result.IsValid = $true
            $result.Family  = 'IPv6'
            $result.Address = $parsedV6.ToString().ToLowerInvariant()
        }
        return $result
    }

    if ($text -match '^[0-9.]+$') {
        $result.Reason = 'is not a valid IPv4 address. Use four numbers from 0 to 255, e.g. 1.1.1.1'
    }
    else {
        $result.Reason = 'is not a valid IPv4 or IPv6 address. Examples: 1.1.1.1 or 2606:4700:4700::1111'
    }
    return $result
}

function Get-KnownAddressTable {
    <#
    .SYNOPSIS
        Builds a lookup table: normalized address -> provider id and variant name.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()

    $table = @{}
    foreach ($preset in $script:DnsPresets) {
        foreach ($address in (@($preset.IPv4) + @($preset.IPv6))) {
            $table[(ConvertTo-NormalizedAddress -Address $address)] = [pscustomobject]@{ PresetId = $preset.Id; Variant = '' }
        }
        foreach ($variant in @($preset.Variants)) {
            foreach ($address in @($variant.Addresses)) {
                $table[(ConvertTo-NormalizedAddress -Address $address)] = [pscustomobject]@{ PresetId = $preset.Id; Variant = $variant.Name }
            }
        }
    }
    return $table
}

function Get-DnsIdentity {
    <#
    .SYNOPSIS
        Identifies a list of manually configured DNS servers.
    .DESCRIPTION
        No addresses means DHCP. When every address belongs to the same known provider the
        provider is returned, otherwise the configuration is reported as custom.
    .OUTPUTS
        An object with Id ('DHCP', a preset Id or 'Custom') and a display Name.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [string[]]$Addresses = @()
    )

    $list = @($Addresses | Where-Object { $_ })
    if ($list.Count -eq 0) {
        return [pscustomobject]@{ Id = 'DHCP'; Name = 'DHCP Default' }
    }

    $presetIds = New-Object -TypeName 'System.Collections.Generic.List[string]'
    $variants  = New-Object -TypeName 'System.Collections.Generic.List[string]'
    foreach ($address in $list) {
        $key = $address
        try { $key = ConvertTo-NormalizedAddress -Address $address } catch { Write-Verbose "Unparseable address '$address'." }

        if (-not $script:KnownAddresses.ContainsKey($key)) {
            return [pscustomobject]@{ Id = 'Custom'; Name = 'Custom DNS' }
        }
        $hit = $script:KnownAddresses[$key]
        if (-not $presetIds.Contains($hit.PresetId)) { $presetIds.Add($hit.PresetId) }
        if (-not $variants.Contains($hit.Variant)) { $variants.Add($hit.Variant) }
    }

    if ($presetIds.Count -ne 1) {
        return [pscustomobject]@{ Id = 'Custom'; Name = 'Custom DNS (mixed providers)' }
    }

    $preset = $script:DnsPresets | Where-Object { $_.Id -eq $presetIds[0] }
    $name   = $preset.Name
    if ($variants.Count -eq 1 -and $variants[0]) {
        $name = '{0} ({1})' -f $name, $variants[0]
    }
    return [pscustomobject]@{ Id = $preset.Id; Name = $name }
}

#endregion

#region Network adapter and DNS state -----------------------------------------------------------

# Network information is read straight from CIM (root/StandardCimv2) instead of through the
# NetAdapter, NetTCPIP and DnsClient cmdlets. Loading those modules takes several seconds,
# which made the screen stay blank for a long time at startup. The CIM queries take milliseconds.
$script:CimNamespace = 'root/StandardCimv2'

function Get-CimNetwork {
    <#
    .SYNOPSIS
        Queries a class in root/StandardCimv2. Returns nothing when the query fails.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ClassName,

        [string]$Filter
    )

    $params = @{ Namespace = $script:CimNamespace; ClassName = $ClassName; ErrorAction = 'SilentlyContinue' }
    if ($Filter) { $params.Filter = $Filter }
    Get-CimInstance @params
}

function Get-AdapterStatusText {
    <#
    .SYNOPSIS
        Turns MSFT_NetAdapter status fields into the same text Get-NetAdapter shows.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        $CimAdapter
    )

    switch ([int]$CimAdapter.InterfaceOperationalStatus) {
        1 { return 'Up' }
        3 { return 'Testing' }
        4 { return 'Unknown' }
        5 { return 'Dormant' }
        6 { return 'Not Present' }
        7 { return 'Lower Layer Down' }
        2 {
            if ([int]$CimAdapter.InterfaceAdminStatus -eq 2) { return 'Disabled' }
            $reasons = @()
            if ($CimAdapter.OperationalStatusDownDefaultPortNotAuthenticated) { $reasons += 'Not Authenticated' }
            if ($CimAdapter.OperationalStatusDownMediaDisconnected) { $reasons += 'Disconnected' }
            if ($CimAdapter.OperationalStatusDownLowPowerState) { $reasons += 'Low Power State' }
            if ($reasons.Count -gt 0) { return ($reasons -join ', ') }
            return 'Down'
        }
    }
    return 'Unknown'
}

function Get-NetworkAdapter {
    <#
    .SYNOPSIS
        Returns the visible network adapters (like Get-NetAdapter), optionally just one.
    #>
    [CmdletBinding()]
    param(
        [int]$InterfaceIndex = -1
    )

    $filter = $null
    if ($InterfaceIndex -ge 0) { $filter = "InterfaceIndex = $InterfaceIndex" }

    foreach ($cim in @(Get-CimNetwork -ClassName 'MSFT_NetAdapter' -Filter $filter)) {
        if ($cim.Hidden) { continue }
        [pscustomobject]@{
            Name                 = [string]$cim.Name
            ifIndex              = [int]$cim.InterfaceIndex
            InterfaceGuid        = [string]$cim.InterfaceGuid
            InterfaceDescription = [string]$cim.InterfaceDescription
            Status               = Get-AdapterStatusText -CimAdapter $cim
            # Same test Get-NetAdapter -Physical uses. VPN and other virtual adapters have no connector.
            IsPhysical           = [bool]$cim.ConnectorPresent -and -not [bool]$cim.Virtual
        }
    }
}

function Get-PreferredAdapter {
    <#
    .SYNOPSIS
        Returns the adapter used for internet traffic (lowest metric default route).
        Physical adapters win over virtual ones (VPN clients such as Cato often give their
        virtual adapter the lowest metric, but DNS should normally be set on the real adapter).
    #>
    [CmdletBinding()]
    param()

    $adapters = @(Get-NetworkAdapter)
    if ($adapters.Count -eq 0) {
        throw 'No network adapters were found on this computer.'
    }

    # Physical adapters first, keeping the original order within each group.
    $adapters   = @(@($adapters | Where-Object { $_.IsPhysical }) + @($adapters | Where-Object { -not $_.IsPhysical }))
    $upAdapters = @($adapters | Where-Object { $_.Status -eq 'Up' })
    $upIndexes  = @($upAdapters | ForEach-Object { $_.ifIndex })
    $physicalIndexes = @($upAdapters | Where-Object { $_.IsPhysical } | ForEach-Object { $_.ifIndex })

    $routes = @(Get-CimNetwork -ClassName 'MSFT_NetRoute' -Filter "DestinationPrefix = '0.0.0.0/0'" |
            Where-Object { $upIndexes -contains [int]$_.InterfaceIndex })

    if ($routes.Count -gt 0) {
        # Windows picks the route with the lowest route metric + interface metric.
        # AddressFamily 2 = IPv4.
        $metrics = @{}
        foreach ($interface in @(Get-CimNetwork -ClassName 'MSFT_NetIPInterface' -Filter 'AddressFamily = 2')) {
            $metrics[[int]$interface.InterfaceIndex] = [int]$interface.InterfaceMetric
        }
        $best = $routes | Sort-Object -Property @{
            Expression = { $physicalIndexes -notcontains [int]$_.InterfaceIndex }
        }, @{
            Expression = {
                $interfaceMetric = 0
                if ($metrics.ContainsKey([int]$_.InterfaceIndex)) { $interfaceMetric = $metrics[[int]$_.InterfaceIndex] }
                [int]$_.RouteMetric + $interfaceMetric
            }
        } | Select-Object -First 1
        return $adapters | Where-Object { $_.ifIndex -eq [int]$best.InterfaceIndex } | Select-Object -First 1
    }

    if ($upAdapters.Count -gt 0) {
        return $upAdapters[0]
    }
    return $adapters[0]
}

function Test-IPv6Enabled {
    <#
    .SYNOPSIS
        Returns $true when the IPv6 protocol is bound to the adapter.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        $Adapter
    )

    $name = $Adapter.Name -replace "'", "''"
    $bindings = @(Get-CimNetwork -ClassName 'MSFT_NetAdapterBindingSettingData' -Filter "Name = '$name' AND ComponentID = 'ms_tcpip6'")
    return (@($bindings | Where-Object { $_.Enabled }).Count -gt 0)
}

function Get-StaticDnsServer {
    <#
    .SYNOPSIS
        Returns the manually configured DNS servers of an interface (none = DHCP).
    .DESCRIPTION
        Windows stores manually configured servers in the NameServer registry value of the
        interface. When it is empty the servers come from DHCP. This is read only.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$InterfaceGuid,

        [Parameter(Mandatory)]
        [ValidateSet('IPv4', 'IPv6')]
        [string]$AddressFamily
    )

    $service = 'Tcpip'
    if ($AddressFamily -eq 'IPv6') { $service = 'Tcpip6' }
    $path = "HKLM:\SYSTEM\CurrentControlSet\Services\$service\Parameters\Interfaces\$InterfaceGuid"

    if (-not (Test-Path -LiteralPath $path)) { return }

    $raw = [string](Get-Item -LiteralPath $path).GetValue('NameServer', '')
    foreach ($entry in ($raw -split '[,\s]+')) {
        if (-not $entry) { continue }
        try { ConvertTo-NormalizedAddress -Address $entry } catch { Write-Verbose "Ignoring invalid registry entry '$entry'." }
    }
}

function Get-EffectiveDnsServer {
    <#
    .SYNOPSIS
        Returns the DNS servers the adapter is actually using for one address family.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [int]$InterfaceIndex,

        [Parameter(Mandatory)]
        [ValidateSet('IPv4', 'IPv6')]
        [string]$AddressFamily
    )

    $family = 2
    if ($AddressFamily -eq 'IPv6') { $family = 23 }
    $entries = @(Get-CimNetwork -ClassName 'MSFT_DNSClientServerAddress' -Filter "InterfaceIndex = $InterfaceIndex AND AddressFamily = $family")
    foreach ($entry in $entries) {
        foreach ($address in @($entry.ServerAddresses)) {
            # fec0:0:0:ffff::1-3 are deprecated placeholders Windows shows when no IPv6 DNS exists.
            if ($address -and $address -notlike 'fec0:0:0:ffff::*') { $address }
        }
    }
}

function Get-DnsState {
    <#
    .SYNOPSIS
        Reads the complete DNS configuration of an adapter.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        $Adapter
    )

    $ipv6Enabled = Test-IPv6Enabled -Adapter $Adapter
    $staticV4    = @(Get-StaticDnsServer -InterfaceGuid $Adapter.InterfaceGuid -AddressFamily IPv4)
    $staticV6    = @()
    if ($ipv6Enabled) {
        $staticV6 = @(Get-StaticDnsServer -InterfaceGuid $Adapter.InterfaceGuid -AddressFamily IPv6)
    }

    return [pscustomobject]@{
        IPv6Enabled = $ipv6Enabled
        IPv4Static  = $staticV4
        IPv6Static  = $staticV6
        IPv4Active  = @(Get-EffectiveDnsServer -InterfaceIndex $Adapter.ifIndex -AddressFamily IPv4)
        IPv6Active  = @(Get-EffectiveDnsServer -InterfaceIndex $Adapter.ifIndex -AddressFamily IPv6)
        Identity    = Get-DnsIdentity -Addresses (@($staticV4) + @($staticV6))
    }
}

function Set-AdapterDnsServer {
    <#
    .SYNOPSIS
        Applies DNS servers to an adapter. Empty lists mean "use DHCP" for that family.
    .DESCRIPTION
        The adapter is first reset to DHCP-provided DNS for both IPv4 and IPv6, then the
        given servers are applied. This keeps the result predictable for both families.
        Only DNS server settings are modified; the DNS cache is flushed afterwards.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        $Adapter,

        [string[]]$IPv4 = @(),

        [string[]]$IPv6 = @()
    )

    $servers = @(@($IPv4) + @($IPv6) | Where-Object { $_ })
    $target  = 'DNS servers of adapter "{0}"' -f $Adapter.Name
    $action  = 'Use DHCP'
    if ($servers.Count -gt 0) { $action = 'Set to ' + ($servers -join ', ') }

    if ($PSCmdlet.ShouldProcess($target, $action)) {
        Set-DnsClientServerAddress -InterfaceIndex $Adapter.ifIndex -ResetServerAddresses -ErrorAction Stop
        if ($servers.Count -gt 0) {
            Set-DnsClientServerAddress -InterfaceIndex $Adapter.ifIndex -ServerAddresses $servers -ErrorAction Stop
        }
        Clear-DnsClientCache -ErrorAction SilentlyContinue
    }
}

#endregion

#region Original settings backup ----------------------------------------------------------------

function Get-BackupPath {
    <#
    .SYNOPSIS
        Returns the path of the file holding the original DNS settings.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    return (Join-Path -Path $env:LOCALAPPDATA -ChildPath 'DNS-Switcher\original-dns.json')
}

function Read-DnsBackup {
    <#
    .SYNOPSIS
        Loads saved original DNS settings as a hashtable keyed by interface GUID.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()

    $backup = @{}
    $path   = Get-BackupPath
    if (-not (Test-Path -LiteralPath $path)) { return $backup }

    try {
        $data = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
        foreach ($property in @($data.PSObject.Properties)) {
            $entry = $property.Value
            $backup[$property.Name] = [pscustomobject]@{
                AdapterName = [string]$entry.AdapterName
                IPv4        = @(@($entry.IPv4) | Where-Object { $_ })
                IPv6        = @(@($entry.IPv6) | Where-Object { $_ })
                SavedAt     = [string]$entry.SavedAt
            }
        }
    }
    catch {
        Set-Status -Text "Could not read saved original settings ($path): $($_.Exception.Message)" -Color Yellow
    }
    return $backup
}

function Write-DnsBackup {
    <#
    .SYNOPSIS
        Saves the original DNS settings hashtable to disk (deletes the file when empty).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Backup
    )

    $path = Get-BackupPath
    if ($Backup.Count -eq 0) {
        if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force }
        return
    }

    $folder = Split-Path -Path $path -Parent
    if (-not (Test-Path -LiteralPath $folder)) {
        New-Item -Path $folder -ItemType Directory -Force | Out-Null
    }
    $Backup | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $path -Encoding UTF8
}

function Get-OriginalDns {
    <#
    .SYNOPSIS
        Returns the saved original DNS settings of an adapter, or $null.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $Adapter
    )

    $backup = Read-DnsBackup
    if ($backup.ContainsKey($Adapter.InterfaceGuid)) {
        return $backup[$Adapter.InterfaceGuid]
    }
    return $null
}

function Save-OriginalDns {
    <#
    .SYNOPSIS
        Saves the adapter's current DNS settings unless an original is already saved.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $Adapter,

        [Parameter(Mandatory)]
        $State
    )

    $backup = Read-DnsBackup
    if ($backup.ContainsKey($Adapter.InterfaceGuid)) { return }

    $backup[$Adapter.InterfaceGuid] = [pscustomobject]@{
        AdapterName = $Adapter.Name
        IPv4        = @($State.IPv4Static)
        IPv6        = @($State.IPv6Static)
        SavedAt     = (Get-Date).ToString('yyyy-MM-dd HH:mm')
    }
    Write-DnsBackup -Backup $backup
}

function Remove-OriginalDns {
    <#
    .SYNOPSIS
        Forgets the saved original DNS settings of an adapter.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        $Adapter
    )

    $backup = Read-DnsBackup
    if ($backup.ContainsKey($Adapter.InterfaceGuid) -and $PSCmdlet.ShouldProcess((Get-BackupPath), 'Remove saved original DNS settings')) {
        $backup.Remove($Adapter.InterfaceGuid)
        Write-DnsBackup -Backup $backup
    }
}

#endregion

#region Console rendering -----------------------------------------------------------------------

function New-Segment {
    <#
    .SYNOPSIS
        Creates a piece of coloured text. $null colours use the terminal defaults.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory, Position = 0)]
        [AllowEmptyString()]
        [string]$Text,

        [Parameter(Position = 1)]
        $Foreground = $null,

        [Parameter(Position = 2)]
        $Background = $null
    )

    return [pscustomobject]@{ Text = $Text; Foreground = $Foreground; Background = $Background }
}

function Set-Status {
    <#
    .SYNOPSIS
        Sets the message shown at the bottom of the screen.
    #>
    [CmdletBinding()]
    param(
        [AllowEmptyString()]
        [string]$Text = '',

        [ConsoleColor]$Color = [ConsoleColor]::Gray
    )

    if ($Text) {
        $script:Status = [pscustomobject]@{ Text = $Text; Color = $Color }
    }
    else {
        $script:Status = $null
    }
}

function Reset-Frame {
    <#
    .SYNOPSIS
        Forces the next frame to clear the screen first.
    #>
    [CmdletBinding()]
    param()

    $script:FrameWidth = -1
}

function Write-Frame {
    <#
    .SYNOPSIS
        Draws a full screen of lines. Each line is an array of segments.
    .DESCRIPTION
        Instead of clearing the screen on every key press (which flickers), the cursor is
        moved to the top and every line is overwritten and padded to the window width.
        The screen is only cleared when the window size changed.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object[]]$Lines
    )

    $windowWidth  = [Math]::Max(20, [Console]::WindowWidth)
    $windowHeight = [Console]::WindowHeight
    $width        = $windowWidth - 1

    if ($windowWidth -ne $script:FrameWidth -or $windowHeight -ne $script:FrameHeight -or $Lines.Count -ge $windowHeight) {
        Clear-Host
        $script:FrameWidth  = $windowWidth
        $script:FrameHeight = $windowHeight
        $script:FrameLines  = 0
    }

    [Console]::SetCursorPosition(0, 0)

    foreach ($line in $Lines) {
        $used = 0
        foreach ($segment in @($line)) {
            if ($null -eq $segment) { continue }
            $remaining = $width - $used
            if ($remaining -le 0) { break }

            $text = [string]$segment.Text
            if ($text.Length -gt $remaining) { $text = $text.Substring(0, $remaining) }
            if ($text.Length -eq 0) { continue }

            $writeArgs = @{ Object = $text; NoNewline = $true }
            if ($null -ne $segment.Foreground) { $writeArgs.ForegroundColor = $segment.Foreground }
            if ($null -ne $segment.Background) { $writeArgs.BackgroundColor = $segment.Background }
            Write-Host @writeArgs
            $used += $text.Length
        }
        Write-Host (' ' * [Math]::Max(0, $width - $used))
    }

    # Blank out lines left over from a taller previous frame.
    for ($i = $Lines.Count; $i -lt $script:FrameLines; $i++) {
        Write-Host (' ' * $width)
    }
    $script:FrameLines = $Lines.Count
}

function Read-ConsoleKey {
    <#
    .SYNOPSIS
        Waits for a key press. Returns $null when the window was resized meanwhile.
    #>
    [CmdletBinding()]
    param()

    $width  = [Console]::WindowWidth
    $height = [Console]::WindowHeight
    while (-not [Console]::KeyAvailable) {
        if ([Console]::WindowWidth -ne $width -or [Console]::WindowHeight -ne $height) {
            return $null
        }
        Start-Sleep -Milliseconds 40
    }
    return [Console]::ReadKey($true)
}

function New-MenuItem {
    <#
    .SYNOPSIS
        Creates a menu entry (or a separator line when -Separator is used).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [string]$Key = '',
        [string]$Label = '',
        [string]$Detail = '',
        [string]$Hotkey = '',
        [switch]$IsCurrent,
        [switch]$Separator
    )

    return [pscustomobject]@{
        Key         = $Key
        Label       = $Label
        Detail      = $Detail
        Hotkey      = $Hotkey
        IsCurrent   = [bool]$IsCurrent
        IsSeparator = [bool]$Separator
    }
}

function Format-MenuItem {
    <#
    .SYNOPSIS
        Turns a menu item into a line of segments.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $Item,

        [bool]$Selected,

        [int]$LabelWidth = 18
    )

    if ($Item.IsSeparator) {
        return , @(New-Segment ('      ' + ($script:Glyph.Line * ($LabelWidth + 6))) DarkGray)
    }

    $segments = New-Object -TypeName 'System.Collections.Generic.List[object]'
    if ($Selected) {
        $segments.Add((New-Segment ("  $($script:Glyph.Pointer) ") Cyan))
    }
    else {
        $segments.Add((New-Segment '    '))
    }

    $hotkeyText = '   '
    if ($Item.Hotkey) { $hotkeyText = '[' + $Item.Hotkey.ToUpperInvariant() + ']' }
    $label = ' ' + $Item.Label.PadRight($LabelWidth) + ' '

    if ($Selected) {
        $segments.Add((New-Segment $hotkeyText Yellow))
        $segments.Add((New-Segment ' '))
        $segments.Add((New-Segment $label Black Cyan))
    }
    else {
        $segments.Add((New-Segment $hotkeyText DarkGray))
        $segments.Add((New-Segment ' '))
        $segments.Add((New-Segment $label))
    }

    if ($Item.Detail) { $segments.Add((New-Segment ('  ' + $Item.Detail) DarkGray)) }
    if ($Item.IsCurrent) { $segments.Add((New-Segment ("  $($script:Glyph.Current) current") Green)) }

    return , $segments.ToArray()
}

function Invoke-Menu {
    <#
    .SYNOPSIS
        Shows a header and a keyboard driven menu and returns the Key of the chosen item.
    .OUTPUTS
        The chosen item's Key, 'Escape', 'Quit' (Ctrl+C) or 'Refresh' (F5).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [object[]]$Header = @(),

        [Parameter(Mandatory)]
        [object[]]$Items,

        [string]$InitialKey = '',

        [string]$Footer = ''
    )

    $selectable = @(for ($i = 0; $i -lt $Items.Count; $i++) { if (-not $Items[$i].IsSeparator) { $i } })
    if ($selectable.Count -eq 0) { return 'Escape' }

    $position = 0
    for ($i = 0; $i -lt $selectable.Count; $i++) {
        if ($InitialKey -and $Items[$selectable[$i]].Key -eq $InitialKey) { $position = $i }
    }

    $labelWidth = 18
    foreach ($item in $Items) { $labelWidth = [Math]::Max($labelWidth, $item.Label.Length) }

    while ($true) {
        $lines = New-Object -TypeName 'System.Collections.Generic.List[object]'
        foreach ($line in $Header) { $lines.Add($line) }
        for ($i = 0; $i -lt $Items.Count; $i++) {
            $lines.Add((Format-MenuItem -Item $Items[$i] -Selected ($i -eq $selectable[$position]) -LabelWidth $labelWidth))
        }
        $lines.Add(@())
        if ($null -ne $script:Status) {
            $lines.Add(@(New-Segment ('  ' + $script:Status.Text) $script:Status.Color))
        }
        else {
            $lines.Add(@())
        }
        $lines.Add(@(New-Segment ('  ' + $Footer) DarkGray))

        Write-Frame -Lines $lines.ToArray()

        $keyInfo = Read-ConsoleKey
        if ($null -eq $keyInfo) { continue }   # window resized: redraw

        $isCtrl = ($keyInfo.Modifiers -band [ConsoleModifiers]::Control) -ne 0
        if ($isCtrl -and $keyInfo.Key -eq [ConsoleKey]::C) { return 'Quit' }

        $count = $selectable.Count
        if ($keyInfo.Key -eq [ConsoleKey]::UpArrow) {
            $position = ($position - 1 + $count) % $count
        }
        elseif ($keyInfo.Key -eq [ConsoleKey]::DownArrow -or $keyInfo.Key -eq [ConsoleKey]::Tab) {
            $position = ($position + 1) % $count
        }
        elseif ($keyInfo.Key -eq [ConsoleKey]::Home -or $keyInfo.Key -eq [ConsoleKey]::PageUp) {
            $position = 0
        }
        elseif ($keyInfo.Key -eq [ConsoleKey]::End -or $keyInfo.Key -eq [ConsoleKey]::PageDown) {
            $position = $count - 1
        }
        elseif ($keyInfo.Key -eq [ConsoleKey]::Enter -or $keyInfo.Key -eq [ConsoleKey]::Spacebar) {
            return $Items[$selectable[$position]].Key
        }
        elseif ($keyInfo.Key -eq [ConsoleKey]::Escape) {
            return 'Escape'
        }
        elseif ($keyInfo.Key -eq [ConsoleKey]::F5) {
            return 'Refresh'
        }
        else {
            $character = [string]$keyInfo.KeyChar
            foreach ($item in $Items) {
                if ($item.Hotkey -and $item.Hotkey -eq $character) { return $item.Key }
            }
        }
    }
}

#endregion

#region Screens ---------------------------------------------------------------------------------

function Format-ServerList {
    <#
    .SYNOPSIS
        Describes the DNS servers of one address family for the header.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [string[]]$Static = @(),
        [string[]]$Active = @(),
        [bool]$Enabled = $true
    )

    $staticList = @($Static | Where-Object { $_ })
    $activeList = @($Active | Where-Object { $_ })

    if (-not $Enabled) {
        return [pscustomobject]@{ Text = 'IPv6 is disabled on this adapter'; Note = '' }
    }
    if ($staticList.Count -gt 0) {
        return [pscustomobject]@{ Text = ($staticList -join ', '); Note = 'manual' }
    }
    if ($activeList.Count -gt 0) {
        return [pscustomobject]@{ Text = ($activeList -join ', '); Note = 'from DHCP' }
    }
    return [pscustomobject]@{ Text = 'none'; Note = 'automatic' }
}

function New-TitleLines {
    <#
    .SYNOPSIS
        Returns the title bar lines shared by all screens.
    #>
    [CmdletBinding()]
    param(
        [string]$Subtitle = ''
    )

    $title = New-Object -TypeName 'System.Collections.Generic.List[object]'
    $title.Add(@(
            (New-Segment '  '),
            (New-Segment " $($script:AppName) " White DarkBlue),
            (New-Segment "  v$($script:AppVersion)" DarkGray),
            (New-Segment "  $Subtitle" DarkGray)
        ))
    $title.Add(@(New-Segment ('  ' + ($script:Glyph.Line * 60)) DarkGray))
    $title.Add(@())
    return , $title.ToArray()
}

function New-MainHeader {
    <#
    .SYNOPSIS
        Builds the header of the main screen: adapter, current and original settings.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $Adapter,

        [Parameter(Mandatory)]
        $State,

        $Original
    )

    $lines = New-Object -TypeName 'System.Collections.Generic.List[object]'
    foreach ($line in (New-TitleLines -Subtitle 'Windows DNS made easy')) { $lines.Add($line) }

    $statusColor = 'Yellow'
    if ($Adapter.Status -eq 'Up') { $statusColor = 'Green' }
    $lines.Add(@(
            (New-Segment '  Adapter    ' DarkGray),
            (New-Segment $Adapter.Name White),
            (New-Segment "  [$($Adapter.Status)]" $statusColor),
            (New-Segment "  $($Adapter.InterfaceDescription)" DarkGray)
        ))

    $mode = 'manual'
    if ($State.Identity.Id -eq 'DHCP') { $mode = 'automatic' }
    $lines.Add(@(
            (New-Segment '  Current    ' DarkGray),
            (New-Segment $State.Identity.Name Cyan),
            (New-Segment "  ($mode)" DarkGray)
        ))

    $v4 = Format-ServerList -Static $State.IPv4Static -Active $State.IPv4Active
    $v6 = Format-ServerList -Static $State.IPv6Static -Active $State.IPv6Active -Enabled $State.IPv6Enabled
    foreach ($family in @(@('IPv4', $v4), @('IPv6', $v6))) {
        $segments = @(
            (New-Segment ('    {0}     ' -f $family[0]) DarkGray),
            (New-Segment $family[1].Text)
        )
        if ($family[1].Note) { $segments += New-Segment "  ($($family[1].Note))" DarkGray }
        $lines.Add($segments)
    }

    if ($null -ne $Original) {
        $originalIdentity = Get-DnsIdentity -Addresses (@($Original.IPv4) + @($Original.IPv6))
        $lines.Add(@(
                (New-Segment '  Original   ' DarkGray),
                (New-Segment $originalIdentity.Name Magenta),
                (New-Segment "  (saved $($Original.SavedAt), press R to restore)" DarkGray)
            ))
    }
    else {
        $lines.Add(@(
                (New-Segment '  Original   ' DarkGray),
                (New-Segment 'Same as current' DarkGray),
                (New-Segment '  (not changed by DNS Switcher yet)' DarkGray)
            ))
    }

    $lines.Add(@())
    $lines.Add(@(New-Segment '  Choose DNS servers:' White))
    $lines.Add(@())
    return , $lines.ToArray()
}

function New-MainMenuItems {
    <#
    .SYNOPSIS
        Builds the list of options for the main screen.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $State,

        $Original
    )

    $currentId = $State.Identity.Id
    $items = New-Object -TypeName 'System.Collections.Generic.List[object]'

    $items.Add((New-MenuItem -Key 'DHCP' -Label 'DHCP Default' -Hotkey '1' -Detail 'Automatic, from your router' -IsCurrent:($currentId -eq 'DHCP')))
    foreach ($preset in $script:DnsPresets) {
        $items.Add((New-MenuItem -Key $preset.Id -Label $preset.Name -Hotkey $preset.Hotkey -Detail ($preset.IPv4 -join ', ') -IsCurrent:($currentId -eq $preset.Id)))
    }
    $items.Add((New-MenuItem -Key 'Custom' -Label 'Custom DNS...' -Hotkey '7' -Detail 'Enter your own addresses' -IsCurrent:($currentId -eq 'Custom')))
    $items.Add((New-MenuItem -Separator))

    $restoreDetail = 'Nothing changed yet'
    if ($null -ne $Original) { $restoreDetail = 'Undo all changes on this adapter' }
    $items.Add((New-MenuItem -Key 'Restore' -Label 'Restore original' -Hotkey 'r' -Detail $restoreDetail))
    $items.Add((New-MenuItem -Key 'Adapter' -Label 'Change adapter...' -Hotkey 'a'))
    $items.Add((New-MenuItem -Key 'Quit' -Label 'Quit' -Hotkey 'q'))
    return , $items.ToArray()
}

function Select-NetworkAdapter {
    <#
    .SYNOPSIS
        Lets the user pick a network adapter. Returns the adapter or $null when cancelled.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $Current
    )

    # Connected adapters first, then alphabetical.
    $adapters = @(Get-NetworkAdapter |
            Sort-Object -Property @{ Expression = { $_.Status -ne 'Up' } }, Name)
    if ($adapters.Count -eq 0) {
        Set-Status -Text 'No network adapters were found.' -Color Red
        return $null
    }

    $items = New-Object -TypeName 'System.Collections.Generic.List[object]'
    for ($i = 0; $i -lt $adapters.Count; $i++) {
        $hotkey = ''
        if ($i -lt 9) { $hotkey = [string]($i + 1) }
        $adapter = $adapters[$i]
        $items.Add((New-MenuItem -Key ([string]$adapter.ifIndex) -Label $adapter.Name -Hotkey $hotkey `
                    -Detail ('{0}  {1}' -f $adapter.Status, $adapter.InterfaceDescription) `
                    -IsCurrent:($adapter.ifIndex -eq $Current.ifIndex)))
    }

    $header = New-Object -TypeName 'System.Collections.Generic.List[object]'
    foreach ($line in (New-TitleLines -Subtitle 'Choose a network adapter')) { $header.Add($line) }
    $header.Add(@(New-Segment '  Which adapter should DNS Switcher manage?' White))
    $header.Add(@())

    Set-Status
    $footer = "$($script:Glyph.Up)$($script:Glyph.Down) Move   Enter Select   1-9 Quick pick   Esc Back"
    $choice = Invoke-Menu -Header $header.ToArray() -Items $items.ToArray() -InitialKey ([string]$Current.ifIndex) -Footer $footer
    Reset-Frame

    $selected = $adapters | Where-Object { [string]$_.ifIndex -eq $choice } | Select-Object -First 1
    if ($selected) {
        Set-Status -Text "Now managing adapter ""$($selected.Name)""." -Color Green
    }
    return $selected
}

function Read-InputLine {
    <#
    .SYNOPSIS
        Reads a line of text from the console. Esc (or Ctrl+C) cancels.
    .OUTPUTS
        The text entered, or $null when cancelled.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$Prompt
    )

    Write-Host "  ${Prompt}: " -NoNewline
    $buffer = New-Object -TypeName 'System.Text.StringBuilder'

    while ($true) {
        $keyInfo = [Console]::ReadKey($true)
        $isCtrlC = ($keyInfo.Key -eq [ConsoleKey]::C) -and
                   (($keyInfo.Modifiers -band [ConsoleModifiers]::Control) -ne 0)

        if ($keyInfo.Key -eq [ConsoleKey]::Escape -or $isCtrlC) {
            Write-Host ''
            return $null
        }
        elseif ($keyInfo.Key -eq [ConsoleKey]::Enter) {
            Write-Host ''
            return $buffer.ToString()
        }
        elseif ($keyInfo.Key -eq [ConsoleKey]::Backspace) {
            if ($buffer.Length -gt 0) {
                [void]$buffer.Remove($buffer.Length - 1, 1)
                Write-Host "`b `b" -NoNewline
            }
        }
        elseif (-not [char]::IsControl($keyInfo.KeyChar) -and $buffer.Length -lt 64) {
            [void]$buffer.Append($keyInfo.KeyChar)
            Write-Host $keyInfo.KeyChar -NoNewline -ForegroundColor White
        }
    }
}

function Read-DnsServerField {
    <#
    .SYNOPSIS
        Asks for a single DNS server address until it is valid, skipped or cancelled.
    .OUTPUTS
        An object with Cancelled, Address and Family. Address is $null when skipped.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string]$Prompt,

        [Parameter(Mandatory)]
        [bool]$IPv6Enabled,

        [switch]$Optional,

        [string]$Primary
    )

    while ($true) {
        $answer = Read-InputLine -Prompt $Prompt
        if ($null -eq $answer) {
            return [pscustomobject]@{ Cancelled = $true; Address = $null; Family = $null }
        }

        $answer = $answer.Trim()
        if (-not $answer) {
            if ($Optional) {
                return [pscustomobject]@{ Cancelled = $false; Address = $null; Family = $null }
            }
            Write-Host '  Error: a primary DNS server is required.' -ForegroundColor Red
            continue
        }

        $check = Test-DnsServerAddress -Address $answer
        if (-not $check.IsValid) {
            Write-Host ('  Error: "{0}" {1}' -f $answer, $check.Reason) -ForegroundColor Red
        }
        elseif ($check.Family -eq 'IPv6' -and -not $IPv6Enabled) {
            Write-Host ('  Error: "{0}" is an IPv6 address, but IPv6 is disabled on this adapter.' -f $answer) -ForegroundColor Red
        }
        elseif ($Primary -and $check.Address -eq $Primary) {
            Write-Host '  Error: the secondary server must be different from the primary.' -ForegroundColor Red
        }
        else {
            return [pscustomobject]@{ Cancelled = $false; Address = $check.Address; Family = $check.Family }
        }
    }
}

function Read-CustomDnsServer {
    <#
    .SYNOPSIS
        Asks for a primary and secondary custom DNS server, then for confirmation.
        Esc cancels at any point without changing anything.
    .OUTPUTS
        An object with IPv4 and IPv6 address arrays, or $null when cancelled.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $Adapter,

        [Parameter(Mandatory)]
        $State
    )

    Clear-Host
    Reset-Frame
    [Console]::CursorVisible = $true

    try {
        foreach ($line in (New-TitleLines -Subtitle 'Custom DNS')) {
            foreach ($segment in @($line)) {
                $writeArgs = @{ Object = $segment.Text; NoNewline = $true }
                if ($null -ne $segment.Foreground) { $writeArgs.ForegroundColor = $segment.Foreground }
                if ($null -ne $segment.Background) { $writeArgs.BackgroundColor = $segment.Background }
                Write-Host @writeArgs
            }
            Write-Host ''
        }

        Write-Host '  Enter a primary and a secondary DNS server for ' -NoNewline
        Write-Host $Adapter.Name -ForegroundColor White -NoNewline
        Write-Host '.'
        Write-Host '  Each can be an IPv4 or IPv6 address, e.g. 1.1.1.1 or 2606:4700:4700::1111' -ForegroundColor DarkGray
        Write-Host '  The secondary server is optional; leave it empty and press Enter to skip it.' -ForegroundColor DarkGray
        if (-not $State.IPv6Enabled) {
            Write-Host '  IPv6 is disabled on this adapter, so only IPv4 addresses can be used.' -ForegroundColor Yellow
        }
        Write-Host '  Press Esc at any time to go back without changing anything.' -ForegroundColor DarkGray
        Write-Host ''

        $primary = Read-DnsServerField -Prompt 'Primary DNS server  ' -IPv6Enabled $State.IPv6Enabled
        if ($primary.Cancelled) { return $null }

        $secondary = Read-DnsServerField -Prompt 'Secondary DNS server' -IPv6Enabled $State.IPv6Enabled -Optional -Primary $primary.Address
        if ($secondary.Cancelled) { return $null }

        $ipv4 = New-Object -TypeName 'System.Collections.Generic.List[string]'
        $ipv6 = New-Object -TypeName 'System.Collections.Generic.List[string]'
        foreach ($entry in @($primary, $secondary)) {
            if ($null -eq $entry.Address) { continue }
            if ($entry.Family -eq 'IPv4') { $ipv4.Add($entry.Address) } else { $ipv6.Add($entry.Address) }
        }

        Write-Host ''
        Write-Host '  Apply these DNS servers? ' -NoNewline
        Write-Host 'Enter' -ForegroundColor White -NoNewline
        Write-Host ' Apply   ' -NoNewline
        Write-Host 'Esc' -ForegroundColor White -NoNewline
        Write-Host ' Cancel'
        [Console]::CursorVisible = $false

        while ($true) {
            $keyInfo = [Console]::ReadKey($true)
            $isCtrlC = ($keyInfo.Key -eq [ConsoleKey]::C) -and
                       (($keyInfo.Modifiers -band [ConsoleModifiers]::Control) -ne 0)
            if ($keyInfo.Key -eq [ConsoleKey]::Escape -or $isCtrlC) { return $null }
            if ($keyInfo.Key -eq [ConsoleKey]::Enter) {
                return [pscustomobject]@{ IPv4 = $ipv4.ToArray(); IPv6 = $ipv6.ToArray() }
            }
        }
    }
    finally {
        [Console]::CursorVisible = $false
        Clear-Host
        Reset-Frame
    }
}

#endregion

#region Actions ---------------------------------------------------------------------------------

function Test-SameAddressList {
    <#
    .SYNOPSIS
        Returns $true when two address lists contain the same addresses in the same order.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [string[]]$First = @(),
        [string[]]$Second = @()
    )

    $a = @($First | Where-Object { $_ }) -join ','
    $b = @($Second | Where-Object { $_ }) -join ','
    return ($a -eq $b)
}

function Invoke-DnsChange {
    <#
    .SYNOPSIS
        Switches an adapter to the given servers, saving the original settings first.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $Adapter,

        [Parameter(Mandatory)]
        $State,

        [Parameter(Mandatory)]
        [string]$Name,

        [string[]]$IPv4 = @(),

        [string[]]$IPv6 = @()
    )

    $ipv4List = @($IPv4 | Where-Object { $_ } | ForEach-Object { ConvertTo-NormalizedAddress -Address $_ })
    $ipv6List = @()
    if ($State.IPv6Enabled) {
        $ipv6List = @($IPv6 | Where-Object { $_ } | ForEach-Object { ConvertTo-NormalizedAddress -Address $_ })
    }

    if ((Test-SameAddressList $State.IPv4Static $ipv4List) -and (Test-SameAddressList $State.IPv6Static $ipv6List)) {
        Set-Status -Text "$Name is already in use on ""$($Adapter.Name)""." -Color Cyan
        return
    }

    try {
        Save-OriginalDns -Adapter $Adapter -State $State
        Set-AdapterDnsServer -Adapter $Adapter -IPv4 $ipv4List -IPv6 $ipv6List
        Set-Status -Text "Switched ""$($Adapter.Name)"" to $Name." -Color Green
    }
    catch {
        Set-Status -Text "Could not change DNS: $($_.Exception.Message)" -Color Red
    }
}

function Restore-OriginalDns {
    <#
    .SYNOPSIS
        Restores the DNS settings saved before DNS Switcher made its first change.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $Adapter,

        [Parameter(Mandatory)]
        $State
    )

    $original = Get-OriginalDns -Adapter $Adapter
    if ($null -eq $original) {
        Set-Status -Text "Nothing to restore: DNS on ""$($Adapter.Name)"" has not been changed by $($script:AppName)." -Color Yellow
        return
    }

    $ipv6 = @()
    if ($State.IPv6Enabled) { $ipv6 = @($original.IPv6) }
    $identity = Get-DnsIdentity -Addresses (@($original.IPv4) + @($original.IPv6))

    try {
        Set-AdapterDnsServer -Adapter $Adapter -IPv4 @($original.IPv4) -IPv6 $ipv6
        Remove-OriginalDns -Adapter $Adapter
        Set-Status -Text "Restored the original DNS settings of ""$($Adapter.Name)"" ($($identity.Name))." -Color Green
    }
    catch {
        Set-Status -Text "Could not restore DNS: $($_.Exception.Message)" -Color Red
    }
}

function Start-DnsSwitcher {
    <#
    .SYNOPSIS
        Runs the interactive main loop.
    #>
    [CmdletBinding()]
    param()

    $adapter = Get-PreferredAdapter
    $lastChoice = ''
    $footer = "$($script:Glyph.Up)$($script:Glyph.Down) Move   Enter Select   1-7 Quick pick   R Restore   A Adapter   F5 Refresh   Q Quit"

    while ($true) {
        # Re-read everything each time so the screen always reflects the real configuration.
        $adapter  = Get-NetworkAdapter -InterfaceIndex $adapter.ifIndex | Select-Object -First 1
        if ($null -eq $adapter) {
            $adapter = Get-PreferredAdapter
            Set-Status -Text 'The selected adapter disappeared; switched to the default adapter.' -Color Yellow
        }
        $state    = Get-DnsState -Adapter $adapter
        $original = Get-OriginalDns -Adapter $adapter

        $header = New-MainHeader -Adapter $adapter -State $state -Original $original
        $items  = New-MainMenuItems -State $state -Original $original
        $choice = Invoke-Menu -Header $header -Items $items -InitialKey $lastChoice -Footer $footer
        Set-Status

        if ($choice -eq 'Quit' -or $choice -eq 'Escape') {
            return $adapter
        }
        if ($choice -ne 'Refresh') { $lastChoice = $choice }

        if ($choice -eq 'Refresh') {
            Set-Status -Text 'Refreshed.' -Color DarkGray
        }
        elseif ($choice -eq 'Adapter') {
            $newAdapter = Select-NetworkAdapter -Current $adapter
            if ($null -ne $newAdapter) { $adapter = $newAdapter }
        }
        elseif ($choice -eq 'Restore') {
            Restore-OriginalDns -Adapter $adapter -State $state
        }
        elseif ($choice -eq 'Custom') {
            $custom = Read-CustomDnsServer -Adapter $adapter -State $state
            if ($null -eq $custom) {
                Set-Status -Text 'Custom DNS cancelled. Nothing was changed.' -Color DarkGray
            }
            else {
                $identity = Get-DnsIdentity -Addresses (@($custom.IPv4) + @($custom.IPv6))
                $name = 'custom DNS (' + ((@($custom.IPv4) + @($custom.IPv6)) -join ', ') + ')'
                if ($identity.Id -ne 'Custom') {
                    $name = "$($identity.Name) (recognised from the addresses you entered)"
                }
                Invoke-DnsChange -Adapter $adapter -State $state -Name $name -IPv4 $custom.IPv4 -IPv6 $custom.IPv6
            }
        }
        elseif ($choice -eq 'DHCP') {
            Invoke-DnsChange -Adapter $adapter -State $state -Name 'DHCP Default'
        }
        else {
            $preset = $script:DnsPresets | Where-Object { $_.Id -eq $choice } | Select-Object -First 1
            if ($null -ne $preset) {
                Invoke-DnsChange -Adapter $adapter -State $state -Name $preset.Name -IPv4 $preset.IPv4 -IPv6 $preset.IPv6
            }
        }
    }
}

#endregion

#region Entry point -----------------------------------------------------------------------------

if ($Help) {
    Show-Usage
    exit 0
}

if ($Version) {
    Write-Output "$($script:AppName) $($script:AppVersion)"
    exit 0
}

$exitCode = 0
try {
    Assert-Environment

    if (-not (Test-IsAdministrator)) {
        if ($Elevated) {
            throw 'The script was relaunched for elevation but still has no administrator rights.'
        }
        Write-Host "  $($script:AppName) needs administrator rights to change DNS settings. Requesting elevation..." -ForegroundColor Cyan
        if (Start-ElevatedInstance) {
            Write-Host '  DNS Switcher was opened in a new administrator window.' -ForegroundColor Green
            exit 0
        }
        exit 1
    }

    $script:KnownAddresses = Get-KnownAddressTable

    $originalTitle   = $Host.UI.RawUI.WindowTitle
    $originalCtrlC   = [Console]::TreatControlCAsInput
    $originalCursor  = $true
    try { $originalCursor = [Console]::CursorVisible } catch { Write-Verbose 'Cursor visibility not readable.' }

    try {
        $Host.UI.RawUI.WindowTitle = "$($script:AppName) $($script:AppVersion)"
        [Console]::CursorVisible = $false
        [Console]::TreatControlCAsInput = $true
        Clear-Host

        $finalAdapter = Start-DnsSwitcher
    }
    finally {
        [Console]::TreatControlCAsInput = $originalCtrlC
        [Console]::CursorVisible = $originalCursor
        $Host.UI.RawUI.WindowTitle = $originalTitle
        Clear-Host
    }

    if ($null -ne $finalAdapter) {
        $finalState = Get-DnsState -Adapter $finalAdapter
        Write-Host "  $($script:AppName): " -NoNewline -ForegroundColor DarkGray
        Write-Host $finalAdapter.Name -NoNewline -ForegroundColor White
        Write-Host ' is using ' -NoNewline -ForegroundColor DarkGray
        Write-Host $finalState.Identity.Name -ForegroundColor Cyan
    }
}
catch {
    $exitCode = 1
    Write-Host ''
    Write-Host "  Error: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host ''
    if ($Elevated) {
        # The elevated window would close immediately; give the user a chance to read the error.
        Write-Host '  Press any key to close this window...' -ForegroundColor DarkGray
        try { [void][Console]::ReadKey($true) } catch { Start-Sleep -Seconds 10 }
    }
}
exit $exitCode

#endregion
