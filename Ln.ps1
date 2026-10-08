#Requires -Version 5.1
<#
.SYNOPSIS
    ln - make links between files. A PowerShell port of the POSIX/GNU ln utility.

.DESCRIPTION
    Creates Windows (NTFS) hard links and symbolic links using POSIX/GNU ln
    command-line syntax. Run "Ln.ps1 --help" for the full option list and
    see README.md for the differences between this port and ln on Unix.

        Ln.ps1 [OPTION]... [-T] TARGET LINK_NAME
        Ln.ps1 [OPTION]... TARGET
        Ln.ps1 [OPTION]... TARGET... DIRECTORY
        Ln.ps1 [OPTION]... -t DIRECTORY TARGET...

.EXAMPLE
    .\Ln.ps1 -s ..\shared\config.json config.json

.EXAMPLE
    .\Ln.ps1 -sfv C:\tools\bin\app.exe app.exe

.NOTES
    Copyright (C) 2026 Luke Maciak

    This program is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    This program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with this program.  If not, see <https://www.gnu.org/licenses/>.
#>

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$LnVersion = '1.0.0'

if ($PSVersionTable.PSEdition -eq 'Core' -and -not $IsWindows) {
    [Console]::Error.WriteLine('ln: this port only runs on Windows; use the native ln instead')
    exit 1
}

