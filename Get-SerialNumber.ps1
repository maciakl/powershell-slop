<#
.SYNOPSIS
    Displays the computer's make, model and serial number.

.DESCRIPTION
    Queries WMI/CIM (Win32_ComputerSystem, Win32_ComputerSystemProduct, Win32_BIOS,
    Win32_SystemEnclosure, Win32_BaseBoard) and the BIOS registry key to determine
    the make, model and serial number of the local computer. Works with Dell, HP,
    Lenovo, Acer, ASUS, Sony/VAIO, Razer, Microsoft Surface, MSI, Samsung, Toshiba,
    Fujitsu, Gigabyte, custom-built PCs and common virtual machines.

    Vendor placeholder strings such as "To be filled by O.E.M." or "Default string"
    are ignored and the next available source is used instead.

    The output format is chosen automatically:
      * Console     - colorized, labelled report
      * Pipeline    - a PowerShell object (Make, Model, SerialNumber), also when the
                      result is assigned to a variable or wrapped in parentheses
      * Redirected  - plain text (e.g. "> file.txt", or stdout redirected by cmd.exe)

    Use -AsText or -AsObject to override the automatic choice.

.PARAMETER Make
    Output only the make (manufacturer), as plain text with no label.

.PARAMETER Model
    Output only the model, as plain text with no label.

.PARAMETER Serial
    Output only the serial number, as plain text with no label.

.PARAMETER AsText
    Force plain, uncolored text output.

.PARAMETER AsObject
    Force PowerShell object output.

.PARAMETER Help
    Display usage information.

.EXAMPLE
    .\Get-SerialNumber.ps1
    Prints a colorized report to the console.

.EXAMPLE
    .\Get-SerialNumber.ps1 -Serial
    Prints only the serial number.

.EXAMPLE
    .\Get-SerialNumber.ps1 | Export-Csv inventory.csv -NoTypeInformation
    Pipes the result as an object.

.EXAMPLE
    .\Get-SerialNumber.ps1 > info.txt
    Writes a plain-text report to a file.

.EXAMPLE
    .\Get-SerialNumber.ps1 -Make -Model -AsObject
    Returns an object containing only the Make and Model properties.
#>
[CmdletBinding()]
param(
    [Alias('Manufacturer', 'Vendor')]
    [switch]$Make,

    [switch]$Model,

    [Alias('SerialNumber', 'SN', 'ServiceTag')]
    [switch]$Serial,

    [Alias('Text', 'Plain')]
    [switch]$AsText,

    [Alias('Object')]
    [switch]$AsObject,

    [Alias('h', 'Usage')]
    [switch]$Help
)

Set-StrictMode -Version 2.0

$Invocation = $MyInvocation
$ScriptName = Split-Path -Leaf $PSCommandPath
if (-not $ScriptName) { $ScriptName = 'Get-SerialNumber.ps1' }

# ---------------------------------------------------------------------------
# Help
# ---------------------------------------------------------------------------

