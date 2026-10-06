<#
.SYNOPSIS
    Displays detailed Windows version, build and environment information.

.DESCRIPTION
    Get-WinVer collects the Windows product name, edition, display version
    (e.g. 25H2), build number, update build revision (UBR), kernel and
    Feature Experience Pack versions, architecture, language, install and
    boot times, and runtime versions - everything typically needed to
    identify a Windows environment when troubleshooting.

    Output adapts to how the script is invoked:
      * At the console          -> colorized, human friendly report
      * Piped / assigned        -> a [pscustomobject] (GetWinVer.Info)
      * Redirected to a file    -> plain text report

    Use -AsText or -AsObject to force a specific output type. Use one or
    more of the field switches (-Build, -Edition, -DisplayVersion, ...) to
    return only those values. Fields are returned as bare text unless
    -AsObject is also given, in which case a labeled object is returned.

    No external modules are required. Works on Windows PowerShell 5.1 and
    PowerShell 7+. Set the NO_COLOR environment variable to disable color.

.PARAMETER AsText
    Always return a plain text report (or plain field values).

.PARAMETER AsObject
    Always return an object. Combined with field switches, returns an
    object containing only the selected fields.

.PARAMETER Help
    Shows usage information, including the list of field switches, and exits.

.EXAMPLE
    .\Get-WinVer.ps1
    Shows a colorized report.

.EXAMPLE
    .\Get-WinVer.ps1 > winver.txt
    Writes a plain text report to winver.txt.

.EXAMPLE
    .\Get-WinVer.ps1 | Select-Object ProductName, DisplayVersion, FullBuild
    Pipes the information object into another command.

.EXAMPLE
    .\Get-WinVer.ps1 -FullBuild
    Returns just the build string, e.g. 26200.6584

.EXAMPLE
    .\Get-WinVer.ps1 -DisplayVersion -Build -AsObject
    Returns an object with DisplayVersion and Build properties.
#>
[CmdletBinding()]
param(
    [switch]$Help,
    [switch]$AsText,
    [switch]$AsObject,

    # Field switches - each returns only that data point.
    [switch]$ComputerName,
    [switch]$ProductName,
    [switch]$OSName,
    [switch]$Edition,
    [switch]$CompositionEdition,
    [Alias('DisplayName')]
    [switch]$DisplayVersion,
    [switch]$ReleaseId,
    [switch]$Version,
    [switch]$Build,
    [Alias('Revision')]
    [switch]$UBR,
    [switch]$FullBuild,
    [switch]$FullVersion,
    [switch]$LCUVersion,
    [switch]$KernelVersion,
    [Alias('FEP')]
    [switch]$FeatureExperiencePack,
    [switch]$BuildLab,
    [switch]$BuildLabEx,
    [switch]$BuildBranch,
    [switch]$InsiderChannel,
    [switch]$InstallationType,
    [switch]$ProductType,
    [switch]$SKU,
    [Alias('Arch')]
    [switch]$Architecture,
    [switch]$ProcessArchitecture,
    [switch]$OSLanguage,
    [switch]$UILanguage,
    [switch]$SystemLocale,
    [switch]$InstallDate,
    [switch]$LastBootTime,
    [switch]$Uptime,
    [switch]$WindowsDirectory,
    [switch]$RegisteredOwner,
    [switch]$PowerShellVersion,
    [switch]$DotNetFramework
)

# Field switch names, in report order. Each matches a property on the result object.
$FieldNames = @(
    'ComputerName', 'ProductName', 'OSName', 'Edition', 'CompositionEdition',
    'DisplayVersion', 'ReleaseId', 'Version', 'Build', 'UBR', 'FullBuild',
    'FullVersion', 'LCUVersion', 'KernelVersion', 'FeatureExperiencePack',
    'BuildLab', 'BuildLabEx', 'BuildBranch', 'InsiderChannel',
    'InstallationType', 'ProductType', 'SKU', 'Architecture',
    'ProcessArchitecture', 'OSLanguage', 'UILanguage', 'SystemLocale',
    'InstallDate', 'LastBootTime', 'Uptime', 'WindowsDirectory',
    'RegisteredOwner', 'PowerShellVersion', 'DotNetFramework'
)

