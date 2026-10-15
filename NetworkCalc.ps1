<#
.SYNOPSIS
    Interactive IPv4 network (subnet) calculator with a text user interface.

.DESCRIPTION
    NetworkCalc calculates IPv4 subnet details in three ways:

      1. From CIDR notation (for example 192.168.1.10/24).
      2. From an IP address and a subnet mask (dotted, such as 255.255.255.0,
         or a prefix length such as /24).
      3. From an IP address and a required number of hosts. The smallest
         subnet that can hold that many hosts is chosen.

    For each calculation it shows the CIDR notation, network address,
    broadcast address, usable host range, host counts, subnet and wildcard
    masks, the address type (private, public, loopback, ...) and the address
    and mask in binary.

    Run without parameters to start the full-screen interactive calculator.
    Results update live while you type. Keys:

      Tab / Down / Enter    Next input field
      Shift+Tab / Up        Previous input field
      F1, F2, F3            Switch calculator mode
      PgUp / PgDn           Previous / next calculator mode
      Esc                   Clear every field and start over
      Ctrl+Q / Ctrl+C / F10 Quit

    Pass -Cidr, -IPAddress with -SubnetMask, or -IPAddress with -Hosts to run
    a single calculation without the interface. The result is written to the
    pipeline as an object so it can be used by other commands.

    The script has no dependencies and runs in Windows PowerShell 5.1 (which
    ships with Windows 11) and in PowerShell 7+.

.PARAMETER Cidr
    An IPv4 address in CIDR notation, such as 10.20.30.40/22.

.PARAMETER IPAddress
    An IPv4 address in dotted-decimal notation, such as 172.16.5.4. Used with
    -SubnetMask or -Hosts.

.PARAMETER SubnetMask
    A subnet mask in dotted-decimal notation (255.255.240.0) or as a prefix
    length (/20 or 20).

.PARAMETER Hosts
    The number of usable host addresses the subnet must provide.

.EXAMPLE
    .\NetworkCalc.ps1

    Starts the interactive calculator.

.EXAMPLE
    .\NetworkCalc.ps1 -Cidr 192.168.1.10/24

    Calculates the subnet that contains 192.168.1.10 with a /24 prefix.

.EXAMPLE
    .\NetworkCalc.ps1 -IPAddress 10.0.0.5 -SubnetMask 255.255.252.0

    Calculates the subnet from an address and a dotted subnet mask.

.EXAMPLE
    .\NetworkCalc.ps1 -IPAddress 10.0.0.5 -Hosts 500

    Finds the smallest subnet around 10.0.0.5 with at least 500 usable hosts
    (10.0.0.0/23).

.OUTPUTS
    None in interactive mode. Otherwise a PSCustomObject with the subnet
    details.

.NOTES
    /31 networks follow RFC 3021 (two usable addresses, no broadcast) and /32
    networks describe a single host.
#>

#Requires -Version 5.1

[CmdletBinding(DefaultParameterSetName = 'Interactive')]
param(
    [Parameter(Mandatory, Position = 0, ParameterSetName = 'Cidr')]
    [ValidateNotNullOrEmpty()]
    [string]$Cidr,

    [Parameter(Mandatory, ParameterSetName = 'Mask')]
    [Parameter(Mandatory, ParameterSetName = 'Hosts')]
    [ValidateNotNullOrEmpty()]
    [string]$IPAddress,

    [Parameter(Mandatory, ParameterSetName = 'Mask')]
    [ValidateNotNullOrEmpty()]
    [string]$SubnetMask,

    [Parameter(Mandatory, ParameterSetName = 'Hosts')]
    [ValidateRange(1, 4294967294)]
    [long]$Hosts
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# All address arithmetic uses [long] (Int64) so that the full unsigned 32-bit
# range fits without sign problems in both Windows PowerShell and PowerShell 7.
$script:MaxIPv4 = [long]4294967295

#region Calculation functions

function ConvertTo-IPv4Integer {
    <#
    .SYNOPSIS
        Parses a dotted-decimal IPv4 string into its 32-bit numeric value.
    .DESCRIPTION
        Parsing is strict: exactly four decimal octets, each 0-255. The error
        messages are written to help someone who is still typing, so partial
        input such as "192.168." reports that the address is incomplete.
    .PARAMETER Address
        The text to parse.
    .PARAMETER Name
        What the value represents, used in error messages.
    #>
    [CmdletBinding()]
    [OutputType([long])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Address,

        [string]$Name = 'IP address'
    )

    $text = $Address.Trim()
    if ($text.Length -eq 0) {
        throw "The $Name is empty."
    }
    if ($text -notmatch '^[0-9.]+$') {
        throw "The $Name may only contain digits and dots."
    }

    $octets = $text.Split('.')
    if ($octets.Count -gt 4) {
        throw "Too many octets in the $Name - IPv4 uses exactly four (a.b.c.d)."
    }
    foreach ($octet in $octets) {
        if ($octet.Length -gt 3) {
            throw "Octet '$octet' in the $Name is too long."
        }
    }
    if ($octets.Count -lt 4 -or $octets -contains '') {
        throw "Incomplete $Name - expected four octets (a.b.c.d)."
    }

    $value = [long]0
    foreach ($octet in $octets) {
        $number = [int]$octet
        if ($number -gt 255) {
            throw "Octet '$octet' in the $Name is out of range (0-255)."
        }
        $value = ($value -shl 8) -bor $number
    }
    $value
}

function ConvertTo-IPv4String {
    <#
    .SYNOPSIS
        Formats a 32-bit numeric IPv4 value as dotted-decimal text.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [long]$Value
    )

    '{0}.{1}.{2}.{3}' -f (($Value -shr 24) -band 255), (($Value -shr 16) -band 255),
        (($Value -shr 8) -band 255), ($Value -band 255)
}

