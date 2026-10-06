<#
.SYNOPSIS
    Returns the true absolute path of a user's Documents folder.

.DESCRIPTION
    Resolves the Documents ("Personal") known folder for the current user or
    for another local/domain user, taking into account:

      * OneDrive Known Folder Move (OneDrive Personal and OneDrive for
        Business / "OneDrive - <Org>"), including the legacy SkyDrive client
      * Group Policy / manual Folder Redirection (local or UNC paths)
      * Relocated user profiles (ProfileImagePath not under C:\Users)
      * Symbolic links, junctions and mount points anywhere in the path

    The script writes the resolved path as a single line of text and nothing
    else. On failure it writes a message to stderr and exits with code 1.

    Works on Windows PowerShell 5.1 (ships with Windows 11) and PowerShell 7+.
    No external modules or tools are required.

.PARAMETER User
    The user whose Documents folder should be resolved. Accepts
    "user", "DOMAIN\user", "AzureAD\user", "user@domain" or a SID string.
    Defaults to the current user.

    If the user is not logged on, the user's registry hive (NTUSER.DAT) must
    be loaded temporarily, which requires running elevated.

.PARAMETER NoResolveLinks
    Return the configured path without resolving symbolic links/junctions.

.PARAMETER Help
    Show usage information and exit.

.EXAMPLE
    .\Get-DocumentsPath.ps1
    C:\Users\jane\OneDrive\Documents

.EXAMPLE
    .\Get-DocumentsPath.ps1 -User CONTOSO\bob
    \\fileserver\home$\bob\Documents

.EXAMPLE
    cd (.\Get-DocumentsPath.ps1)
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [Alias('u', 'UserName')]
    [string]$User,

    [Alias('n')]
    [switch]$NoResolveLinks,

    [Alias('h')]
    [switch]$Help
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$script:FolderGuidDocuments = '{F42EE2D3-909F-4907-8871-4C22FC0BF756}'
$script:ShellFoldersKey     = 'Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders'
$script:ShellFoldersLegacy  = 'Software\Microsoft\Windows\CurrentVersion\Explorer\Shell Folders'
$script:ProfileListKey      = 'SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList'

function Show-Usage {
    $name = 'Get-DocumentsPath.ps1'
    @"
Usage: $name [[-User] <name|SID>] [-NoResolveLinks] [-Help]

Prints the true absolute path of a user's Documents folder, accounting for
OneDrive (Personal/Business/legacy SkyDrive), folder redirection, relocated
profiles, and symbolic links/junctions.

Options:
  -User, -u <name>       User to look up: user, DOMAIN\user, AzureAD\user,
                         user@domain, or a SID. Default: current user.
                         A user who is not logged on requires elevation.
  -NoResolveLinks, -n    Do not resolve symbolic links / junctions.
  -Help, -h              Show this help and exit.

Exit codes: 0 = success, 1 = error (message on stderr).

Examples:
  $name
  $name -User CONTOSO\bob
  $name S-1-5-21-1111111111-2222222222-3333333333-1001
"@
}

function Exit-WithError([string]$Message) {
    [Console]::Error.WriteLine("Get-DocumentsPath: $Message")
    exit 1
}

# ---------------------------------------------------------------------------
# Link / junction resolution
# ---------------------------------------------------------------------------

$script:NativeAvailable = $false
function Initialize-Native {
    if ('GetDocumentsPath.Native' -as [type]) { $script:NativeAvailable = $true; return }
    try {
        Add-Type -ErrorAction Stop -TypeDefinition @'
using System;
using System.Text;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
namespace GetDocumentsPath {
    public static class Native {
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        static extern SafeFileHandle CreateFileW(string name, uint access, uint share,
            IntPtr security, uint disposition, uint flags, IntPtr template);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        static extern uint GetFinalPathNameByHandleW(SafeFileHandle handle,
            StringBuilder buffer, uint length, uint flags);

        const uint FILE_SHARE_ALL = 0x7;
        const uint OPEN_EXISTING = 3;
        const uint FILE_FLAG_BACKUP_SEMANTICS = 0x02000000;

        public static string GetFinalPath(string path) {
            using (SafeFileHandle h = CreateFileW(path, 0, FILE_SHARE_ALL, IntPtr.Zero,
                    OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS, IntPtr.Zero)) {
                if (h.IsInvalid) return null;
                StringBuilder sb = new StringBuilder(1024);
                uint n = GetFinalPathNameByHandleW(h, sb, (uint)sb.Capacity, 0);
                if (n == 0) return null;
                if (n >= sb.Capacity) {
                    sb = new StringBuilder((int)n + 1);
                    n = GetFinalPathNameByHandleW(h, sb, (uint)sb.Capacity, 0);
                    if (n == 0) return null;
                }
                return sb.ToString();
            }
        }
    }
}
'@
        $script:NativeAvailable = $true
    } catch {
        # e.g. Constrained Language Mode; fall back to pure PowerShell resolution.
        $script:NativeAvailable = $false
    }
}