# Sections for the text / colorized report: label, property, highlight color.
$Layout = @(
    @{ Title = 'Windows'; Fields = @(
        @('Product Name',        'ProductName',           'White'),
        @('OS Name',             'OSName',                'White'),
        @('Display Version',     'DisplayVersion',        'Yellow'),
        @('Edition',             'Edition',               $null),
        @('Composition Edition', 'CompositionEdition',    $null),
        @('Installation Type',   'InstallationType',      $null),
        @('Product Type',        'ProductType',           $null),
        @('SKU',                 'SKU',                   $null),
        @('Release ID',          'ReleaseId',             $null)
    ) },
    @{ Title = 'Version'; Fields = @(
        @('Version',             'Version',               $null),
        @('Build',               'Build',                 'Green'),
        @('UBR (Revision)',      'UBR',                   'Green'),
        @('Full Build',          'FullBuild',             'Green'),
        @('Full Version',        'FullVersion',           $null),
        @('LCU Version',         'LCUVersion',            $null),
        @('Kernel Version',      'KernelVersion',         $null),
        @('Feature Exp. Pack',   'FeatureExperiencePack', $null),
        @('Build Lab',           'BuildLab',              $null),
        @('Build Lab Ex',        'BuildLabEx',            $null),
        @('Build Branch',        'BuildBranch',           $null),
        @('Insider Channel',     'InsiderChannel',        $null)
    ) },
    @{ Title = 'System'; Fields = @(
        @('Computer Name',       'ComputerName',          'White'),
        @('Architecture',        'Architecture',          $null),
        @('Process Arch.',       'ProcessArchitecture',   $null),
        @('OS Language',         'OSLanguage',            $null),
        @('UI Language',         'UILanguage',            $null),
        @('System Locale',       'SystemLocale',          $null),
        @('Windows Directory',   'WindowsDirectory',      $null),
        @('Registered Owner',    'RegisteredOwner',       $null),
        @('Install Date',        'InstallDate',           $null),
        @('Last Boot Time',      'LastBootTime',          $null),
        @('Uptime',              'Uptime',                $null)
    ) },
    @{ Title = 'Runtime'; Fields = @(
        @('PowerShell',          'PowerShellVersion',     $null),
        @('.NET Framework',      'DotNetFramework',       $null)
    ) }
)

#region Data collection

function Get-RegValue {
    param([string]$Path, [string]$Name)
    # Avoid throwing for missing values so nothing lands in $Error / transcripts.
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $item = Get-ItemProperty -LiteralPath $Path -ErrorAction SilentlyContinue
    if ($item -and $item.PSObject.Properties[$Name]) { return $item.$Name }
    return $null
}

function Get-CultureName {
    param($Lcid)
    if ($null -eq $Lcid -or "$Lcid" -eq '') { return $null }
    try {
        $id = if ($Lcid -is [string]) { [Convert]::ToInt32($Lcid, 16) } else { [int]$Lcid }
        $culture = New-Object System.Globalization.CultureInfo($id)
        return '{0} ({1})' -f $culture.Name, $culture.EnglishName
    } catch {
        return "$Lcid"
    }
}