function ConvertTo-IPv4Binary {
    <#
    .SYNOPSIS
        Formats a 32-bit numeric IPv4 value as dotted binary text.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [long]$Value
    )

    $bits = [Convert]::ToString($Value, 2).PadLeft(32, '0')
    '{0}.{1}.{2}.{3}' -f $bits.Substring(0, 8), $bits.Substring(8, 8),
        $bits.Substring(16, 8), $bits.Substring(24, 8)
}

function Get-SubnetMaskValue {
    <#
    .SYNOPSIS
        Returns the numeric subnet mask for a prefix length (0-32).
    #>
    [CmdletBinding()]
    [OutputType([long])]
    param(
        [Parameter(Mandatory)]
        [ValidateRange(0, 32)]
        [int]$PrefixLength
    )

    # The host part is the low (32 - prefix) bits; the mask is everything else.
    $hostBits = [long][Math]::Pow(2, 32 - $PrefixLength) - 1
    $script:MaxIPv4 -bxor $hostBits
}

function ConvertTo-PrefixLength {
    <#
    .SYNOPSIS
        Converts a subnet mask (255.255.255.0) or prefix (/24 or 24) into a
        prefix length.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$SubnetMask
    )

    $text = $SubnetMask.Trim()
    if ($text -match '^/?(\d{1,2})$') {
        $prefix = [int]$Matches[1]
        if ($prefix -gt 32) {
            throw 'The prefix length must be between 0 and 32.'
        }
        return $prefix
    }
    if ($text -eq '/') {
        throw "Enter a prefix length (0-32) after the '/'."
    }
    if ($text.StartsWith('/') -or $text -notmatch '\.') {
        throw 'The prefix length must be between 0 and 32.'
    }

    $mask = ConvertTo-IPv4Integer -Address $text -Name 'subnet mask'

    # A valid mask is a run of 1 bits followed by a run of 0 bits. Inverted,
    # it becomes 2^n - 1, and x -band (x + 1) is zero only for such values.
    $inverted = $script:MaxIPv4 -bxor $mask
    if (($inverted -band ($inverted + 1)) -ne 0) {
        throw "'$text' is not a valid subnet mask - its 1 bits must be contiguous."
    }
    ([Convert]::ToString($mask, 2) -replace '0', '').Length
}

function ConvertFrom-CidrNotation {
    <#
    .SYNOPSIS
        Splits CIDR notation (a.b.c.d/n) into a numeric address and prefix.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Cidr
    )

    $parts = $Cidr.Trim().Split('/')
    if ($parts.Count -gt 2) {
        throw "CIDR notation contains only one '/'."
    }

    $address = ConvertTo-IPv4Integer -Address $parts[0]
    if ($parts.Count -eq 1 -or $parts[1].Length -eq 0) {
        throw "Add a prefix length after the address, e.g. /24 (0-32)."
    }
    if ($parts[1] -notmatch '^\d{1,2}$' -or [int]$parts[1] -gt 32) {
        throw 'The prefix length must be between 0 and 32.'
    }

    @{
        Address      = $address
        PrefixLength = [int]$parts[1]
    }
}

function Get-UsableHostCount {
    <#
    .SYNOPSIS
        Returns the number of usable host addresses for a prefix length.
    .DESCRIPTION
        Normally the network and broadcast addresses are unusable. A /31 is a
        point-to-point link with two usable addresses (RFC 3021) and a /32 is
        a single host.
    #>
    [CmdletBinding()]
    [OutputType([long])]
    param(
        [Parameter(Mandatory)]
        [ValidateRange(0, 32)]
        [int]$PrefixLength
    )

    switch ($PrefixLength) {
        32 { return [long]1 }
        31 { return [long]2 }
        default { return [long][Math]::Pow(2, 32 - $PrefixLength) - 2 }
    }
}

function Get-PrefixFromHostCount {
    <#
    .SYNOPSIS
        Returns the longest prefix (smallest subnet) that provides at least
        the requested number of usable hosts.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)]
        [long]$HostCount
    )

    if ($HostCount -lt 1) {
        throw 'The number of hosts must be at least 1.'
    }
    $maximum = Get-UsableHostCount -PrefixLength 0
    if ($HostCount -gt $maximum) {
        throw ('The number of hosts cannot exceed {0:N0}.' -f $maximum)
    }

    for ($prefix = 32; $prefix -ge 0; $prefix--) {
        if ((Get-UsableHostCount -PrefixLength $prefix) -ge $HostCount) {
            return $prefix
        }
    }
}