function Show-Usage {
    @"

$ScriptName - show the computer's make, model and serial number

USAGE
    .\$ScriptName [-Make] [-Model] [-Serial] [-AsText | -AsObject] [-Help]

SWITCHES
    -Make        Output only the make (manufacturer), no label.
    -Model       Output only the model, no label.
    -Serial      Output only the serial number, no label.
                 (-Make, -Model and -Serial may be combined; values are
                  printed one per line in make, model, serial order.)
    -AsText      Force plain, uncolored text output.
    -AsObject    Force PowerShell object output.
    -Help        Show this help. (Get-Help .\$ScriptName -Full for more.)

DEFAULT OUTPUT
    Console      Colorized, labelled report.
    Piped        PowerShell object with Make, Model and SerialNumber.
    Redirected   Plain text (e.g. .\$ScriptName > info.txt).

EXAMPLES
    .\$ScriptName
    .\$ScriptName -Serial
    .\$ScriptName | Format-List
    .\$ScriptName > info.txt
    .\$ScriptName -Make -Model -AsObject
    `$sn = .\$ScriptName -Serial

"@ -split '\r?\n'
}

# ---------------------------------------------------------------------------
# Hardware discovery
# ---------------------------------------------------------------------------

# Strings vendors and board makers leave in SMBIOS fields that carry no information.
$Placeholders = @(
    'To be filled by O.E.M.', 'To be filled by OEM', 'To Be Filled By O.E.M',
    'Default string', 'Default', 'OEM', 'O.E.M.', 'OEM Default', 'OEM_Default',
    'System Serial Number', 'System Product Name', 'System Manufacturer',
    'System manufacturer', 'System Version', 'System Name', 'Chassis Serial Number',
    'Base Board Serial Number', 'Base Board Product Name', 'Serial Number',
    'SerialNumber', 'Product Name', 'Manufacturer', 'Not Specified',
    'Not Applicable', 'Not Available', 'Not Defined', 'Unknown', 'None', 'Null',
    'N/A', 'NA', 'Invalid', 'Empty', 'Type1ProductConfigId', 'Type1Family',
    'Type2 - Board Serial Number', 'Type2 - Board Product Name1',
    '123456789', '1234567890', '0123456789', '01234567890', 'ABCDEFGHIJ',
    'SN12345678', 'x.x', 'Mainboard', 'Desktop', 'Notebook', 'Laptop'
)

function Get-CleanValue {
    param([object]$Value)

    if ($null -eq $Value) { return $null }
    $text = ([string]$Value).Trim().Trim([char]0).Trim()
    if ($text.Length -eq 0) { return $null }
    if ($Placeholders -contains $text) { return $null }         # case-insensitive
    if ($text -match '^[\s0\.\-_:]+$') { return $null }          # all zeros / separators
    if ($text -match '^(.)\1+$') { return $null }                # FFFFFFFF, XXXXXXX, ...
    $text
}

function Select-FirstValue {
    foreach ($candidate in $args) {
        $value = Get-CleanValue $candidate
        if ($value) { return $value }
    }
    $null
}

function Get-WmiData {
    param([string]$ClassName)

    try {
        Get-CimInstance -ClassName $ClassName -ErrorAction Stop | Select-Object -First 1
    }
    catch {
        # Fallback for systems where the CIM/WinRM stack is broken; not present in PS 7.
        try { Get-WmiObject -Class $ClassName -ErrorAction Stop | Select-Object -First 1 }
        catch { $null }
    }
}

function Get-Prop {
    param([object]$Object, [string]$Name)

    if ($null -ne $Object -and $Object.PSObject.Properties[$Name]) {
        $Object.PSObject.Properties[$Name].Value
    }
}

function Get-FriendlyMake {
    param([string]$Name)

    if (-not $Name) { return $null }

    $map = [ordered]@{
        '^Dell'                         = 'Dell'
        '^Alienware'                    = 'Alienware'
        '^(HP|Hewlett[\s-]*Packard)\b'  = 'HP'
        '^Lenovo'                       = 'Lenovo'
        '^Acer'                         = 'Acer'
        '^ASUS'                         = 'ASUS'
        '^Sony'                         = 'Sony'
        '^VAIO'                         = 'VAIO'
        '^Razer'                        = 'Razer'
        '^Microsoft'                    = 'Microsoft'
        '^(Micro-Star|MSI\b)'           = 'MSI'
        '^Gigabyte'                     = 'Gigabyte'
        '^Samsung'                      = 'Samsung'
        '^Toshiba'                      = 'Toshiba'
        '^Dynabook'                     = 'Dynabook'
        '^Fujitsu'                      = 'Fujitsu'
        '^Panasonic'                    = 'Panasonic'
        '^LG Electronics'               = 'LG'
        '^Huawei'                       = 'Huawei'
        '^(Xiaomi|Timi)'                = 'Xiaomi'
        '^Apple'                        = 'Apple'
        '^Google'                       = 'Google'
        '^Framework'                    = 'Framework'
        '^Getac'                        = 'Getac'
        '^Intel'                        = 'Intel'
        '^ASRock'                       = 'ASRock'
        '^Medion'                       = 'Medion'
        '^Gateway'                      = 'Gateway'
        '^Packard Bell'                 = 'Packard Bell'
        '^System76'                     = 'System76'
        '^Clevo'                        = 'Clevo'
        '^Chuwi'                        = 'Chuwi'
        '^Beelink'                      = 'Beelink'
        '^Minisforum|^Micro Computer'   = 'Minisforum'
        '^Zotac'                        = 'Zotac'
        '^VMware'                       = 'VMware'
        '^innotek'                      = 'VirtualBox'
        '^Parallels'                    = 'Parallels'
        '^QEMU'                         = 'QEMU'
        '^Xen'                          = 'Xen'
        '^Amazon EC2'                   = 'Amazon EC2'
    }

    foreach ($pattern in $map.Keys) {
        if ($Name -match $pattern) { return $map[$pattern] }
    }
    $Name
}

function Get-SystemInfo {
    $cs        = Get-WmiData 'Win32_ComputerSystem'
    $csp       = Get-WmiData 'Win32_ComputerSystemProduct'
    $bios      = Get-WmiData 'Win32_BIOS'
    $enclosure = Get-WmiData 'Win32_SystemEnclosure'
    $board     = Get-WmiData 'Win32_BaseBoard'
    $reg       = $null
    try { $reg = Get-ItemProperty -Path 'HKLM:\HARDWARE\DESCRIPTION\System\BIOS' -ErrorAction Stop } catch { }

    # --- Make -------------------------------------------------------------
    $systemMake = Select-FirstValue (Get-Prop $cs 'Manufacturer') (Get-Prop $csp 'Vendor') `
                                    (Get-Prop $reg 'SystemManufacturer')
    $boardMake  = Select-FirstValue (Get-Prop $board 'Manufacturer') (Get-Prop $reg 'BaseBoardManufacturer')

    # --- Model ------------------------------------------------------------
    $systemModel = $null
    if ($systemMake -match '^Lenovo') {
        # Lenovo puts the machine type (e.g. 20XW00ABUS) in Model and the
        # marketing name (e.g. ThinkPad X1 Carbon Gen 9) in Version.
        $friendly    = Select-FirstValue (Get-Prop $csp 'Version') (Get-Prop $reg 'SystemVersion') `
                                         (Get-Prop $cs 'SystemFamily') (Get-Prop $reg 'SystemFamily')
        $machineType = Select-FirstValue (Get-Prop $cs 'Model') (Get-Prop $csp 'Name')
        if ($friendly -and $friendly -notmatch '^Lenovo$') {
            $systemModel = $friendly
            if ($machineType -and $machineType -ne $friendly) {
                $systemModel = '{0} ({1})' -f $friendly, $machineType.Substring(0, [Math]::Min(4, $machineType.Length))
            }
        }
        else {
            $systemModel = $machineType
        }
    }
    else {
        $systemModel = Select-FirstValue (Get-Prop $cs 'Model') (Get-Prop $csp 'Name') `
                                         (Get-Prop $reg 'SystemProductName')
    }
    $boardModel = Select-FirstValue (Get-Prop $board 'Product') (Get-Prop $reg 'BaseBoardProduct')

    # Custom-built PCs often leave the system fields blank; fall back to the motherboard.
    $makeValue  = $systemMake
    $modelValue = $systemModel
    if (-not $systemMake -and -not $systemModel) {
        $makeValue  = $boardMake
        $modelValue = $boardModel
    }
    elseif (-not $systemMake) {
        $makeValue = $boardMake
    }
    elseif (-not $systemModel -and $boardModel) {
        $modelValue = $boardModel
    }

    # --- Serial -----------------------------------------------------------
    # Win32_BIOS holds the Dell service tag, HP/Lenovo/Acer/ASUS/Surface serials, etc.
    $serialValue = Select-FirstValue (Get-Prop $bios 'SerialNumber') (Get-Prop $csp 'IdentifyingNumber') `
                                     (Get-Prop $enclosure 'SerialNumber') (Get-Prop $board 'SerialNumber')

    [pscustomobject]@{
        Make         = Get-FriendlyMake $makeValue
        Model        = $modelValue
        SerialNumber = $serialValue
    }
}

# ---------------------------------------------------------------------------
# Output mode detection
# ---------------------------------------------------------------------------

# Inspects the command line that invoked this script to decide where the
# output is going: 'Object' (piped/captured), 'Text' (redirected to a file)
# or 'Host' (displayed on the console).
function Get-InvocationTarget {
    param([System.Management.Automation.InvocationInfo]$Info)

    $line   = $Info.Line
    $offset = $Info.OffsetInLine
    if ([string]::IsNullOrWhiteSpace($line) -or $offset -lt 1) { return $null }

    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($line, [ref]$tokens, [ref]$errors)

    # Innermost command whose extent contains the invocation offset.
    $command = $null
    $commands = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true)
    foreach ($candidate in $commands) {
        $extent = $candidate.Extent
        if ($extent.StartLineNumber -eq 1 -and $extent.StartColumnNumber -le $offset -and $extent.EndColumnNumber -gt $offset) {
            if (-not $command -or $extent.Text.Length -lt $command.Extent.Text.Length) { $command = $candidate }
        }
    }
    if (-not $command) { return $null }

    # Walk outward; the nearest construct that consumes our output decides.
    $child = $null
    $node  = $command
    while ($node) {
        if ($node -is [System.Management.Automation.Language.CommandBaseAst]) {
            foreach ($redirection in $node.Redirections) {
                if ($redirection -is [System.Management.Automation.Language.FileRedirectionAst] -and
                    ('Output', 'All') -contains [string]$redirection.FromStream) {
                    return 'Text'
                }
            }
        }
        elseif ($node -is [System.Management.Automation.Language.PipelineAst]) {
            $elements = $node.PipelineElements
            if ($elements.Count -gt 1 -and -not [object]::ReferenceEquals($elements[$elements.Count - 1], $child)) {
                return 'Object'
            }
        }
        elseif ($node -is [System.Management.Automation.Language.AssignmentStatementAst] -or
                $node -is [System.Management.Automation.Language.ParenExpressionAst] -or
                $node -is [System.Management.Automation.Language.SubExpressionAst] -or
                $node -is [System.Management.Automation.Language.ArrayExpressionAst]) {
            return 'Object'
        }
        $child = $node
        $node  = $node.Parent
    }
    $null
}

function Get-OutputMode {
    param([System.Management.Automation.InvocationInfo]$Info)

    # With "powershell -File" there is no command line text and the host itself
    # appends Out-Default to the pipeline, so only check for a pipe when invoked
    # from a command line or script.
    if (-not [string]::IsNullOrWhiteSpace($Info.Line)) {
        if ($Info.PipelinePosition -lt $Info.PipelineLength) { return 'Object' }

        $target = $null
        try { $target = Get-InvocationTarget $Info } catch { }
        if ($target) { return $target }
    }

    # e.g. "powershell -File Get-SerialNumber.ps1 > out.txt" from cmd.exe
    try { if ([Console]::IsOutputRedirected) { return 'Text' } } catch { }

    'Host'
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

if ($Help) {
    Show-Usage
    return
}

if ($AsText -and $AsObject) {
    Write-Error 'The -AsText and -AsObject switches cannot be used together. Use -Help for usage.'
    return
}

$info = Get-SystemInfo

$fields = @()
if ($Make)   { $fields += 'Make' }
if ($Model)  { $fields += 'Model' }
if ($Serial) { $fields += 'SerialNumber' }

if ($AsObject) {
    $mode = 'Object'
}
elseif ($AsText) {
    $mode = 'Text'
}
elseif ($fields.Count -gt 0) {
    # Individual values are always bare text unless -AsObject is given.
    $mode = 'Text'
}
else {
    $mode = Get-OutputMode $Invocation
}

if ($fields.Count -gt 0) {
    if ($mode -eq 'Object') {
        $info | Select-Object -Property $fields
    }
    else {
        foreach ($field in $fields) { [string]$info.$field }
    }
    return
}

$rows = @(
    @{ Label = 'Make';          Value = $info.Make;         Color = 'White'  }
    @{ Label = 'Model';         Value = $info.Model;        Color = 'White'  }
    @{ Label = 'Serial Number'; Value = $info.SerialNumber; Color = 'Yellow' }
)

switch ($mode) {
    'Object' {
        $info
    }
    'Text' {
        foreach ($row in $rows) {
            $value = $row.Value
            if (-not $value) { $value = 'Not found' }
            '{0,-15}{1}' -f ($row.Label + ':'), $value
        }
    }
    default {
        Write-Host ''
        foreach ($row in $rows) {
            Write-Host ('  {0,-15}' -f ($row.Label + ':')) -ForegroundColor Cyan -NoNewline
            if ($row.Value) { Write-Host $row.Value -ForegroundColor $row.Color }
            else            { Write-Host 'Not found' -ForegroundColor Red }
        }
        Write-Host ''
    }
}