function Get-WinVerInfo {
    $cvPath = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    $cv = $null
    try { $cv = Get-ItemProperty -LiteralPath $cvPath -ErrorAction Stop } catch { }

    function cv([string]$Name) {
        if ($null -ne $cv -and $cv.PSObject.Properties[$Name]) { return $cv.$Name }
        return $null
    }

    $os = $null
    try { $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop } catch { }

    # Version numbers
    $major = cv 'CurrentMajorVersionNumber'
    $minor = cv 'CurrentMinorVersionNumber'
    $build = cv 'CurrentBuildNumber'
    if (-not $build) { $build = cv 'CurrentBuild' }
    if ($null -eq $major -and $os) {
        $parts = $os.Version.Split('.')
        $major = $parts[0]; $minor = $parts[1]
    }
    if ($null -eq $major) {
        $osv = [Environment]::OSVersion.Version
        $major = $osv.Major; $minor = $osv.Minor
        if (-not $build) { $build = $osv.Build }
    }
    if (-not $build -and $os) { $build = $os.BuildNumber }
    $buildInt = 0
    [void][int]::TryParse("$build", [ref]$buildInt)
    $ubr = cv 'UBR'

    $versionStr = '{0}.{1}.{2}' -f $major, $minor, $build
    $fullBuild = if ($null -ne $ubr) { '{0}.{1}' -f $build, $ubr } else { "$build" }
    $fullVersion = if ($null -ne $ubr) { '{0}.{1}' -f $versionStr, $ubr } else { $versionStr }

    $installationType = cv 'InstallationType'
    $isServer = ($installationType -like 'Server*') -or ($os -and $os.ProductType -ne 1)

    # Product name: registry still says "Windows 10" on Windows 11, so prefer CIM caption.
    $productName = $null
    if ($os -and $os.Caption) { $productName = ($os.Caption -replace '^Microsoft\s+', '').Trim() }
    if (-not $productName) {
        $productName = cv 'ProductName'
        if ($productName -and -not $isServer -and $buildInt -ge 22000) {
            $productName = $productName -replace 'Windows 10', 'Windows 11'
        }
    }

    # Short OS family name
    $osName = $null
    if ($productName -match 'Windows (Server \d{4}( R2)?|\d+)') { $osName = 'Windows ' + $Matches[1] }
    if (-not $osName) {
        if ($isServer) {
            $serverMap = [ordered]@{ 26100 = '2025'; 20348 = '2022'; 17763 = '2019'; 14393 = '2016' }
            foreach ($k in $serverMap.Keys) {
                if ($buildInt -ge $k) { $osName = 'Windows Server ' + $serverMap[$k]; break }
            }
        } elseif ("$major" -eq '10') {
            $osName = if ($buildInt -ge 22000) { 'Windows 11' } else { 'Windows 10' }
        }
    }

    # Kernel version (use Sysnative from a 32-bit process on 64-bit Windows)
    $kernelVersion = $null
    $sysDir = Join-Path $env:windir 'System32'
    if (Test-Path (Join-Path $env:windir 'Sysnative')) { $sysDir = Join-Path $env:windir 'Sysnative' }
    try {
        $vi = (Get-Item -LiteralPath (Join-Path $sysDir 'ntoskrnl.exe') -ErrorAction Stop).VersionInfo
        $kernelVersion = '{0}.{1}.{2}.{3}' -f $vi.ProductMajorPart, $vi.ProductMinorPart, $vi.ProductBuildPart, $vi.ProductPrivatePart
    } catch { }

    # Windows Feature Experience Pack
    $fep = $null
    $fepManifest = Join-Path $env:windir 'SystemApps\MicrosoftWindows.Client.CBS_cw5n1h2txyewy\appxmanifest.xml'
    try {
        if (Test-Path -LiteralPath $fepManifest) {
            $xml = [xml](Get-Content -LiteralPath $fepManifest -Raw -ErrorAction Stop)
            $fep = $xml.Package.Identity.Version
        }
    } catch { }

    # Insider program
    $insider = $null
    $selfHost = 'HKLM:\SOFTWARE\Microsoft\WindowsSelfHost\Applicability'
    $branchName = Get-RegValue $selfHost 'BranchName'
    if ($branchName) {
        $ring = Get-RegValue $selfHost 'Ring'
        $insider = if ($ring) { '{0} ({1})' -f $branchName, $ring } else { "$branchName" }
    }

    # Architecture: the machine-wide value reflects the native OS, even under emulation.
    $arch = Get-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment' 'PROCESSOR_ARCHITECTURE'
    if (-not $arch) { $arch = $env:PROCESSOR_ARCHITECTURE }
    if ($os -and $os.OSArchitecture) { $arch = '{0} ({1})' -f $arch, $os.OSArchitecture }
    $procArch = '{0} ({1}-bit)' -f $env:PROCESSOR_ARCHITECTURE, $(if ([Environment]::Is64BitProcess) { 64 } else { 32 })

    # Dates
    $installDate = $null
    $installEpoch = cv 'InstallDate'
    if ($installEpoch) {
        try { $installDate = [DateTimeOffset]::FromUnixTimeSeconds([long]$installEpoch).LocalDateTime } catch { }
    }
    if (-not $installDate -and $os) { $installDate = $os.InstallDate }
    $lastBoot = $null
    $uptime = $null
    if ($os -and $os.LastBootUpTime) {
        $lastBoot = $os.LastBootUpTime
        $uptime = (Get-Date) - $lastBoot
    }

    $productType = $null
    if ($os) {
        switch ($os.ProductType) {
            1 { $productType = 'Workstation' }
            2 { $productType = 'Domain Controller' }
            3 { $productType = 'Server' }
            default { $productType = "$($os.ProductType)" }
        }
    }

    # .NET Framework 4.x
    $dotNet = $null
    $ndp = 'HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full'
    $release = Get-RegValue $ndp 'Release'
    if ($release) {
        $friendly = if ($release -ge 533320) { '4.8.1' }
                    elseif ($release -ge 528040) { '4.8' }
                    elseif ($release -ge 461808) { '4.7.2' }
                    else { Get-RegValue $ndp 'Version' }
        $dotNet = '{0} (release {1})' -f $friendly, $release
    }

    $psEd = if ($PSVersionTable.PSEdition) { $PSVersionTable.PSEdition } else { 'Desktop' }
    $psVersion = '{0} ({1})' -f $PSVersionTable.PSVersion, $psEd

    $owner = cv 'RegisteredOwner'
    $org = cv 'RegisteredOrganization'
    if ($org) { $owner = '{0} / {1}' -f $owner, $org }

    [pscustomobject][ordered]@{
        PSTypeName            = 'GetWinVer.Info'
        ComputerName          = $env:COMPUTERNAME
        ProductName           = $productName
        OSName                = $osName
        Edition               = cv 'EditionID'
        CompositionEdition    = cv 'CompositionEditionID'
        DisplayVersion        = cv 'DisplayVersion'
        ReleaseId             = cv 'ReleaseId'
        Version               = $versionStr
        Build                 = $buildInt
        UBR                   = $ubr
        FullBuild             = $fullBuild
        FullVersion           = $fullVersion
        LCUVersion            = cv 'LCUVer'
        KernelVersion         = $kernelVersion
        FeatureExperiencePack = $fep
        BuildLab              = cv 'BuildLab'
        BuildLabEx            = cv 'BuildLabEx'
        BuildBranch           = cv 'BuildBranch'
        InsiderChannel        = $insider
        InstallationType      = $installationType
        ProductType           = $productType
        SKU                   = $(if ($os) { $os.OperatingSystemSKU } else { $null })
        Architecture          = $arch
        ProcessArchitecture   = $procArch
        OSLanguage            = $(if ($os) { Get-CultureName $os.OSLanguage } else { $null })
        UILanguage            = '{0} ({1})' -f (Get-UICulture).Name, (Get-UICulture).EnglishName
        SystemLocale          = $(if ($os) { Get-CultureName $os.Locale } else { $null })
        InstallDate           = $installDate
        LastBootTime          = $lastBoot
        Uptime                = $uptime
        WindowsDirectory      = $env:windir
        RegisteredOwner       = $owner
        PowerShellVersion     = $psVersion
        DotNetFramework       = $dotNet
    }
}