function Get-IPv4AddressType {
    <#
    .SYNOPSIS
        Describes the special-purpose block (RFC 6890) an address belongs to,
        or "Public" when it is not in one.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [long]$Address
    )

    # Most specific entries first: 255.255.255.255 lies inside 240.0.0.0/4.
    $blocks = @(
        @{ Network = '255.255.255.255'; Prefix = 32; Name = 'Limited broadcast' }
        @{ Network = '0.0.0.0'; Prefix = 8; Name = '"This" network (RFC 1122)' }
        @{ Network = '10.0.0.0'; Prefix = 8; Name = 'Private (RFC 1918)' }
        @{ Network = '100.64.0.0'; Prefix = 10; Name = 'Shared / carrier-grade NAT (RFC 6598)' }
        @{ Network = '127.0.0.0'; Prefix = 8; Name = 'Loopback' }
        @{ Network = '169.254.0.0'; Prefix = 16; Name = 'Link-local / APIPA (RFC 3927)' }
        @{ Network = '172.16.0.0'; Prefix = 12; Name = 'Private (RFC 1918)' }
        @{ Network = '192.0.0.0'; Prefix = 24; Name = 'IETF protocol assignments' }
        @{ Network = '192.0.2.0'; Prefix = 24; Name = 'Documentation (TEST-NET-1)' }
        @{ Network = '192.168.0.0'; Prefix = 16; Name = 'Private (RFC 1918)' }
        @{ Network = '198.18.0.0'; Prefix = 15; Name = 'Benchmarking (RFC 2544)' }
        @{ Network = '198.51.100.0'; Prefix = 24; Name = 'Documentation (TEST-NET-2)' }
        @{ Network = '203.0.113.0'; Prefix = 24; Name = 'Documentation (TEST-NET-3)' }
        @{ Network = '224.0.0.0'; Prefix = 4; Name = 'Multicast' }
        @{ Network = '240.0.0.0'; Prefix = 4; Name = 'Reserved (future use)' }
    )

    foreach ($block in $blocks) {
        $mask = Get-SubnetMaskValue -PrefixLength $block.Prefix
        if (($Address -band $mask) -eq (ConvertTo-IPv4Integer -Address $block.Network)) {
            return $block.Name
        }
    }
    'Public'
}

function Get-SubnetInfo {
    <#
    .SYNOPSIS
        Calculates every subnet detail for an address and prefix length.
    .PARAMETER Address
        Any address inside the subnet, as a numeric value.
    .PARAMETER PrefixLength
        The prefix length (0-32).
    .PARAMETER RequestedHosts
        The host count the subnet was sized for, if any. Recorded in the
        output only.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [long]$Address,

        [Parameter(Mandatory)]
        [ValidateRange(0, 32)]
        [int]$PrefixLength,

        [long]$RequestedHosts = 0
    )

    $mask = Get-SubnetMaskValue -PrefixLength $PrefixLength
    $wildcard = $script:MaxIPv4 -bxor $mask
    $network = $Address -band $mask
    $broadcast = $network -bor $wildcard

    if ($PrefixLength -ge 31) {
        # /31 and /32 have no network or broadcast address to reserve.
        $firstUsable = $network
        $lastUsable = $broadcast
        $broadcastText = $null
    }
    else {
        $firstUsable = $network + 1
        $lastUsable = $broadcast - 1
        $broadcastText = ConvertTo-IPv4String -Value $broadcast
    }

    $requested = $null
    if ($RequestedHosts -gt 0) {
        $requested = $RequestedHosts
    }

    [pscustomobject]@{
        IPAddress        = ConvertTo-IPv4String -Value $Address
        CIDR             = '{0}/{1}' -f (ConvertTo-IPv4String -Value $network), $PrefixLength
        PrefixLength     = $PrefixLength
        NetworkAddress   = ConvertTo-IPv4String -Value $network
        BroadcastAddress = $broadcastText
        FirstUsable      = ConvertTo-IPv4String -Value $firstUsable
        LastUsable       = ConvertTo-IPv4String -Value $lastUsable
        UsableHosts      = Get-UsableHostCount -PrefixLength $PrefixLength
        TotalAddresses   = $wildcard + 1
        SubnetMask       = ConvertTo-IPv4String -Value $mask
        WildcardMask     = ConvertTo-IPv4String -Value $wildcard
        AddressType      = Get-IPv4AddressType -Address $Address
        RequestedHosts   = $requested
        BinaryAddress    = ConvertTo-IPv4Binary -Value $Address
        BinaryMask       = ConvertTo-IPv4Binary -Value $mask
    }
}

#endregion

#region Text user interface

# Screen geometry. Rows are relative to the top of the drawn frame.
$script:TuiWidth = 78
$script:TuiHeight = 25
$script:TuiLeft = 0
$script:TuiTop = 0
$script:FieldLabelWidth = 17
$script:FieldBoxWidth = 19
$script:ResultLabelWidth = 19
$script:FirstFieldRow = 4

# Box-drawing characters are built from code points so the script file stays
# pure ASCII; Windows PowerShell 5.1 misreads non-ASCII in files without a BOM.
# Only single-width glyphs are used (arrows, for example, can render two cells
# wide in some console fonts and would break the frame).
$script:Box = @{
    Horizontal  = [string][char]0x2500
    Vertical    = [string][char]0x2502
    TopLeft     = [string][char]0x250C
    TopRight    = [string][char]0x2510
    BottomLeft  = [string][char]0x2514
    BottomRight = [string][char]0x2518
    TeeLeft     = [string][char]0x251C
    TeeRight    = [string][char]0x2524
}