function Remove-LongPathPrefix([string]$Path) {
    if ($Path.StartsWith('\\?\UNC\', [StringComparison]::OrdinalIgnoreCase)) { return '\\' + $Path.Substring(8) }
    if ($Path.StartsWith('\\?\')) { return $Path.Substring(4) }
    return $Path
}

function Get-LinkTargetOf($Item) {
    # PowerShell 7+: LinkTarget; Windows PowerShell 5.1: Target (string[])
    $target = $null
    if ($Item.PSObject.Properties['LinkTarget']) { $target = $Item.LinkTarget }
    if (-not $target -and $Item.PSObject.Properties['Target']) { $target = @($Item.Target) | Select-Object -First 1 }
    if ($target) { return [string]$target }
    return $null
}

function Resolve-LinksManually([string]$Path) {
    # Walk the path one component at a time, substituting link targets.
    $current = [IO.Path]::GetFullPath($Path)
    for ($guard = 0; $guard -lt 64; $guard++) {
        $root  = [IO.Path]::GetPathRoot($current)
        $parts = $current.Substring($root.Length).Split([char[]]'\', [StringSplitOptions]::RemoveEmptyEntries)
        $built = $root
        $changed = $false
        for ($i = 0; $i -lt $parts.Count; $i++) {
            $built = Join-Path $built $parts[$i]
            $item = Get-Item -LiteralPath $built -Force -ErrorAction SilentlyContinue
            if (-not $item) { return $current }
            if (-not ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { continue }
            $target = Get-LinkTargetOf $item
            if (-not $target) { continue }   # e.g. OneDrive cloud placeholder
            $target = Remove-LongPathPrefix $target
            if (-not [IO.Path]::IsPathRooted($target)) {
                $target = Join-Path (Split-Path $built -Parent) $target
            }
            $rest = @($parts | Select-Object -Skip ($i + 1))
            $current = [IO.Path]::GetFullPath((@($target) + $rest) -join '\')
            $changed = $true
            break
        }
        if (-not $changed) { return $current }
    }
    return $current
}

function Resolve-TruePath([string]$Path) {
    if ($NoResolveLinks -or -not (Test-Path -LiteralPath $Path -PathType Container)) {
        return $Path.TrimEnd('\')
    }
    if ($script:NativeAvailable) {
        $final = [GetDocumentsPath.Native]::GetFinalPath($Path)
        # Volume GUID paths (volume without a drive letter) are not useful to callers.
        if ($final -and -not $final.StartsWith('\\?\Volume{', [StringComparison]::OrdinalIgnoreCase)) {
            return (Remove-LongPathPrefix $final).TrimEnd('\')
        }
    }
    return (Resolve-LinksManually $Path).TrimEnd('\')
}

# ---------------------------------------------------------------------------
# User / registry helpers
# ---------------------------------------------------------------------------

function Get-ProfileImagePath([string]$Sid) {
    $key = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey("$script:ProfileListKey\$Sid")
    if (-not $key) { return $null }
    try { return [string]$key.GetValue('ProfileImagePath') } finally { $key.Close() }
}

function Resolve-UserSid([string]$Name) {
    if ($Name -match '^S-1-\d+(-\d+)+$') { return $Name.ToUpperInvariant() }
    try {
        return ([Security.Principal.NTAccount]$Name).Translate([Security.Principal.SecurityIdentifier]).Value
    } catch { }
    # Fallback: match the profile folder name (e.g. cached Azure AD / orphaned accounts).
    $leaf = ($Name -replace '^.*\\', '') -replace '@.*$', ''
    $list = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey($script:ProfileListKey)
    if ($list) {
        try {
            foreach ($sid in $list.GetSubKeyNames()) {
                if ($sid -like '*.bak') { continue }
                $p = Get-ProfileImagePath $sid
                if ($p -and (Split-Path $p -Leaf) -ieq $leaf) { return $sid }
            }
        } finally { $list.Close() }
    }
    return $null
}

function Get-RawRegValue($Key, [string]$Name) {
    if (-not $Key) { return $null }
    $v = $Key.GetValue($Name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
    if ($v -is [string] -and $v.Trim()) { return $v.Trim() }
    return $null
}

function Expand-ForUser([string]$Value, [hashtable]$Vars) {
    if (-not $Value) { return $Value }
    $result = $Value
    for ($pass = 0; $pass -lt 5 -and $result -match '%[^%\s]+%'; $pass++) {
        $result = [regex]::Replace($result, '%([^%\s]+)%', {
            param($m)
            $n = $m.Groups[1].Value
            if ($Vars.ContainsKey($n)) { return [string]$Vars[$n] }
            $machine = [Environment]::GetEnvironmentVariable($n, 'Machine')
            if ($machine) { return $machine }
            $proc = [Environment]::GetEnvironmentVariable($n, 'Process')
            if ($proc -and $n -notmatch '^(USER|HOME|APPDATA|LOCALAPPDATA|ONEDRIVE|TEMP|TMP)') { return $proc }
            return $m.Value
        })
    }
    return $result
}

function Get-OneDriveFallbacks($HiveRoot, [hashtable]$Vars) {
    # Candidate Documents locations inside OneDrive folders, used only if the
    # configured path does not exist. Business accounts first (KFM is usually
    # enforced by policy there), then Personal, then legacy SkyDrive.
    $candidates = New-Object System.Collections.Generic.List[string]
    $accounts = $HiveRoot.OpenSubKey('Software\Microsoft\OneDrive\Accounts')
    if ($accounts) {
        try {
            $names = @($accounts.GetSubKeyNames() | Sort-Object { if ($_ -like 'Business*') { 0 } else { 1 } }, { $_ })
            foreach ($n in $names) {
                $k = $accounts.OpenSubKey($n)
                try {
                    $folder = Get-RawRegValue $k 'UserFolder'
                    if ($folder) { $candidates.Add((Join-Path (Expand-ForUser $folder $Vars) 'Documents')) }
                } finally { if ($k) { $k.Close() } }
            }
        } finally { $accounts.Close() }
    }
    foreach ($v in 'OneDriveCommercial', 'OneDriveConsumer', 'OneDrive') {
        if ($Vars.ContainsKey($v) -and $Vars[$v]) { $candidates.Add((Join-Path $Vars[$v] 'Documents')) }
    }
    $sky = $HiveRoot.OpenSubKey('Software\Microsoft\SkyDrive')
    if ($sky) {
        try {
            $folder = Get-RawRegValue $sky 'UserFolder'
            if ($folder) { $candidates.Add((Join-Path (Expand-ForUser $folder $Vars) 'Documents')) }
        } finally { $sky.Close() }
    }
    return $candidates
}

function Get-DocumentsFromHive($HiveRoot, [string]$ProfilePath) {
    # Build the user's own environment so %USERPROFILE%, %OneDrive%, etc.
    # expand to that user's values rather than ours.
    $vars = @{}
    $vars['USERPROFILE']  = $ProfilePath
    $vars['USERNAME']     = Split-Path $ProfilePath -Leaf
    $vars['APPDATA']      = Join-Path $ProfilePath 'AppData\Roaming'
    $vars['LOCALAPPDATA'] = Join-Path $ProfilePath 'AppData\Local'
    if ($ProfilePath -match '^([A-Za-z]:)(.*)$') {
        $vars['HOMEDRIVE'] = $Matches[1]; $vars['HOMEPATH'] = $Matches[2]
    }
    foreach ($sub in 'Volatile Environment', 'Environment') {
        $k = $HiveRoot.OpenSubKey($sub)
        if (-not $k) { continue }
        try {
            foreach ($n in $k.GetValueNames()) {
                $raw = Get-RawRegValue $k $n
                if ($raw -and $n -notmatch '^(PATH|TEMP|TMP)$') { $vars[$n] = $raw }
            }
        } finally { $k.Close() }
    }
    foreach ($n in @($vars.Keys)) { $vars[$n] = Expand-ForUser $vars[$n] $vars }

    $configured = $null
    foreach ($keyPath in $script:ShellFoldersKey, $script:ShellFoldersLegacy) {
        $k = $HiveRoot.OpenSubKey($keyPath)
        if (-not $k) { continue }
        try {
            $configured = Get-RawRegValue $k $script:FolderGuidDocuments
            if (-not $configured) { $configured = Get-RawRegValue $k 'Personal' }
        } finally { $k.Close() }
        if ($configured) { break }
    }
    if (-not $configured) { $configured = '%USERPROFILE%\Documents' }
    $configured = Expand-ForUser $configured $vars

    if (Test-Path -LiteralPath $configured -PathType Container) { return $configured }
    foreach ($c in (Get-OneDriveFallbacks $HiveRoot $vars)) {
        if (Test-Path -LiteralPath $c -PathType Container) { return $c }
    }
    return $configured   # Report what Windows is configured to use even if absent.
}

function Get-OtherUserDocuments([string]$Sid) {
    $profilePath = Get-ProfileImagePath $Sid
    if (-not $profilePath) { Exit-WithError "No local profile found for SID $Sid on this machine." }

    $hive = [Microsoft.Win32.Registry]::Users.OpenSubKey($Sid)
    if ($hive) {
        try { return Get-DocumentsFromHive $hive $profilePath } finally { $hive.Close() }
    }

    # User is not logged on: temporarily load NTUSER.DAT (requires elevation).
    $ntuser = Join-Path $profilePath 'NTUSER.DAT'
    if (-not (Test-Path -LiteralPath $ntuser)) { Exit-WithError "Registry hive not found: $ntuser" }
    $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Exit-WithError 'The user is not logged on; run elevated (as Administrator) to read their registry hive.'
    }
    $mount = 'GetDocumentsPath_' + [Guid]::NewGuid().ToString('N')
    $reg = Join-Path $env:SystemRoot 'System32\reg.exe'
    & $reg load "HKU\$mount" $ntuser 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { Exit-WithError "Unable to load registry hive $ntuser." }
    try {
        $hive = [Microsoft.Win32.Registry]::Users.OpenSubKey($mount)
        try { return Get-DocumentsFromHive $hive $profilePath } finally { if ($hive) { $hive.Close() } }
    } finally {
        [GC]::Collect(); [GC]::WaitForPendingFinalizers()
        & $reg unload "HKU\$mount" 2>&1 | Out-Null
    }
}

function Get-CurrentUserDocuments {
    # SHGetFolderPath honours OneDrive KFM, folder redirection and relocation.
    $path = [Environment]::GetFolderPath([Environment+SpecialFolder]::MyDocuments,
                                         [Environment+SpecialFolderOption]::DoNotVerify)
    if ($path -and (Test-Path -LiteralPath $path -PathType Container)) { return $path }
    # Fall back to registry-based logic (covers odd or partially-migrated setups).
    $profilePath = $env:USERPROFILE
    if (-not $profilePath) { $profilePath = Get-ProfileImagePath ([Security.Principal.WindowsIdentity]::GetCurrent().User.Value) }
    $fromHive = Get-DocumentsFromHive ([Microsoft.Win32.Registry]::CurrentUser) $profilePath
    if ($fromHive) { return $fromHive }
    return $path
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

if ($Help) { Show-Usage; exit 0 }

if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
    Exit-WithError 'This script supports Windows only.'
}

try {
    $currentSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $targetSid  = $currentSid
    if ($User) {
        $targetSid = Resolve-UserSid $User
        if (-not $targetSid) { Exit-WithError "Unknown user '$User'." }
    }

    if ($targetSid -eq $currentSid) {
        $docs = Get-CurrentUserDocuments
    } else {
        $docs = Get-OtherUserDocuments $targetSid
    }
    if (-not $docs) { Exit-WithError 'Unable to determine the Documents folder.' }

    Initialize-Native
    Write-Output (Resolve-TruePath $docs)
    exit 0
} catch {
    Exit-WithError $_.Exception.Message
}