#endregion

#region Output helpers

function Format-WinVerValue {
    param($Value)
    if ($null -eq $Value) { return '' }
    if ($Value -is [datetime]) { return $Value.ToString('yyyy-MM-dd HH:mm:ss') }
    if ($Value -is [timespan]) {
        return '{0}d {1:D2}h {2:D2}m {3:D2}s' -f $Value.Days, $Value.Hours, $Value.Minutes, $Value.Seconds
    }
    return "$Value"
}

function Get-LabelWidth {
    $width = 0
    foreach ($section in $Layout) {
        foreach ($f in $section.Fields) { if ($f[0].Length -gt $width) { $width = $f[0].Length } }
    }
    return $width + 2
}

function Get-HeaderText {
    param($Info)
    $parts = @($Info.ProductName)
    if ($Info.DisplayVersion) { $parts += $Info.DisplayVersion }
    $parts += 'OS Build ' + $Info.FullBuild
    return ($parts -join '  |  ')
}

function ConvertTo-WinVerText {
    param($Info)
    $width = Get-LabelWidth
    $header = Get-HeaderText $Info
    $header
    '=' * $header.Length
    foreach ($section in $Layout) {
        ''
        $section.Title
        '-' * $section.Title.Length
        foreach ($f in $section.Fields) {
            $value = Format-WinVerValue $Info.($f[1])
            if ($value -eq '') { $value = 'n/a' }
            '  {0} {1}' -f ($f[0] + ' ').PadRight($width, '.'), $value
        }
    }
}