$script:Theme = @{
    Border      = [ConsoleColor]::DarkCyan
    Title       = [ConsoleColor]::Cyan
    TabActiveFg = [ConsoleColor]::Black
    TabActiveBg = [ConsoleColor]::Cyan
    TabIdle     = [ConsoleColor]::Gray
    Label       = [ConsoleColor]::Gray
    LabelFocus  = [ConsoleColor]::White
    Value       = [ConsoleColor]::White
    KeyValue    = [ConsoleColor]::Green
    Dim         = [ConsoleColor]::DarkGray
    FieldText   = [ConsoleColor]::White
    FieldError  = [ConsoleColor]::Yellow
    FieldFocus  = [ConsoleColor]::DarkBlue
    FieldIdle   = [ConsoleColor]::DarkGray
    Hint        = [ConsoleColor]::DarkGray
    Error       = [ConsoleColor]::Yellow
    Ok          = [ConsoleColor]::Green
    NetworkBits = [ConsoleColor]::Cyan
    HostBits    = [ConsoleColor]::Yellow
    HelpKey     = [ConsoleColor]::Cyan
    HelpText    = [ConsoleColor]::Gray
}

function Initialize-TuiState {
    <#
    .SYNOPSIS
        Creates the interface state: the three modes and their input fields.
    .DESCRIPTION
        Each field records its text, caret position, maximum length and a
        regular expression for the characters it accepts. Each mode keeps its
        own fields and focus, so switching modes does not lose input.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()

    $ipField = {
        @{ Label = 'IP address'; Text = ''; Caret = 0; Max = 15; Allowed = '^[0-9.]$'; Example = 'e.g. 192.168.1.10' }
    }

    @{
        ModeIndex = 0
        Modes     = @(
            @{
                Name   = 'CIDR'
                Key    = 'F1'
                Focus  = 0
                Fields = @(
                    @{ Label = 'CIDR notation'; Text = ''; Caret = 0; Max = 18; Allowed = '^[0-9./]$'; Example = 'e.g. 192.168.1.10/24' }
                )
            }
            @{
                Name   = 'IP + Subnet mask'
                Key    = 'F2'
                Focus  = 0
                Fields = @(
                    (& $ipField)
                    @{ Label = 'Subnet mask'; Text = ''; Caret = 0; Max = 15; Allowed = '^[0-9./]$'; Example = 'e.g. 255.255.255.0 or /24' }
                )
            }
            @{
                Name   = 'IP + Host count'
                Key    = 'F3'
                Focus  = 0
                Fields = @(
                    (& $ipField)
                    @{ Label = 'Number of hosts'; Text = ''; Caret = 0; Max = 10; Allowed = '^[0-9]$'; Example = 'e.g. 50' }
                )
            }
        )
    }
}

function Get-TuiResult {
    <#
    .SYNOPSIS
        Evaluates the fields of a mode and returns the subnet details plus a
        status message for the interface.
    .OUTPUTS
        A hashtable: Info (subnet object or $null), Message, Level ('Hint',
        'Error' or 'Ok') and ErrorField (index of the invalid field or -1).
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [int]$ModeIndex,

        [Parameter(Mandatory)]
        [hashtable[]]$Fields
    )

    $result = @{ Info = $null; Message = ''; Level = 'Hint'; ErrorField = -1 }
    $texts = @($Fields | ForEach-Object { $_.Text.Trim() })
    $current = 0

    try {
        switch ($ModeIndex) {
            0 {
                if (-not $texts[0]) {
                    $result.Message = 'Type an IPv4 address in CIDR notation, e.g. 192.168.1.10/24.'
                    return $result
                }
                $parsed = ConvertFrom-CidrNotation -Cidr $texts[0]
                $result.Info = Get-SubnetInfo -Address $parsed.Address -PrefixLength $parsed.PrefixLength
            }
            1 {
                # Validate whatever has been typed so far, then ask for the rest.
                $address = $null
                $prefix = $null
                if ($texts[0]) {
                    $current = 0
                    $address = ConvertTo-IPv4Integer -Address $texts[0]
                }
                if ($texts[1]) {
                    $current = 1
                    $prefix = ConvertTo-PrefixLength -SubnetMask $texts[1]
                }
                if ($null -eq $address) {
                    $result.Message = 'Enter an IP address, e.g. 192.168.1.10.'
                    return $result
                }
                if ($null -eq $prefix) {
                    $result.Message = 'Now enter a subnet mask (255.255.255.0) or a prefix length (/24).'
                    return $result
                }
                $result.Info = Get-SubnetInfo -Address $address -PrefixLength $prefix
            }
            2 {
                $address = $null
                $hostCount = $null
                $prefix = $null
                if ($texts[0]) {
                    $current = 0
                    $address = ConvertTo-IPv4Integer -Address $texts[0]
                }
                if ($texts[1]) {
                    $current = 1
                    $hostCount = [long]$texts[1]
                    $prefix = Get-PrefixFromHostCount -HostCount $hostCount
                }
                if ($null -eq $address) {
                    $result.Message = 'Enter an IP address, e.g. 192.168.1.10.'
                    return $result
                }
                if ($null -eq $prefix) {
                    $result.Message = 'Now enter how many hosts the subnet needs.'
                    return $result
                }
                $result.Info = Get-SubnetInfo -Address $address -PrefixLength $prefix -RequestedHosts $hostCount
            }
        }
    }
    catch {
        $result.Info = $null
        $result.Level = 'Error'
        $result.Message = $_.Exception.Message
        $result.ErrorField = $current
        return $result
    }

    $info = $result.Info
    $result.Level = 'Ok'
    if ($ModeIndex -eq 2) {
        $result.Message = 'Smallest subnet for {0:N0} host(s) is /{1} with {2:N0} usable.' -f
            $info.RequestedHosts, $info.PrefixLength, $info.UsableHosts
    }
    else {
        $result.Message = '{0} has {1:N0} usable host address(es).' -f $info.CIDR, $info.UsableHosts
    }
    $result
}