# ---------------------------------------------------------------------------
# Win32 interop. Compiled in-process by Add-Type (part of PowerShell itself),
# so the script has no external dependencies. Written in C# 5 so that the
# .NET Framework compiler used by Windows PowerShell 5.1 accepts it.
# ---------------------------------------------------------------------------
if (-not ('LnPs1v1.Native' -as [type])) {
    Add-Type -Language CSharp -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;

namespace LnPs1v1
{
    public sealed class FileStat
    {
        public uint Attributes;
        public uint ReparseTag;
        public uint VolumeSerial;
        public ulong FileIndex;
        public uint LinkCount;
        public bool HasId;

        public bool IsDirectory { get { return (Attributes & 0x10) != 0; } }
        public bool IsReparsePoint { get { return (Attributes & 0x400) != 0; } }

        // Symbolic links and junctions (mount points) behave like POSIX symlinks.
        public bool IsSymlink
        {
            get { return IsReparsePoint && (ReparseTag == 0xA000000C || ReparseTag == 0xA0000003); }
        }

        public bool SameFileAs(FileStat other)
        {
            return other != null && HasId && other.HasId &&
                   VolumeSerial == other.VolumeSerial && FileIndex == other.FileIndex;
        }
    }

    public static class Native
    {
        const uint FILE_READ_ATTRIBUTES = 0x80;
        const uint FILE_WRITE_ATTRIBUTES = 0x100;
        const uint DELETE = 0x10000;
        const uint SYNCHRONIZE = 0x100000;
        const uint FILE_SHARE_ALL = 0x7;
        const uint OPEN_EXISTING = 3;
        const uint FILE_FLAG_BACKUP_SEMANTICS = 0x02000000;
        const uint FILE_FLAG_OPEN_REPARSE_POINT = 0x00200000;
        const uint SYMBOLIC_LINK_FLAG_DIRECTORY = 0x1;
        const uint SYMBOLIC_LINK_FLAG_ALLOW_UNPRIVILEGED_CREATE = 0x2;
        const uint MOVEFILE_REPLACE_EXISTING = 0x1;
        const int FileAttributeTagInfo = 9;
        const int FileDispositionInfo = 4;
        const int FileDispositionInfoEx = 21;
        const int FileLinkInformation = 11;
        const int ERROR_INVALID_PARAMETER = 87;

        [StructLayout(LayoutKind.Sequential)]
        struct BY_HANDLE_FILE_INFORMATION
        {
            public uint FileAttributes;
            public long CreationTime;
            public long LastAccessTime;
            public long LastWriteTime;
            public uint VolumeSerialNumber;
            public uint FileSizeHigh;
            public uint FileSizeLow;
            public uint NumberOfLinks;
            public uint FileIndexHigh;
            public uint FileIndexLow;
        }

        [StructLayout(LayoutKind.Sequential)]
        struct FILE_ATTRIBUTE_TAG_INFO
        {
            public uint FileAttributes;
            public uint ReparseTag;
        }

        [StructLayout(LayoutKind.Sequential)]
        struct IO_STATUS_BLOCK
        {
            public IntPtr Status;
            public IntPtr Information;
        }

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        static extern SafeFileHandle CreateFileW(string name, uint access, uint share, IntPtr security,
                                                 uint disposition, uint flags, IntPtr template);

        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool GetFileInformationByHandle(SafeFileHandle handle, out BY_HANDLE_FILE_INFORMATION info);

        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool GetFileInformationByHandleEx(SafeFileHandle handle, int infoClass,
                                                        out FILE_ATTRIBUTE_TAG_INFO info, uint size);

        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool SetFileInformationByHandle(SafeFileHandle handle, int infoClass, ref uint info, uint size);

        [DllImport("kernel32.dll", EntryPoint = "SetFileInformationByHandle", SetLastError = true)]
        static extern bool SetFileInformationByHandleByte(SafeFileHandle handle, int infoClass, ref byte info, uint size);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        static extern uint GetFileAttributesW(string name);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        static extern uint GetFinalPathNameByHandleW(SafeFileHandle handle, StringBuilder buffer, uint size, uint flags);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        static extern bool CreateHardLinkW(string link, string existing, IntPtr security);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.I1)]
        static extern bool CreateSymbolicLinkW(string link, string target, uint flags);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        static extern bool MoveFileExW(string from, string to, uint flags);

        [DllImport("ntdll.dll")]
        static extern int NtSetInformationFile(SafeFileHandle handle, out IO_STATUS_BLOCK status,
                                               IntPtr info, uint length, int infoClass);

        [DllImport("ntdll.dll")]
        static extern int RtlNtStatusToDosError(int status);

        static SafeFileHandle Open(string path, uint access, bool follow)
        {
            uint flags = FILE_FLAG_BACKUP_SEMANTICS;
            if (!follow) flags |= FILE_FLAG_OPEN_REPARSE_POINT;
            return CreateFileW(path, access, FILE_SHARE_ALL, IntPtr.Zero, OPEN_EXISTING, flags, IntPtr.Zero);
        }

        // stat() when follow is true, lstat() when false. Returns null and a
        // Win32 error code when the path cannot be examined.
        public static FileStat Stat(string path, bool follow, out int error)
        {
            error = 0;
            using (SafeFileHandle h = Open(path, FILE_READ_ATTRIBUTES, follow))
            {
                if (h.IsInvalid)
                {
                    error = Marshal.GetLastWin32Error();
                    // Some files (e.g. locked system files) cannot be opened at
                    // all but still exist; fall back to their attributes.
                    if (!follow && error != 2 && error != 3)
                    {
                        uint attrs = GetFileAttributesW(path);
                        if (attrs != 0xFFFFFFFF)
                        {
                            error = 0;
                            FileStat partial = new FileStat();
                            partial.Attributes = attrs;
                            return partial;
                        }
                    }
                    return null;
                }

                BY_HANDLE_FILE_INFORMATION info;
                if (!GetFileInformationByHandle(h, out info))
                {
                    error = Marshal.GetLastWin32Error();
                    return null;
                }

                FileStat st = new FileStat();
                st.Attributes = info.FileAttributes;
                st.VolumeSerial = info.VolumeSerialNumber;
                st.FileIndex = ((ulong)info.FileIndexHigh << 32) | info.FileIndexLow;
                st.LinkCount = info.NumberOfLinks;
                st.HasId = true;

                if (st.IsReparsePoint)
                {
                    FILE_ATTRIBUTE_TAG_INFO tag;
                    if (GetFileInformationByHandleEx(h, FileAttributeTagInfo, out tag,
                                                     (uint)Marshal.SizeOf(typeof(FILE_ATTRIBUTE_TAG_INFO))))
                    {
                        st.ReparseTag = tag.ReparseTag;
                    }
                }
                return st;
            }
        }

        // Fully resolved path of an existing file (all links followed), like realpath().
        public static string FinalPath(string path, out int error)
        {
            error = 0;
            using (SafeFileHandle h = Open(path, FILE_READ_ATTRIBUTES, true))
            {
                if (h.IsInvalid)
                {
                    error = Marshal.GetLastWin32Error();
                    return null;
                }
                StringBuilder buffer = new StringBuilder(512);
                uint n = GetFinalPathNameByHandleW(h, buffer, (uint)buffer.Capacity, 0);
                if (n >= buffer.Capacity)
                {
                    buffer = new StringBuilder((int)n + 1);
                    n = GetFinalPathNameByHandleW(h, buffer, (uint)buffer.Capacity, 0);
                }
                if (n == 0)
                {
                    error = Marshal.GetLastWin32Error();
                    return null;
                }
                string result = buffer.ToString();
                if (result.StartsWith(@"\\?\UNC\", StringComparison.OrdinalIgnoreCase))
                    return @"\\" + result.Substring(8);
                if (result.StartsWith(@"\\?\") && result.Length >= 6 && result[5] == ':')
                    return result.Substring(4);
                return result;
            }
        }

        public static int CreateSymlink(string link, string target, bool directory)
        {
            uint flags = SYMBOLIC_LINK_FLAG_ALLOW_UNPRIVILEGED_CREATE;
            if (directory) flags |= SYMBOLIC_LINK_FLAG_DIRECTORY;
            if (CreateSymbolicLinkW(link, target, flags)) return 0;
            int error = Marshal.GetLastWin32Error();
            if (error == ERROR_INVALID_PARAMETER)
            {
                // Windows builds that predate the unprivileged-create flag.
                flags &= ~SYMBOLIC_LINK_FLAG_ALLOW_UNPRIVILEGED_CREATE;
                if (CreateSymbolicLinkW(link, target, flags)) return 0;
                error = Marshal.GetLastWin32Error();
            }
            return error;
        }

        public static int CreateHardLink(string link, string existing)
        {
            return CreateHardLinkW(link, existing, IntPtr.Zero) ? 0 : Marshal.GetLastWin32Error();
        }

        // Hard link to the named file itself, even when it is a symbolic link
        // (ln -P semantics). Uses FileLinkInformation on a handle opened with
        // FILE_FLAG_OPEN_REPARSE_POINT so the link is never followed.
        public static int CreateHardLinkNoFollow(string link, string existing)
        {
            using (SafeFileHandle h = Open(existing, FILE_WRITE_ATTRIBUTES | SYNCHRONIZE, false))
            {
                if (h.IsInvalid) return Marshal.GetLastWin32Error();

                byte[] name = Encoding.Unicode.GetBytes(ToNtPath(link));
                int offRoot = IntPtr.Size;              // after BOOLEAN ReplaceIfExists, pointer aligned
                int offLength = offRoot + IntPtr.Size;  // after HANDLE RootDirectory
                int offName = offLength + 4;            // after ULONG FileNameLength
                int size = offName + name.Length + 2;
                IntPtr buffer = Marshal.AllocHGlobal(size);
                try
                {
                    for (int i = 0; i < size; i++) Marshal.WriteByte(buffer, i, 0);
                    Marshal.WriteInt32(buffer, offLength, name.Length);
                    Marshal.Copy(name, 0, new IntPtr(buffer.ToInt64() + offName), name.Length);
                    IO_STATUS_BLOCK iosb;
                    int status = NtSetInformationFile(h, out iosb, buffer, (uint)size, FileLinkInformation);
                    return status < 0 ? RtlNtStatusToDosError(status) : 0;
                }
                finally
                {
                    Marshal.FreeHGlobal(buffer);
                }
            }
        }

        // unlink(): removes a file, or a symbolic link / junction without
        // touching what it points to. Like unlink() on POSIX, the read-only
        // attribute does not prevent removal.
        public static int Remove(string path)
        {
            using (SafeFileHandle h = Open(path, DELETE, false))
            {
                if (h.IsInvalid) return Marshal.GetLastWin32Error();
                uint flags = 0x1 | 0x2 | 0x10; // DELETE | POSIX_SEMANTICS | IGNORE_READONLY_ATTRIBUTE
                if (SetFileInformationByHandle(h, FileDispositionInfoEx, ref flags, 4)) return 0;
                // File systems without FileDispositionInfoEx (FAT, older Windows).
                byte delete = 1;
                if (SetFileInformationByHandleByte(h, FileDispositionInfo, ref delete, 1)) return 0;
                return Marshal.GetLastWin32Error();
            }
        }

        public static int Rename(string from, string to)
        {
            return MoveFileExW(from, to, MOVEFILE_REPLACE_EXISTING) ? 0 : Marshal.GetLastWin32Error();
        }

        static string ToNtPath(string full)
        {
            if (full.StartsWith(@"\\?\") || full.StartsWith(@"\\.\")) return @"\??\" + full.Substring(4);
            if (full.StartsWith(@"\\")) return @"\??\UNC\" + full.Substring(2);
            return @"\??\" + full;
        }
    }
}
'@
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

$Opt = @{
    Symbolic    = $false
    Force       = $false
    Interactive = $false
    Logical     = $false
    NoDeref     = $false
    Relative    = $false
    Verbose     = $false
    HardDir     = $false
    Backup      = $false
    BackupArg   = $null
    Suffix      = $null
    TargetDir   = $null
    NoTargetDir = $false
    Failed      = $false
}

function Write-Err([string]$Message) {
    [Console]::Error.WriteLine("ln: $Message")
}

function Exit-Usage([string]$Message) {
    if ($Message) { Write-Err $Message }
    [Console]::Error.WriteLine("Try 'ln --help' for more information.")
    exit 1
}

function Exit-Fail([string]$Message) {
    Write-Err $Message
    exit 1
}

function Q([string]$Text) {
    if ($Text.Contains("'")) { return '"' + $Text + '"' }
    return "'" + $Text + "'"
}

# Win32 error code -> strerror()-style text.
function Get-ErrorText([int]$Code) {
    switch ($Code) {
        { $_ -in 2, 3, 161 } { return 'No such file or directory' }
        5    { return 'Permission denied' }
        { $_ -in 80, 183 } { return 'File exists' }
        17   { return 'Invalid cross-device link' }
        1142 { return 'Too many links' }
        { $_ -in 1, 50 } { return 'Operation not supported' }
        206  { return 'File name too long' }
        267  { return 'Not a directory' }
        1314 { return 'Operation not permitted (symbolic links require Developer Mode or an elevated prompt)' }
    }
    return ([ComponentModel.Win32Exception]::new($Code)).Message.TrimEnd('.')
}

function Get-Stat([string]$FullPath, [bool]$Follow) {
    $err = 0
    $st = [LnPs1v1.Native]::Stat($FullPath, $Follow, [ref]$err)
    return [pscustomobject]@{ Stat = $st; Error = $err }
}

# Absolute path of $Path, resolved against $Base (default: PowerShell's
# current file system location, which can differ from the process CWD).
function Get-FullPath([string]$Path, [string]$Base) {
    if (-not $Base) { $Base = (Get-Location -PSProvider FileSystem).ProviderPath }
    if ($Path -match '^[\\/](?![\\/])') {
        # Root-relative (\foo): relative to the drive of the base directory.
        $Path = [IO.Path]::GetPathRoot($Base).TrimEnd('\') + $Path
    }
    $full = [IO.Path]::GetFullPath([IO.Path]::Combine($Base, $Path))
    $root = [IO.Path]::GetPathRoot($full)
    if ($full.Length -gt $root.Length) { $full = $full.TrimEnd('\', '/') }
    return $full
}

function Get-BaseName([string]$Path) {
    $trimmed = $Path.TrimEnd('\', '/')
    return $trimmed.Substring($trimmed.LastIndexOfAny([char[]]'\/:') + 1)
}

function Join-Display([string]$Dir, [string]$Name) {
    if ($Dir.EndsWith('\') -or $Dir.EndsWith('/')) { return $Dir + $Name }
    if ($Dir.Contains('/') -and -not $Dir.Contains('\')) { return "$Dir/$Name" }
    return "$Dir\$Name"
}

function Get-RelativePath([string]$FromDir, [string]$To) {
    $fromRoot = [IO.Path]::GetPathRoot($FromDir)
    $toRoot = [IO.Path]::GetPathRoot($To)
    if (-not [string]::Equals($fromRoot.TrimEnd('\'), $toRoot.TrimEnd('\'), [StringComparison]::OrdinalIgnoreCase)) {
        return $To  # different drives or shares: no relative path exists
    }
    $sep = [char[]]'\'
    $from = $FromDir.Substring($fromRoot.Length).Split($sep, [StringSplitOptions]::RemoveEmptyEntries)
    $to = $To.Substring($toRoot.Length).Split($sep, [StringSplitOptions]::RemoveEmptyEntries)
    $common = 0
    while ($common -lt $from.Length -and $common -lt $to.Length -and
           [string]::Equals($from[$common], $to[$common], [StringComparison]::OrdinalIgnoreCase)) {
        $common++
    }
    $parts = New-Object System.Collections.Generic.List[string]
    for ($i = $common; $i -lt $from.Length; $i++) { $parts.Add('..') }
    for ($i = $common; $i -lt $to.Length; $i++) { $parts.Add($to[$i]) }
    if ($parts.Count -eq 0) { return '.' }
    return [string]::Join('\', $parts)
}

# GNU argmatch: exact match, or an unambiguous abbreviation.
function Select-Match([string]$Arg, [string[]]$Names, $Values) {
    $hits = @($Names | Where-Object { $_.StartsWith($Arg, [StringComparison]::Ordinal) })
    if ($Names -ccontains $Arg) { return $Arg }
    if ($hits.Count -eq 0) { return $null }
    if ($Values) {
        $distinct = @($hits | ForEach-Object { $Values[$_] } | Select-Object -Unique)
        if ($distinct.Count -eq 1) { return $hits[0] }
    }
    elseif ($hits.Count -eq 1) { return $hits[0] }
    return $hits
}

function Get-BackupType([string]$Arg, [string]$Context) {
    $types = [ordered]@{
        'none' = 'none'; 'off' = 'none'
        'simple' = 'simple'; 'never' = 'simple'
        'existing' = 'existing'; 'nil' = 'existing'
        'numbered' = 'numbered'; 't' = 'numbered'
    }
    $names = [string[]]@($types.Keys)
    $hit = Select-Match $Arg $names $types
    if ($hit -is [string]) { return $types[$hit] }
    $kind = if ($null -eq $hit) { 'invalid' } else { 'ambiguous' }
    Write-Err "$kind argument $(Q $Arg) for $(Q $Context)"
    [Console]::Error.WriteLine("Valid arguments are:`n  - 'none', 'off'`n  - 'simple', 'never'`n  - 'existing', 'nil'`n  - 'numbered', 't'")
    Exit-Usage
}

function Get-BackupName([string]$DestFull, [string]$Type, [string]$Suffix) {
    $dir = [IO.Path]::GetDirectoryName($DestFull)
    $base = [IO.Path]::GetFileName($DestFull)
    if ($Type -ne 'simple') {
        $pattern = '^' + [regex]::Escape($base) + '\.~([1-9][0-9]*)~$'
        $highest = 0
        foreach ($entry in [IO.Directory]::EnumerateFileSystemEntries($dir)) {
            $m = [regex]::Match([IO.Path]::GetFileName($entry), $pattern, 'IgnoreCase')
            if ($m.Success) {
                $n = [long]$m.Groups[1].Value
                if ($n -gt $highest) { $highest = $n }
            }
        }
        if ($Type -eq 'numbered' -or $highest -gt 0) { return "$DestFull.~$($highest + 1)~" }
    }
    return $DestFull + $Suffix
}

function Read-Confirmation([string]$Prompt) {
    [Console]::Error.Write("ln: $Prompt ")
    if ([Console]::IsInputRedirected) { $line = [Console]::In.ReadLine() }
    else { $line = $Host.UI.ReadLine() }
    return ($null -ne $line -and $line.TrimStart() -match '^[yY]')
}

function Show-Help {
    @"
Usage: ln [OPTION]... [-T] TARGET LINK_NAME
  or:  ln [OPTION]... TARGET
  or:  ln [OPTION]... TARGET... DIRECTORY
  or:  ln [OPTION]... -t DIRECTORY TARGET...
In the 1st form, create a link to TARGET with the name LINK_NAME.
In the 2nd form, create a link to TARGET in the current directory.
In the 3rd and 4th forms, create links to each TARGET in DIRECTORY.
Create hard links by default, symbolic links with --symbolic.
By default, each destination (name of new link) should not already exist.
When creating hard links, each TARGET must exist.  Symbolic links
can hold arbitrary text; if later resolved, a relative link is
interpreted in relation to its parent directory.

Mandatory arguments to long options are mandatory for short options too.
      --backup[=CONTROL]      make a backup of each existing destination file
  -b                          like --backup but does not accept an argument
  -d, -F, --directory         allow the superuser to attempt to hard link
                                directories (always fails on Windows)
  -f, --force                 remove existing destination files
  -i, --interactive           prompt whether to remove destinations
  -L, --logical               dereference TARGETs that are symbolic links
  -n, --no-dereference        treat LINK_NAME as a normal file if
                                it is a symbolic link to a directory
  -P, --physical              make hard links directly to symbolic links
  -r, --relative              with -s, create links relative to link location
  -s, --symbolic              make symbolic links instead of hard links
  -S, --suffix=SUFFIX         override the usual backup suffix
  -t, --target-directory=DIRECTORY  specify the DIRECTORY in which to create
                                the links
  -T, --no-target-directory   treat LINK_NAME as a normal file always
  -v, --verbose               print name of each linked file
      --help        display this help and exit
      --version     output version information and exit

The backup suffix is '~', unless set with --suffix or SIMPLE_BACKUP_SUFFIX.
The version control method may be selected via the --backup option or through
the VERSION_CONTROL environment variable.  Here are the values:

  none, off       never make backups (even if --backup is given)
  numbered, t     make numbered backups
  existing, nil   numbered if numbered backups exist, simple otherwise
  simple, never   always make simple backups

Using -s ignores -L and -P.  Otherwise, the last option specified controls
behavior when a TARGET is a symbolic link, defaulting to -P.

Windows notes:
  Symbolic links require Developer Mode or an elevated (Administrator) prompt.
  A symbolic link is created as a directory link when TARGET (resolved
  relative to the link) is a directory, or when a nonexistent TARGET ends
  in '\' or '/'; otherwise it is a file link.  '/' in TARGET becomes '\'.
  Hard links require NTFS or ReFS and cannot cross volumes.
  PowerShell swallows a bare --; quote it ('--') to end option parsing.
  Wildcards are not expanded; pass e.g. (Get-ChildItem *.txt) instead.
"@
}

function Show-Version {
    @"
ln (PowerShell port) $LnVersion
Copyright (C) 2026 Luke Maciak
License GPLv3+: GNU GPL version 3 or later <https://gnu.org/licenses/gpl.html>.
This is free software: you are free to change and redistribute it.
There is NO WARRANTY, to the extent permitted by law.

Modeled on ln from GNU coreutils.
"@
}

# ---------------------------------------------------------------------------
# Link creation (one TARGET -> one LINK_NAME)
# ---------------------------------------------------------------------------

$JustCreated = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)

function New-Link([string]$Target, [string]$Dest) {
    $kind = if ($Opt.Symbolic) { 'symbolic link' } else { 'hard link' }
    $arrow = if ($Opt.Symbolic) { '->' } else { '=>' }

    try { $destFull = Get-FullPath $Dest }
    catch { Write-Err "$(Q $Dest): Invalid argument"; $Opt.Failed = $true; return }
    $linkDir = [IO.Path]::GetDirectoryName($destFull)
    if (-not $linkDir) { $linkDir = $destFull }

    if ($JustCreated.Contains($destFull)) {
        Write-Err "will not overwrite just-created $(Q $Dest) with $(Q $Target)"
        $Opt.Failed = $true; return
    }

    # --- examine the source --------------------------------------------------
    $source = $Target          # what gets printed / stored
    $sourceStat = $null
    $sourceFull = $null
    $isDirLink = $false
    if ($Opt.Symbolic) {
        if ($Target.Length -eq 0) {
            Write-Err "failed to create $kind $(Q $Dest): No such file or directory"
            $Opt.Failed = $true; return
        }
        try {
            $text = $Target.Replace('/', '\')
            if ($Opt.Relative) { $text = Get-RelativePath $linkDir (Get-FullPath $Target) }
            $dirHint = $text.EndsWith('\')
            $root = [IO.Path]::GetPathRoot($text)
            if ($text.Length -gt $root.Length) { $text = $text.TrimEnd('\') }
            $sourceFull = Get-FullPath $text $linkDir
        }
        catch { Write-Err "$(Q $Target): Invalid argument"; $Opt.Failed = $true; return }
        $source = $text
        $resolved = (Get-Stat $sourceFull $true).Stat
        $isDirLink = if ($resolved) { $resolved.IsDirectory } else { $dirHint }
    }
    else {
        try { $sourceFull = Get-FullPath $Target }
        catch { Write-Err "failed to access $(Q $Target): Invalid argument"; $Opt.Failed = $true; return }
        $r = Get-Stat $sourceFull $Opt.Logical
        if (-not $r.Stat) {
            Write-Err "failed to access $(Q $Target): $(Get-ErrorText $r.Error)"
            $Opt.Failed = $true; return
        }
        $sourceStat = $r.Stat
        if ($sourceStat.IsDirectory) {
            if ($Opt.HardDir) {
                Write-Err "failed to create hard link $(Q $Dest) => $(Q $Target): Operation not permitted"
            }
            else {
                Write-Err "$(Q $Target): hard link not allowed for directory"
            }
            $Opt.Failed = $true; return
        }
    }

    # --- deal with an existing destination ----------------------------------
    $backupFull = $null
    $d = Get-Stat $destFull $false
    if ($d.Stat) {
        $destStat = $d.Stat
        $replacing = $Opt.Force -or $Opt.Interactive -or $Opt.Backup
        if (-not $replacing) {
            Write-Err "failed to create $kind $(Q $Dest): File exists"
            $Opt.Failed = $true; return
        }
        if ($destStat.IsDirectory -and -not $destStat.IsSymlink) {
            Write-Err "$(Q $Dest): cannot overwrite directory"
            $Opt.Failed = $true; return
        }
        if (-not $Opt.Backup) {
            $same = if ($Opt.Symbolic) {
                [string]::Equals($sourceFull, $destFull, [StringComparison]::OrdinalIgnoreCase)
            }
            else { $destStat.SameFileAs($sourceStat) }
            if ($same) {
                Write-Err "$(Q $Target) and $(Q $Dest) are the same file"
                $Opt.Failed = $true; return
            }
        }
        if ($Opt.Interactive -and -not (Read-Confirmation "replace $(Q $Dest)?")) { return }

        if ($Opt.Backup) {
            $backupFull = Get-BackupName $destFull $Opt.BackupType $Opt.SuffixValue
            $e = [LnPs1v1.Native]::Rename($destFull, $backupFull)
            if ($e -ne 0) {
                Write-Err "cannot backup $(Q $Dest): $(Get-ErrorText $e)"
                $Opt.Failed = $true; return
            }
        }
        else {
            $e = [LnPs1v1.Native]::Remove($destFull)
            if ($e -ne 0) {
                Write-Err "cannot remove $(Q $Dest): $(Get-ErrorText $e)"
                $Opt.Failed = $true; return
            }
        }
    }

    # --- create the link ----------------------------------------------------
    if ($Opt.Symbolic) {
        $e = [LnPs1v1.Native]::CreateSymlink($destFull, $source, $isDirLink)
    }
    elseif ($Opt.Logical) {
        $err = 0
        $final = [LnPs1v1.Native]::FinalPath($sourceFull, [ref]$err)
        $e = if ($final) { [LnPs1v1.Native]::CreateHardLink($destFull, $final) } else { $err }
    }
    elseif ($sourceStat.IsReparsePoint) {
        $e = [LnPs1v1.Native]::CreateHardLinkNoFollow($destFull, $sourceFull)
    }
    else {
        $e = [LnPs1v1.Native]::CreateHardLink($destFull, $sourceFull)
    }

    if ($e -ne 0) {
        $why = Get-ErrorText $e
        if ($Opt.Symbolic) {
            Write-Err "failed to create symbolic link $(Q $Dest): $why"
        }
        elseif ($e -eq 1142) {
            Write-Err "failed to create hard link to $(Q $Target): $why"
        }
        elseif ($e -in 80, 183, 112) {
            Write-Err "failed to create hard link $(Q $Dest): $why"
        }
        else {
            Write-Err "failed to create hard link $(Q $Dest) => $(Q $Target): $why"
        }
        if ($backupFull) { [void][LnPs1v1.Native]::Rename($backupFull, $destFull) }
        $Opt.Failed = $true; return
    }

    [void]$JustCreated.Add($destFull)

    if ($Opt.Verbose) {
        $prefix = ''
        if ($backupFull) {
            $prefix = (Q ($Dest + $backupFull.Substring($destFull.Length))) + ' ~ '
        }
        Write-Output "$prefix$(Q $Dest) $arrow $(Q $source)"
    }
}

# ---------------------------------------------------------------------------
# Command line parsing (getopt_long compatible, with option permutation)
# ---------------------------------------------------------------------------

# Flatten arguments: arrays and pipeline-style objects are accepted so that
# e.g.  Ln.ps1 -s (Get-ChildItem *.txt) dir  works. Non-string objects are
# always operands, never options.
$tokText = New-Object System.Collections.Generic.List[string]
$tokLiteral = New-Object System.Collections.Generic.List[bool]
function Add-Token($Item) {
    if ($null -eq $Item) { return }
    if ($Item -is [string]) { $tokText.Add($Item); $tokLiteral.Add($false); return }
    if ($Item -is [IO.FileSystemInfo]) { $tokText.Add($Item.FullName); $tokLiteral.Add($true); return }
    if ($Item -is [Management.Automation.PathInfo]) { $tokText.Add($Item.ProviderPath); $tokLiteral.Add($true); return }
    if ($Item -is [Collections.IEnumerable]) { foreach ($x in $Item) { Add-Token $x }; return }
    $tokText.Add([string]$Item); $tokLiteral.Add($true)
}
foreach ($a in $args) { Add-Token $a }

$LongOptions = [ordered]@{
    'backup'              = 'optional'
    'directory'           = 'none'
    'force'               = 'none'
    'interactive'         = 'none'
    'logical'             = 'none'
    'no-dereference'      = 'none'
    'no-target-directory' = 'none'
    'physical'            = 'none'
    'relative'            = 'none'
    'suffix'              = 'required'
    'symbolic'            = 'none'
    'target-directory'    = 'required'
    'verbose'             = 'none'
    'help'                = 'none'
    'version'             = 'none'
}
$LongToShort = @{
    'directory' = 'd'; 'force' = 'f'; 'interactive' = 'i'; 'logical' = 'L'
    'no-dereference' = 'n'; 'no-target-directory' = 'T'; 'physical' = 'P'
    'relative' = 'r'; 'suffix' = 'S'; 'symbolic' = 's'; 'target-directory' = 't'
    'verbose' = 'v'
}

function Set-Option([string]$Key, $Value) {
    switch -CaseSensitive ($Key) {
        'backup' { $Opt.Backup = $true; if ($null -ne $Value) { $Opt.BackupArg = $Value } }
        'b' { $Opt.Backup = $true }
        'd' { $Opt.HardDir = $true }
        'F' { $Opt.HardDir = $true }
        'f' { $Opt.Force = $true; $Opt.Interactive = $false }
        'i' { $Opt.Interactive = $true; $Opt.Force = $false }
        'L' { $Opt.Logical = $true }
        'P' { $Opt.Logical = $false }
        'n' { $Opt.NoDeref = $true }
        'r' { $Opt.Relative = $true }
        's' { $Opt.Symbolic = $true }
        'S' { $Opt.Backup = $true; $Opt.Suffix = $Value }
        't' {
            if ($null -ne $Opt.TargetDir) { Exit-Fail 'multiple target directories specified' }
            $Opt.TargetDir = $Value
        }
        'T' { $Opt.NoTargetDir = $true }
        'v' { $Opt.Verbose = $true }
        'help' { Show-Help; exit 0 }
        'version' { Show-Version; exit 0 }
    }
}

$operands = New-Object System.Collections.Generic.List[string]
$endOfOptions = $false
$i = 0
while ($i -lt $tokText.Count) {
    $tok = $tokText[$i]
    $literal = $tokLiteral[$i]
    $i++
    if ($endOfOptions -or $literal -or $tok.Length -lt 2 -or $tok[0] -ne '-') {
        $operands.Add($tok); continue
    }
    if ($tok -eq '--') { $endOfOptions = $true; continue }
    # PowerShell turns "-t:dir" into the two arguments "-t:" and "dir".
    if ($tok.Length -gt 2 -and $tok.EndsWith(':') -and -not $tok.Contains('=')) {
        $tok = $tok.Substring(0, $tok.Length - 1)
    }

    if ($tok.StartsWith('--')) {
        $body = $tok.Substring(2)
        $value = $null
        $eq = $body.IndexOf('=')
        if ($eq -ge 0) { $value = $body.Substring($eq + 1); $body = $body.Substring(0, $eq) }
        $hit = Select-Match $body ([string[]]@($LongOptions.Keys)) $null
        if ($null -eq $hit) { Exit-Usage "unrecognized option $(Q $tok)" }
        if ($hit -isnot [string]) {
            $list = ($hit | ForEach-Object { "'--$_'" }) -join ' '
            Exit-Usage "option $(Q ('--' + $body)) is ambiguous; possibilities: $list"
        }
        $name = $hit
        switch ($LongOptions[$name]) {
            'none' {
                if ($null -ne $value) { Exit-Usage "option '--$name' doesn't allow an argument" }
            }
            'required' {
                if ($null -eq $value) {
                    if ($i -ge $tokText.Count) { Exit-Usage "option '--$name' requires an argument" }
                    $value = $tokText[$i]; $i++
                }
            }
        }
        $key = if ($LongToShort.ContainsKey($name)) { $LongToShort[$name] } else { $name }
        Set-Option $key $value
        continue
    }

    # Cluster of short options, e.g. -sfv or -tDIR.
    $j = 1
    while ($j -lt $tok.Length) {
        $c = [string]$tok[$j]
        $j++
        if ('bdFfiLnPrsSTtv'.IndexOf($c, [StringComparison]::Ordinal) -lt 0) {
            Exit-Usage "invalid option -- $(Q $c)"
        }
        if ($c -ceq 'S' -or $c -ceq 't') {
            if ($j -lt $tok.Length) { $value = $tok.Substring($j) }
            elseif ($i -lt $tokText.Count) { $value = $tokText[$i]; $i++ }
            else { Exit-Usage "option requires an argument -- $(Q $c)" }
            Set-Option $c $value
            break
        }
        Set-Option $c $null
    }
}

# ---------------------------------------------------------------------------
# Validate options
# ---------------------------------------------------------------------------

if ($Opt.Relative -and -not $Opt.Symbolic) { Exit-Usage 'cannot do --relative without --symbolic' }

$Opt.BackupType = 'none'
if ($Opt.Backup) {
    if ($null -ne $Opt.BackupArg) {
        $Opt.BackupType = Get-BackupType $Opt.BackupArg 'backup type'
    }
    elseif ($env:VERSION_CONTROL) {
        $Opt.BackupType = Get-BackupType $env:VERSION_CONTROL '$VERSION_CONTROL'
    }
    else {
        $Opt.BackupType = 'existing'
    }
    if ($Opt.BackupType -eq 'none') { $Opt.Backup = $false }
}
$Opt.SuffixValue = '~'
$suffix = if ($null -ne $Opt.Suffix) { $Opt.Suffix } else { $env:SIMPLE_BACKUP_SUFFIX }
if ($suffix -and $suffix.IndexOfAny([char[]]'\/') -lt 0) { $Opt.SuffixValue = $suffix }

if ($null -ne $Opt.TargetDir -and $Opt.NoTargetDir) {
    Exit-Usage 'cannot combine --target-directory (-t) and --no-target-directory (-T)'
}

# ---------------------------------------------------------------------------
# Work out TARGET/LINK_NAME pairs
# ---------------------------------------------------------------------------

function Test-DirectoryOperand([string]$Path) {
    try { $full = Get-FullPath $Path } catch { return $false }
    $st = (Get-Stat $full $true).Stat
    if (-not $st -or -not $st.IsDirectory) { return $false }
    if ($Opt.NoDeref) {
        $lst = (Get-Stat $full $false).Stat
        if ($lst -and $lst.IsSymlink) { return $false }
    }
    return $true
}

if ($operands.Count -eq 0) { Exit-Usage 'missing file operand' }

$targets = $null
$destDir = $null
if ($null -ne $Opt.TargetDir) {
    try { $full = Get-FullPath $Opt.TargetDir } catch { Exit-Fail "target $(Q $Opt.TargetDir) is not a directory" }
    $r = Get-Stat $full $true
    if (-not $r.Stat) { Exit-Fail "failed to access $(Q $Opt.TargetDir): $(Get-ErrorText $r.Error)" }
    if (-not $r.Stat.IsDirectory) { Exit-Fail "target $(Q $Opt.TargetDir) is not a directory" }
    $targets = $operands
    $destDir = $Opt.TargetDir
}
elseif ($Opt.NoTargetDir) {
    if ($operands.Count -lt 2) { Exit-Usage "missing destination file operand after $(Q $operands[0])" }
    if ($operands.Count -gt 2) { Exit-Usage "extra operand $(Q $operands[2])" }
}
elseif ($operands.Count -eq 1) {
    $targets = $operands
    $destDir = '.'
}
elseif (Test-DirectoryOperand $operands[$operands.Count - 1]) {
    $destDir = $operands[$operands.Count - 1]
    $operands.RemoveAt($operands.Count - 1)
    $targets = $operands
}
elseif ($operands.Count -gt 2) {
    Exit-Fail "target $(Q $operands[$operands.Count - 1]) is not a directory"
}

if ($null -eq $destDir) {
    New-Link $operands[0] $operands[1]
}
else {
    foreach ($t in $targets) {
        $name = Get-BaseName $t
        if (-not $name) {
            Write-Err "$(Q $t): cannot determine link name"
            $Opt.Failed = $true
            continue
        }
        New-Link $t (Join-Display $destDir $name)
    }
}

if ($Opt.Failed) { exit 1 }
exit 0