function Write-WinVerColor {
    param($Info)
    $width = Get-LabelWidth
    $line = [string][char]0x2500

    Write-Host ''
    Write-Host '  ' -NoNewline
    Write-Host $Info.ProductName -ForegroundColor Cyan -NoNewline
    if ($Info.DisplayVersion) {
        Write-Host '  ' -NoNewline
        Write-Host $Info.DisplayVersion -ForegroundColor Black -BackgroundColor Yellow -NoNewline
    }
    Write-Host '  OS Build ' -ForegroundColor DarkGray -NoNewline
    Write-Host $Info.FullBuild -ForegroundColor Green
    Write-Host ('  ' + ($line * ((Get-HeaderText $Info).Length))) -ForegroundColor DarkGray

    foreach ($section in $Layout) {
        Write-Host ''
        Write-Host ('  ' + $section.Title.ToUpper()) -ForegroundColor Cyan
        foreach ($f in $section.Fields) {
            $value = Format-WinVerValue $Info.($f[1])
            Write-Host ('    ' + $f[0].PadRight($width)) -ForegroundColor DarkGray -NoNewline
            if ($value -eq '') {
                Write-Host 'n/a' -ForegroundColor DarkGray
            } elseif ($f[2]) {
                Write-Host $value -ForegroundColor $f[2]
            } else {
                Write-Host $value -ForegroundColor Gray
            }
        }
    }
    Write-Host ''
}

# Inspects how this script was invoked: piped to another command, captured
# into a variable / expression, or redirected to a file.
function Get-InvocationContext {
    param([System.Management.Automation.InvocationInfo]$Invocation)

    $ctx = @{ Piped = $false; Captured = $false; Redirected = $false }

    if ($Invocation.PipelinePosition -lt $Invocation.PipelineLength) { $ctx.Piped = $true }
    if ([Console]::IsOutputRedirected) { $ctx.Redirected = $true }

    if (-not $Invocation.Line -or $Invocation.OffsetInLine -lt 1) { return $ctx }

    try {
        $tokens = $null; $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseInput($Invocation.Line, [ref]$tokens, [ref]$errors)
        $offset = $Invocation.OffsetInLine
        $cmd = $ast.Find({
            param($a)
            $a -is [System.Management.Automation.Language.CommandAst] -and
            $a.Extent.StartLineNumber -eq 1 -and
            $a.Extent.StartColumnNumber -eq $offset
        }, $true)
        if (-not $cmd) { return $ctx }

        foreach ($r in $cmd.Redirections) {
            $from = "$($r.FromStream)"
            if ($r -is [System.Management.Automation.Language.FileRedirectionAst]) {
                if ($from -in 'Output', 'All') { $ctx.Redirected = $true }
            } elseif ($from -in 'Information', 'All') {
                # e.g. 6>&1 / *>&1 - host output would be captured as records
                $ctx.Redirected = $true
            }
        }

        $parent = $cmd.Parent
        while ($parent -and $parent -isnot [System.Management.Automation.Language.ScriptBlockAst]) {
            if ($parent -is [System.Management.Automation.Language.AssignmentStatementAst] -or
                $parent -is [System.Management.Automation.Language.SubExpressionAst] -or
                $parent -is [System.Management.Automation.Language.ParenExpressionAst] -or
                $parent -is [System.Management.Automation.Language.ArrayExpressionAst]) {
                $ctx.Captured = $true
                break
            }
            $parent = $parent.Parent
        }
    } catch { }

    return $ctx
}