function New-TuiSegment {
    <#
    .SYNOPSIS
        Describes a run of text drawn in one color combination.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Creates an in-memory object only.')]
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [string]$Text = '',
        [object]$Foreground = $null,
        [object]$Background = $null
    )

    @{ Text = $Text; Foreground = $Foreground; Background = $Background }
}

function Write-TuiText {
    <#
    .SYNOPSIS
        Writes text at the cursor in the given colors. $null colors mean the
        console default.
    #>
    [CmdletBinding()]
    param(
        [string]$Text,
        [object]$Foreground = $null,
        [object]$Background = $null
    )

    [Console]::ResetColor()
    if ($null -ne $Foreground) { [Console]::ForegroundColor = $Foreground }
    if ($null -ne $Background) { [Console]::BackgroundColor = $Background }
    [Console]::Write($Text)
}

function Write-TuiRow {
    <#
    .SYNOPSIS
        Draws one framed row of the interface, padding (or truncating) the
        segments so the row always covers its full width. Overwriting rows in
        place, rather than clearing the screen, keeps redraws flicker-free.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [int]$Row,

        [object[]]$Segments = @()
    )

    $inner = $script:TuiWidth - 4
    [Console]::SetCursorPosition($script:TuiLeft, $script:TuiTop + $Row)
    Write-TuiText -Text ($script:Box.Vertical + ' ') -Foreground $script:Theme.Border

    $used = 0
    foreach ($segment in $Segments) {
        $remaining = $inner - $used
        if ($remaining -le 0) { break }
        $text = [string]$segment.Text
        if ($text.Length -gt $remaining) {
            $text = $text.Substring(0, $remaining)
        }
        Write-TuiText -Text $text -Foreground $segment.Foreground -Background $segment.Background
        $used += $text.Length
    }
    if ($used -lt $inner) {
        Write-TuiText -Text (' ' * ($inner - $used))
    }

    Write-TuiText -Text (' ' + $script:Box.Vertical) -Foreground $script:Theme.Border
}

function Write-TuiBorder {
    <#
    .SYNOPSIS
        Draws a horizontal frame line with optional embedded title.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [int]$Row,

        [Parameter(Mandatory)]
        [string]$Left,

        [Parameter(Mandatory)]
        [string]$Right,

        [string]$Title = ''
    )

    [Console]::SetCursorPosition($script:TuiLeft, $script:TuiTop + $Row)
    $fill = $script:TuiWidth - 2
    if ($Title) {
        $lead = $script:Box.Horizontal + ' '
        $label = $Title + ' '
        $rest = $fill - $lead.Length - $label.Length
        Write-TuiText -Text ($Left + $lead) -Foreground $script:Theme.Border
        Write-TuiText -Text $label -Foreground $script:Theme.Title
        Write-TuiText -Text (($script:Box.Horizontal * $rest) + $Right) -Foreground $script:Theme.Border
    }
    else {
        Write-TuiText -Text ($Left + ($script:Box.Horizontal * $fill) + $Right) -Foreground $script:Theme.Border
    }
}

function Get-TuiBinarySegments {
    <#
    .SYNOPSIS
        Splits a dotted binary string into network bits and host bits so they
        can be drawn in different colors.
    #>
    [CmdletBinding()]
    [OutputType([hashtable[]])]
    param(
        [Parameter(Mandatory)]
        [string]$Binary,

        [Parameter(Mandatory)]
        [int]$PrefixLength
    )

    # Bit n sits at string index n + (number of dots before it).
    $split = 0
    if ($PrefixLength -gt 0) {
        $split = $PrefixLength + [Math]::Floor(($PrefixLength - 1) / 8)
    }
    @(
        New-TuiSegment -Text $Binary.Substring(0, $split) -Foreground $script:Theme.NetworkBits
        New-TuiSegment -Text $Binary.Substring($split) -Foreground $script:Theme.HostBits
    )
}

function Write-TuiResultRow {
    <#
    .SYNOPSIS
        Draws one "label  value" line of the results panel.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [int]$Row,

        [string]$Label = '',

        [object[]]$Value = @()
    )

    $segments = @(New-TuiSegment -Text ('  ' + $Label.PadRight($script:ResultLabelWidth)) -Foreground $script:Theme.Label)
    Write-TuiRow -Row $Row -Segments ($segments + $Value)
}

function Show-TuiScreen {
    <#
    .SYNOPSIS
        Draws the complete interface for the current state and places the
        cursor in the focused input field.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable]$State
    )

    $theme = $script:Theme
    $box = $script:Box
    $mode = $State.Modes[$State.ModeIndex]
    $result = Get-TuiResult -ModeIndex $State.ModeIndex -Fields $mode.Fields
    $info = $result.Info

    [Console]::CursorVisible = $false

    # Title and mode tabs.
    Write-TuiBorder -Row 0 -Left $box.TopLeft -Right $box.TopRight -Title 'NetworkCalc - IPv4 Subnet Calculator'
    $tabs = @()
    for ($i = 0; $i -lt $State.Modes.Count; $i++) {
        $tab = ' {0} {1} ' -f $State.Modes[$i].Key, $State.Modes[$i].Name
        if ($i -eq $State.ModeIndex) {
            $tabs += New-TuiSegment -Text $tab -Foreground $theme.TabActiveFg -Background $theme.TabActiveBg
        }
        else {
            $tabs += New-TuiSegment -Text $tab -Foreground $theme.TabIdle
        }
        $tabs += New-TuiSegment -Text '  '
    }
    Write-TuiRow -Row 1 -Segments $tabs
    Write-TuiBorder -Row 2 -Left $box.TeeLeft -Right $box.TeeRight

    # Input fields (always two rows so the layout never shifts).
    Write-TuiRow -Row 3
    for ($i = 0; $i -lt 2; $i++) {
        $row = $script:FirstFieldRow + $i
        if ($i -ge $mode.Fields.Count) {
            Write-TuiRow -Row $row
            continue
        }
        $field = $mode.Fields[$i]
        $focused = $i -eq $mode.Focus
        $labelColor = if ($focused) { $theme.LabelFocus } else { $theme.Label }
        $fieldBack = if ($focused) { $theme.FieldFocus } else { $theme.FieldIdle }
        $fieldFore = if ($i -eq $result.ErrorField) { $theme.FieldError } else { $theme.FieldText }
        Write-TuiRow -Row $row -Segments @(
            New-TuiSegment -Text $field.Label.PadRight($script:FieldLabelWidth) -Foreground $labelColor
            New-TuiSegment -Text ' '
            New-TuiSegment -Text $field.Text.PadRight($script:FieldBoxWidth) -Foreground $fieldFore -Background $fieldBack
            New-TuiSegment -Text '  '
            New-TuiSegment -Text $field.Example -Foreground $theme.Hint
        )
    }
    Write-TuiRow -Row 6

    # Status line.
    $statusColor = switch ($result.Level) {
        'Error' { $theme.Error }
        'Ok' { $theme.Ok }
        default { $theme.Hint }
    }
    Write-TuiRow -Row 7 -Segments @(New-TuiSegment -Text $result.Message -Foreground $statusColor)

    # Results panel. Without a valid result every value shows as a dash.
    Write-TuiBorder -Row 8 -Left $box.TeeLeft -Right $box.TeeRight -Title 'Results'
    $dash = @(New-TuiSegment -Text '-' -Foreground $theme.Dim)
    $rows = [System.Collections.Generic.List[object]]::new()
    if ($null -eq $info) {
        foreach ($label in 'IP address', 'Address type', 'CIDR notation', 'Subnet mask', 'Wildcard mask',
            'Network address', 'Broadcast address', 'Usable host range', 'Usable hosts', 'Total addresses') {
            $rows.Add(@($label, $dash))
        }
        $rows.Add(@('', @()))
        $rows.Add(@('Binary address', $dash))
        $rows.Add(@('Binary mask', $dash))
    }
    else {
        $broadcast = if ($null -ne $info.BroadcastAddress) {
            @(New-TuiSegment -Text $info.BroadcastAddress -Foreground $theme.KeyValue)
        }
        elseif ($info.PrefixLength -eq 31) {
            @(New-TuiSegment -Text 'none (/31 point-to-point link, RFC 3021)' -Foreground $theme.Dim)
        }
        else {
            @(New-TuiSegment -Text 'none (/32 single host)' -Foreground $theme.Dim)
        }
        $requested = @()
        $requestedLabel = ''
        if ($null -ne $info.RequestedHosts) {
            $requestedLabel = 'Requested hosts'
            $requested = @(
                New-TuiSegment -Text ('{0:N0}' -f $info.RequestedHosts) -Foreground $theme.Value
                New-TuiSegment -Text ('  ({0:N0} spare)' -f ($info.UsableHosts - $info.RequestedHosts)) -Foreground $theme.Dim
            )
        }
        $rows.Add(@('IP address', @(New-TuiSegment -Text $info.IPAddress -Foreground $theme.Value)))
        $rows.Add(@('Address type', @(New-TuiSegment -Text $info.AddressType -Foreground $theme.Value)))
        $rows.Add(@('CIDR notation', @(New-TuiSegment -Text $info.CIDR -Foreground $theme.KeyValue)))
        $rows.Add(@('Subnet mask', @(New-TuiSegment -Text $info.SubnetMask -Foreground $theme.Value)))
        $rows.Add(@('Wildcard mask', @(New-TuiSegment -Text $info.WildcardMask -Foreground $theme.Value)))
        $rows.Add(@('Network address', @(New-TuiSegment -Text $info.NetworkAddress -Foreground $theme.KeyValue)))
        $rows.Add(@('Broadcast address', $broadcast))
        $rows.Add(@('Usable host range', @(New-TuiSegment -Text ('{0} - {1}' -f $info.FirstUsable, $info.LastUsable) -Foreground $theme.KeyValue)))
        $rows.Add(@('Usable hosts', @(New-TuiSegment -Text ('{0:N0}' -f $info.UsableHosts) -Foreground $theme.Value)))
        $rows.Add(@('Total addresses', @(New-TuiSegment -Text ('{0:N0}' -f $info.TotalAddresses) -Foreground $theme.Value)))
        $rows.Add(@($requestedLabel, $requested))
        $rows.Add(@('Binary address', (Get-TuiBinarySegments -Binary $info.BinaryAddress -PrefixLength $info.PrefixLength)))
        $rows.Add(@('Binary mask', (Get-TuiBinarySegments -Binary $info.BinaryMask -PrefixLength $info.PrefixLength)))
    }
    for ($i = 0; $i -lt $rows.Count; $i++) {
        Write-TuiResultRow -Row (9 + $i) -Label $rows[$i][0] -Value $rows[$i][1]
    }

    # Key help and bottom frame.
    Write-TuiBorder -Row 22 -Left $box.TeeLeft -Right $box.TeeRight
    $help = @()
    foreach ($pair in @(
            @('Tab/Up/Down', 'Field'),
            @('F1-F3/PgUp/PgDn', 'Mode'),
            @('Esc', 'Clear all'),
            @('Ctrl+Q', 'Quit'))) {
        $help += New-TuiSegment -Text $pair[0] -Foreground $theme.HelpKey
        $help += New-TuiSegment -Text (' ' + $pair[1] + '   ') -Foreground $theme.HelpText
    }
    Write-TuiRow -Row 23 -Segments $help
    Write-TuiBorder -Row 24 -Left $box.BottomLeft -Right $box.BottomRight

    # Put the blinking cursor at the caret of the focused field.
    [Console]::ResetColor()
    $caretColumn = $script:TuiLeft + 2 + $script:FieldLabelWidth + 1 + $mode.Fields[$mode.Focus].Caret
    [Console]::SetCursorPosition($caretColumn, $script:TuiTop + $script:FirstFieldRow + $mode.Focus)
    [Console]::CursorVisible = $true
}