function Get-WinVerUsage {
    param([System.Management.Automation.CommandInfo]$Command)
    $script = Split-Path -Leaf $Command.Path
    $width = 0
    foreach ($section in $Layout) {
        foreach ($f in $section.Fields) { if ($f[1].Length -gt $width) { $width = $f[1].Length } }
    }
    $width += 3

    "Usage: .\$script [-AsText | -AsObject] [<field switches>...]"
    "       .\$script -Help"
    ''
    'Displays Windows version, build and environment information. At the console'
    'a colorized report is shown; when piped or assigned an object is returned;'
    'when redirected to a file plain text is written.'
    ''
    'Output options:'
    '  ' + '-AsText'.PadRight($width) + 'Always return plain text.'
    '  ' + '-AsObject'.PadRight($width) + 'Always return an object (with field switches: only those fields).'
    '  ' + '-Help'.PadRight($width) + 'Show this usage information.'
    foreach ($section in $Layout) {
        ''
        "$($section.Title) fields:"
        foreach ($f in $section.Fields) {
            $desc = $f[0]
            $aliases = @($Command.Parameters[$f[1]].Aliases)
            if ($aliases.Count -gt 0) { $desc += ' (alias: ' + (($aliases | ForEach-Object { "-$_" }) -join ', ') + ')' }
            '  ' + "-$($f[1])".PadRight($width) + $desc
        }
    }
    ''
    'Field switches return bare values, in the order given; add -AsObject for a'
    'labeled object. Set NO_COLOR to disable color.'
    ''
    'Examples:'
    "  .\$script"
    "  .\$script > winver.txt"
    "  .\$script -FullBuild"
    "  .\$script -DisplayVersion -Build -AsObject"
    ''
    "For full help: Get-Help .\$script -Full"
}

#endregion

#region Main

if ($Help) {
    Get-WinVerUsage $MyInvocation.MyCommand
    return
}

if ($AsText -and $AsObject) {
    throw 'The -AsText and -AsObject switches cannot be used together.'
}

# Preserve the order in which field switches were given on the command line.
$selected = @($PSBoundParameters.Keys | Where-Object { $FieldNames -contains $_ -and $PSBoundParameters[$_] })
$info = Get-WinVerInfo

if ($selected.Count -gt 0) {
    if ($AsObject) {
        $result = [ordered]@{}
        foreach ($name in $selected) { $result[$name] = $info.$name }
        [pscustomobject]$result
    } else {
        foreach ($name in $selected) { Format-WinVerValue $info.$name }
    }
    return
}

if ($AsObject) { return $info }
if ($AsText)   { return ConvertTo-WinVerText $info }

$ctx = Get-InvocationContext $MyInvocation
if ($ctx.Piped -or $ctx.Captured) {
    $info
} elseif ($ctx.Redirected -or $env:NO_COLOR) {
    ConvertTo-WinVerText $info
} else {
    Write-WinVerColor $info
}

#endregion