function Show-TuiTooSmall {
    <#
    .SYNOPSIS
        Shows a notice when the console window cannot fit the interface.
    #>
    [CmdletBinding()]
    param()

    $message = 'NetworkCalc needs a window of at least {0}x{1} (currently {2}x{3}). Enlarge the window or press Ctrl+Q to quit.' -f
        ($script:TuiWidth + 2), ($script:TuiHeight + 1), [Console]::WindowWidth, [Console]::WindowHeight
    $width = [Math]::Max(1, [Console]::WindowWidth - 1)
    [Console]::CursorVisible = $false
    [Console]::ResetColor()
    [Console]::SetCursorPosition(0, [Console]::WindowTop)
    for ($start = 0; $start -lt $message.Length; $start += $width) {
        [Console]::WriteLine($message.Substring($start, [Math]::Min($width, $message.Length - $start)))
    }
}

function Clear-TuiField {
    <#
    .SYNOPSIS
        Empties every input field in every mode and focuses the first field.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable]$State
    )

    foreach ($mode in $State.Modes) {
        $mode.Focus = 0
        foreach ($field in $mode.Fields) {
            $field.Text = ''
            $field.Caret = 0
        }
    }
}

function Invoke-TuiKeyPress {
    <#
    .SYNOPSIS
        Applies one key press to the interface state.
    .OUTPUTS
        $false when the user asked to quit, otherwise $true.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [hashtable]$State,

        [Parameter(Mandatory)]
        [ConsoleKeyInfo]$Key
    )

    $mode = $State.Modes[$State.ModeIndex]
    $field = $mode.Fields[$mode.Focus]
    $fieldCount = $mode.Fields.Count
    $modeCount = $State.Modes.Count
    $control = ($Key.Modifiers -band [ConsoleModifiers]::Control) -ne 0
    $shift = ($Key.Modifiers -band [ConsoleModifiers]::Shift) -ne 0

    if ($control -and ($Key.Key -eq [ConsoleKey]::Q -or $Key.Key -eq [ConsoleKey]::C)) {
        return $false
    }

    switch ($Key.Key) {
        'F10' { return $false }
        'Escape' { Clear-TuiField -State $State }
        'F1' { $State.ModeIndex = 0 }
        'F2' { $State.ModeIndex = 1 }
        'F3' { $State.ModeIndex = 2 }
        'PageDown' { $State.ModeIndex = ($State.ModeIndex + 1) % $modeCount }
        'PageUp' { $State.ModeIndex = ($State.ModeIndex + $modeCount - 1) % $modeCount }
        'Tab' {
            $step = if ($shift) { $fieldCount - 1 } else { 1 }
            $mode.Focus = ($mode.Focus + $step) % $fieldCount
        }
        { $_ -in 'DownArrow', 'Enter' } { $mode.Focus = ($mode.Focus + 1) % $fieldCount }
        'UpArrow' { $mode.Focus = ($mode.Focus + $fieldCount - 1) % $fieldCount }
        'LeftArrow' { $field.Caret = [Math]::Max(0, $field.Caret - 1) }
        'RightArrow' { $field.Caret = [Math]::Min($field.Text.Length, $field.Caret + 1) }
        'Home' { $field.Caret = 0 }
        'End' { $field.Caret = $field.Text.Length }
        'Backspace' {
            if ($field.Caret -gt 0) {
                $field.Text = $field.Text.Remove($field.Caret - 1, 1)
                $field.Caret--
            }
        }
        'Delete' {
            if ($field.Caret -lt $field.Text.Length) {
                $field.Text = $field.Text.Remove($field.Caret, 1)
            }
        }
        default {
            # Printable input: keep only characters the field accepts.
            $char = [string]$Key.KeyChar
            if (-not $control -and $char -match $field.Allowed -and $field.Text.Length -lt $field.Max) {
                $field.Text = $field.Text.Insert($field.Caret, $char)
                $field.Caret++
            }
        }
    }
    $true
}

function Test-VirtualTerminal {
    <#
    .SYNOPSIS
        Returns $true when the host understands VT escape sequences.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    try {
        [bool]$Host.UI.SupportsVirtualTerminal
    }
    catch {
        $false
    }
}

function Invoke-NetworkCalcTui {
    <#
    .SYNOPSIS
        Runs the interactive calculator until the user quits.
    .DESCRIPTION
        Uses the alternate screen buffer when available so the user's console
        contents are restored on exit. Keys are polled rather than awaited so
        the screen can be redrawn when the window is resized.
    #>
    [CmdletBinding()]
    param()

    if ([Console]::IsInputRedirected -or [Console]::IsOutputRedirected -or $Host.Name -eq 'Windows PowerShell ISE Host') {
        throw 'The interactive calculator needs a console window. Use -Cidr, -SubnetMask or -Hosts for non-interactive use.'
    }

    $state = Initialize-TuiState
    $escape = [char]27
    $useAlternateBuffer = Test-VirtualTerminal
    $originalTreatControlC = [Console]::TreatControlCAsInput
    $originalTitle = $null
    try { $originalTitle = $Host.UI.RawUI.WindowTitle } catch { $originalTitle = $null }

    try {
        if ($useAlternateBuffer) {
            [Console]::Write("$escape[?1049h")
        }
        # Handle Ctrl+C as a key so the console is always restored on exit.
        [Console]::TreatControlCAsInput = $true
        try { $Host.UI.RawUI.WindowTitle = 'NetworkCalc' } catch { Write-Verbose 'Window title could not be set.' }

        $lastWidth = -1
        $lastHeight = -1
        $redraw = $true
        $running = $true
        while ($running) {
            $width = [Console]::WindowWidth
            $height = [Console]::WindowHeight
            $fits = $width -ge ($script:TuiWidth + 2) -and $height -ge ($script:TuiHeight + 1)
            if ($width -ne $lastWidth -or $height -ne $lastHeight) {
                $lastWidth = $width
                $lastHeight = $height
                [Console]::ResetColor()
                [Console]::Clear()
                $script:TuiTop = [Console]::WindowTop
                $script:TuiLeft = [Math]::Max(0, [int][Math]::Floor(($width - $script:TuiWidth) / 2))
                $redraw = $true
            }

            if ($redraw) {
                if ($fits) { Show-TuiScreen -State $state } else { Show-TuiTooSmall }
                $redraw = $false
            }

            if (-not [Console]::KeyAvailable) {
                Start-Sleep -Milliseconds 25
                continue
            }

            # Drain every pending key (fast typing or a paste) before redrawing.
            while ($running -and [Console]::KeyAvailable) {
                $running = Invoke-TuiKeyPress -State $state -Key ([Console]::ReadKey($true))
            }
            $redraw = $true
        }
    }
    finally {
        [Console]::ResetColor()
        [Console]::CursorVisible = $true
        [Console]::TreatControlCAsInput = $originalTreatControlC
        if ($null -ne $originalTitle) {
            try { $Host.UI.RawUI.WindowTitle = $originalTitle } catch { Write-Verbose 'Window title could not be restored.' }
        }
        if ($useAlternateBuffer) {
            [Console]::Write("$escape[?1049l")
        }
        else {
            [Console]::Clear()
        }
    }
}

#endregion

#region Entry point

try {
    switch ($PSCmdlet.ParameterSetName) {
        'Cidr' {
            $parsed = ConvertFrom-CidrNotation -Cidr $Cidr
            Get-SubnetInfo -Address $parsed.Address -PrefixLength $parsed.PrefixLength
        }
        'Mask' {
            $address = ConvertTo-IPv4Integer -Address $IPAddress
            $prefix = ConvertTo-PrefixLength -SubnetMask $SubnetMask
            Get-SubnetInfo -Address $address -PrefixLength $prefix
        }
        'Hosts' {
            $address = ConvertTo-IPv4Integer -Address $IPAddress
            $prefix = Get-PrefixFromHostCount -HostCount $Hosts
            Get-SubnetInfo -Address $address -PrefixLength $prefix -RequestedHosts $Hosts
        }
        default {
            Invoke-NetworkCalcTui
        }
    }
}
catch {
    $PSCmdlet.ThrowTerminatingError(
        [System.Management.Automation.ErrorRecord]::new(
            $_.Exception, 'NetworkCalcError', [System.Management.Automation.ErrorCategory]::InvalidArgument, $null))
}

#endregion
