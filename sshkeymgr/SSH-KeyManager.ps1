<#
.SYNOPSIS
    SSH-KeyManager - a terminal UI for managing SSH keys on Windows.

.DESCRIPTION
    Lists the key pairs found in your .ssh directory and lets you:
      * copy a public key to the clipboard as one clean line (ready to paste into GitHub, GitLab, ...)
      * create a new key with GitHub-friendly defaults (Ed25519)
      * install a public key on a remote host, like ssh-copy-id
      * view key details (fingerprints, randomart) and recreate a missing .pub file

    Works with Windows PowerShell 5.1 (ships with Windows 11) and PowerShell 7+.
    Uses the Windows OpenSSH client (ssh.exe / ssh-keygen.exe), installed by default on Windows 11.
    No modules or other external dependencies.

    Keys:  Up/Down  select      Enter/C  copy public key     N  new key
           S  send to host      V  view details              P  recreate missing .pub
           O  open folder       R  refresh                   Q/Esc  quit

.PARAMETER SshDir
    Directory to manage. Defaults to %USERPROFILE%\.ssh (the directory Windows OpenSSH uses).

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\SSH-KeyManager.ps1

.EXAMPLE
    .\SSH-KeyManager.ps1 -SshDir D:\keys
#>
[CmdletBinding()]
param(
    [string]$SshDir = (Join-Path $env:USERPROFILE '.ssh')
)

# NOTE: this file is intentionally pure ASCII so Windows PowerShell 5.1 parses it correctly
# regardless of file encoding. Non-ASCII glyphs are built from [char] codes at runtime.

$ESC            = [char]27
$GitHubKeyUrl   = 'https://github.com/settings/ssh/new'
$DefaultIdNames = @('id_rsa', 'id_ecdsa', 'id_ecdsa_sk', 'id_ed25519', 'id_ed25519_sk', 'id_xmss', 'id_dsa')
$NonKeyFiles    = @('known_hosts', 'known_hosts.old', 'config', 'authorized_keys', 'authorized_keys2', 'environment', 'rc')

$script:Keys       = @()
$script:Sel        = 0
$script:Top        = 0
$script:ListRows   = 10
$script:Status     = ''
$script:StatusFg   = 37
$script:LastTarget = ''
$script:LastPort   = '22'
$script:ConModes   = $null

#region ---------- SSH key parsing -------------------------------------------------------------

function Read-UInt32 {
    param([byte[]]$Data, [ref]$Pos)
    $p = [int]$Pos.Value
    if ($p + 4 -gt $Data.Length) { throw 'Truncated SSH data' }
    $v = ([long]$Data[$p] -shl 24) -bor ([long]$Data[$p + 1] -shl 16) -bor ([long]$Data[$p + 2] -shl 8) -bor [long]$Data[$p + 3]
    $Pos.Value = $p + 4
    return $v
}

# Reads an SSH wire-format "string" (uint32 length + bytes).
function Read-SshString {
    param([byte[]]$Data, [ref]$Pos)
    $len = Read-UInt32 $Data $Pos
    $p = [int]$Pos.Value
    if ($p + $len -gt $Data.Length) { throw 'Truncated SSH data' }
    $out = New-Object byte[] $len
    if ($len -gt 0) { [Array]::Copy($Data, $p, $out, 0, $len) }
    $Pos.Value = $p + $len
    return , $out
}

function Get-MpintBits {
    param([byte[]]$Mpint)
    $i = 0
    while ($i -lt $Mpint.Length -and $Mpint[$i] -eq 0) { $i++ }
    if ($i -ge $Mpint.Length) { return 0 }
    $top = [int]$Mpint[$i]; $bits = 0
    while ($top -gt 0) { $bits++; $top = $top -shr 1 }
    return ($Mpint.Length - $i - 1) * 8 + $bits
}

function Get-KeyBits {
    param([string]$Type, [byte[]]$Blob)
    switch ($Type) {
        'ssh-ed25519'                        { return 256 }
        'sk-ssh-ed25519@openssh.com'         { return 256 }
        'ssh-ed448'                          { return 456 }
        'ecdsa-sha2-nistp256'                { return 256 }
        'sk-ecdsa-sha2-nistp256@openssh.com' { return 256 }
        'ecdsa-sha2-nistp384'                { return 384 }
        'ecdsa-sha2-nistp521'                { return 521 }
        'ssh-rsa' {
            $pos = 0
            $null = Read-SshString $Blob ([ref]$pos)      # type
            $null = Read-SshString $Blob ([ref]$pos)      # e
            return Get-MpintBits (Read-SshString $Blob ([ref]$pos))
        }
        'ssh-dss' {
            $pos = 0
            $null = Read-SshString $Blob ([ref]$pos)      # type
            return Get-MpintBits (Read-SshString $Blob ([ref]$pos))
        }
    }
    return $null
}

function Get-KeyLabel {
    param([string]$Type)
    switch ($Type) {
        'ssh-ed25519'                        { return 'ED25519' }
        'sk-ssh-ed25519@openssh.com'         { return 'ED25519-SK' }
        'ssh-ed448'                          { return 'ED448' }
        'ssh-rsa'                            { return 'RSA' }
        'ssh-dss'                            { return 'DSA' }
        'sk-ecdsa-sha2-nistp256@openssh.com' { return 'ECDSA-SK' }
    }
    if ($Type -like 'ecdsa-sha2-*')        { return 'ECDSA' }
    if ($Type -like '*-cert-v01@openssh.com') { return 'CERT' }
    if ($Type) { return $Type.ToUpperInvariant() }
    return '?'
}

# Parses the text of an OpenSSH public key file into a clean, single-line key plus metadata.
# Removes BOMs, zero-width characters, CR/LF, tabs and duplicate spaces so the result can be
# pasted into web forms without editing.
function ConvertFrom-PublicKeyText {
    param([string]$Text)
    $info = [pscustomobject]@{
        Type = $null; Blob = $null; Bytes = $null; Comment = ''; Line = $null
        Bits = $null; Fingerprint = $null; Md5 = $null; Error = $null
    }
    $clean = $Text -replace '[\u200B-\u200D\u2060\uFEFF]', ''
    foreach ($raw in ($clean -split '\r\n|\r|\n')) {
        $line = ($raw -replace '[\x00-\x1F\x7F]', ' ').Trim()
        if (-not $line -or $line.StartsWith('#')) { continue }
        $m = [regex]::Match($line, '^(\S+)\s+([A-Za-z0-9+/]+={0,2})(?:\s+(.*))?$')
        if (-not $m.Success) { break }
        $info.Type    = $m.Groups[1].Value
        $info.Blob    = $m.Groups[2].Value
        $info.Comment = ($m.Groups[3].Value -replace '\s+', ' ').Trim()
        try {
            $bytes = [Convert]::FromBase64String($info.Blob)
            $pos = 0
            $inner = [Text.Encoding]::ASCII.GetString((Read-SshString $bytes ([ref]$pos)))
            if ($inner -ne $info.Type) { $info.Error = "Key type '$($info.Type)' does not match key data ('$inner')"; return $info }
            $info.Bytes = $bytes
            $info.Bits  = Get-KeyBits $info.Type $bytes
            $sha = [Security.Cryptography.SHA256]::Create()
            $info.Fingerprint = 'SHA256:' + [Convert]::ToBase64String($sha.ComputeHash($bytes)).TrimEnd('=')
            try {
                $md5 = [Security.Cryptography.MD5]::Create()
                $info.Md5 = 'MD5:' + (($md5.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') }) -join ':')
            } catch { }   # MD5 is unavailable when FIPS mode is enforced
        } catch {
            $info.Error = 'Public key data is corrupt (invalid base64 or truncated)'
            return $info
        }
        $info.Line = $info.Type + ' ' + $info.Blob
        if ($info.Comment) { $info.Line += ' ' + $info.Comment }
        return $info
    }
    $info.Error = 'Not an OpenSSH public key (PuTTY/RFC4716 format?)'
    return $info
}

# Detects whether a file is a private key, whether it is passphrase protected, and (for the
# OpenSSH format) extracts the embedded public key, which is stored unencrypted.
function Get-PrivateKeyInfo {
    param([string]$Path)
    try { $text = [IO.File]::ReadAllText($Path) } catch { return $null }
    $m = [regex]::Match($text, '-----BEGIN ([A-Z0-9 ]*?)PRIVATE KEY-----')
    if (-not $m.Success) { return $null }
    $info = [pscustomobject]@{ Format = $m.Groups[1].Value.Trim(); Encrypted = $null; PubLine = $null; PubB64 = $null }
    switch ($info.Format) {
        'OPENSSH' {
            $body = [regex]::Match($text, '-----BEGIN OPENSSH PRIVATE KEY-----(.*?)-----END OPENSSH PRIVATE KEY-----', 'Singleline')
            if ($body.Success) {
                try {
                    $bytes = [Convert]::FromBase64String(($body.Groups[1].Value -replace '\s', ''))
                    if ($bytes.Length -gt 15 -and [Text.Encoding]::ASCII.GetString($bytes, 0, 14) -eq 'openssh-key-v1' -and $bytes[14] -eq 0) {
                        $pos = 15
                        $cipher = [Text.Encoding]::ASCII.GetString((Read-SshString $bytes ([ref]$pos)))
                        $null = Read-SshString $bytes ([ref]$pos)   # kdf name
                        $null = Read-SshString $bytes ([ref]$pos)   # kdf options
                        $null = Read-UInt32 $bytes ([ref]$pos)      # number of keys
                        $pub = Read-SshString $bytes ([ref]$pos)
                        $info.Encrypted = ($cipher -ne 'none')
                        $p2 = 0
                        $type = [Text.Encoding]::ASCII.GetString((Read-SshString $pub ([ref]$p2)))
                        $info.PubB64 = [Convert]::ToBase64String($pub)
                        $info.PubLine = "$type $($info.PubB64)"
                    }
                } catch { }
            }
        }
        'ENCRYPTED' { $info.Encrypted = $true }
        default     { $info.Encrypted = ($text -match 'Proc-Type:\s*4,ENCRYPTED') }
    }
    return $info
}

function New-KeyEntry {
    param([string]$Name)
    [pscustomobject]@{
        Name = $Name; PrivFile = $null; PubFile = $null; Priv = $null; Pub = $null; Key = $null
        Label = '?'; Bits = $null; Comment = ''; Modified = $null; State = ''; StateFg = 37
        Warning = $null; Derived = $false
    }
}

function Get-KeyEntries {
    if (-not (Test-Path -LiteralPath $SshDir -PathType Container)) { return @() }
    $map = @{}
    foreach ($f in @(Get-ChildItem -LiteralPath $SshDir -File -Force -ErrorAction SilentlyContinue)) {
        if ($f.Extension -eq '.pub') {
            $base = $f.Name.Substring(0, $f.Name.Length - 4)
            if (-not $map.ContainsKey($base)) { $map[$base] = New-KeyEntry $base }
            $map[$base].PubFile = $f
        } elseif ($NonKeyFiles -notcontains $f.Name -and $f.Length -gt 0 -and $f.Length -lt 65536) {
            $pi = Get-PrivateKeyInfo $f.FullName
            if ($pi) {
                if (-not $map.ContainsKey($f.Name)) { $map[$f.Name] = New-KeyEntry $f.Name }
                $map[$f.Name].PrivFile = $f
                $map[$f.Name].Priv = $pi
            }
        }
    }

    foreach ($e in $map.Values) {
        if ($e.PubFile) {
            try { $e.Pub = ConvertFrom-PublicKeyText ([IO.File]::ReadAllText($e.PubFile.FullName)) }
            catch { $e.Pub = [pscustomobject]@{ Error = "Cannot read file: $($_.Exception.Message)" } }
        }
        if ($e.Pub -and -not $e.Pub.Error) {
            $e.Key = $e.Pub
        } elseif ($e.Priv -and $e.Priv.PubLine) {
            $e.Key = ConvertFrom-PublicKeyText $e.Priv.PubLine
            $e.Derived = $true
        }

        if ($e.Key) {
            $e.Label = Get-KeyLabel $e.Key.Type
            $e.Bits = $e.Key.Bits
            $e.Comment = $e.Key.Comment
        } elseif ($e.Priv) {
            switch ($e.Priv.Format) { 'RSA' { $e.Label = 'RSA' } 'EC' { $e.Label = 'ECDSA' } 'DSA' { $e.Label = 'DSA' } }
        }

        if ($e.PrivFile) { $e.Modified = $e.PrivFile.LastWriteTime } else { $e.Modified = $e.PubFile.LastWriteTime }

        if ($e.Pub -and $e.Pub.Error) {
            $e.State = 'bad .pub'; $e.StateFg = 91; $e.Warning = "$($e.Name).pub: $($e.Pub.Error)"
        } elseif ($e.PrivFile -and $e.PubFile) {
            if ($e.Priv.PubB64 -and $e.Pub.Blob -and $e.Priv.PubB64 -ne $e.Pub.Blob) {
                $e.State = 'MISMATCH'; $e.StateFg = 91
                $e.Warning = 'The .pub file does NOT belong to this private key! Press P to recreate it.'
            } else {
                $e.State = 'pair'; $e.StateFg = 92
            }
        } elseif ($e.PubFile) {
            $e.State = 'pub only'; $e.StateFg = 33
        } else {
            $e.State = 'no .pub'; $e.StateFg = 93
        }

        if (-not $e.Warning) {
            if ($e.Label -eq 'DSA') {
                $e.Warning = 'DSA keys are obsolete and rejected by GitHub and modern OpenSSH. Create a new Ed25519 key.'
            } elseif ($e.Label -eq 'RSA' -and $e.Bits -and $e.Bits -lt 2048) {
                $e.Warning = "RSA-$($e.Bits) is too weak and is rejected by GitHub. Create a new Ed25519 key."
            }
        }
    }
    return @($map.Values | Sort-Object Name)
}

function Update-Keys {
    param([string]$SelectName)
    if (-not $SelectName -and $script:Keys.Count -gt 0 -and $script:Sel -lt $script:Keys.Count) {
        $SelectName = $script:Keys[$script:Sel].Name
    }
    $script:Keys = @(Get-KeyEntries)
    $script:Sel = 0
    for ($i = 0; $i -lt $script:Keys.Count; $i++) {
        if ($script:Keys[$i].Name -eq $SelectName) { $script:Sel = $i; break }
    }
}

function Get-SelectedKey {
    if ($script:Keys.Count -eq 0) { return $null }
    return $script:Keys[$script:Sel]
}

#endregion
#region ---------- Console / native helpers ----------------------------------------------------

function Initialize-NativeConsole {
    try {
        if (-not ('SshKeyManager.NativeConsole' -as [type])) {
            Add-Type -Namespace SshKeyManager -Name NativeConsole -ErrorAction Stop -MemberDefinition @'
[DllImport("kernel32.dll", SetLastError = true)] public static extern IntPtr GetStdHandle(int nStdHandle);
[DllImport("kernel32.dll", SetLastError = true)] public static extern bool GetConsoleMode(IntPtr hConsole, out uint mode);
[DllImport("kernel32.dll", SetLastError = true)] public static extern bool SetConsoleMode(IntPtr hConsole, uint mode);
'@
        }
        $in = [SshKeyManager.NativeConsole]::GetStdHandle(-10)
        $out = [SshKeyManager.NativeConsole]::GetStdHandle(-11)
        [uint32]$inMode = 0; [uint32]$outMode = 0
        if ([SshKeyManager.NativeConsole]::GetConsoleMode($in, [ref]$inMode) -and
            [SshKeyManager.NativeConsole]::GetConsoleMode($out, [ref]$outMode)) {
            $script:ConModes = @{ In = $in; Out = $out; InMode = $inMode; OutMode = $outMode }
        }
    } catch { $script:ConModes = $null }
    Restore-ConsoleMode
    if ($script:ConModes) { return $true }
    return [bool]$Host.UI.SupportsVirtualTerminal
}

# Restores the console modes captured at startup (child processes such as ssh.exe may change
# them) and makes sure ANSI escape processing is on.
function Restore-ConsoleMode {
    if (-not $script:ConModes) { return }
    $vtProcessing = 0x0004
    [void][SshKeyManager.NativeConsole]::SetConsoleMode($script:ConModes.In, $script:ConModes.InMode)
    [void][SshKeyManager.NativeConsole]::SetConsoleMode($script:ConModes.Out, ($script:ConModes.OutMode -bor $vtProcessing))
}

function Find-SshTool {
    param([string]$Name)
    # Prefer the Windows OpenSSH client over other copies on PATH (e.g. Git for Windows' MSYS build).
    foreach ($p in @("$env:WINDIR\System32\OpenSSH\$Name.exe", "$env:WINDIR\Sysnative\OpenSSH\$Name.exe")) {
        if (Test-Path -LiteralPath $p) { return $p }
    }
    $cmd = Get-Command "$Name.exe" -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cmd) { return $cmd.Path }
    return $null
}

# Quotes arguments using the MSVCRT rules, identically on PowerShell 5.1 and 7.
function ConvertTo-ArgumentString {
    param([string[]]$ArgumentList)
    $parts = foreach ($a in $ArgumentList) {
        if ($a.Length -gt 0 -and $a -notmatch '[\s"]') { $a; continue }
        $sb = New-Object System.Text.StringBuilder '"'
        $slashes = 0
        foreach ($ch in $a.ToCharArray()) {
            if ($ch -eq '\') { $slashes++; continue }
            if ($ch -eq '"') { [void]$sb.Append('\' * ($slashes * 2 + 1)).Append('"') }
            else { [void]$sb.Append('\' * $slashes).Append($ch) }
            $slashes = 0
        }
        [void]$sb.Append('\' * ($slashes * 2)).Append('"')
        $sb.ToString()
    }
    return ($parts -join ' ')
}

# Runs a console program attached to this console (so it can prompt for passwords/passphrases).
# With -CaptureOutput only stdout is captured; prompts and errors still reach the screen.
function Invoke-Native {
    param([string]$FilePath, [string[]]$ArgumentList, [switch]$CaptureOutput)
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $FilePath
    $psi.Arguments = ConvertTo-ArgumentString $ArgumentList
    $psi.UseShellExecute = $false
    if ($CaptureOutput) {
        $psi.RedirectStandardOutput = $true
        $psi.StandardOutputEncoding = New-Object System.Text.UTF8Encoding $false
    }
    [Console]::Write("$ESC[0m$ESC[?25h")
    $result = [pscustomobject]@{ ExitCode = -1; Output = '' }
    try {
        $proc = [System.Diagnostics.Process]::Start($psi)
        if ($CaptureOutput) { $result.Output = $proc.StandardOutput.ReadToEnd() }
        $proc.WaitForExit()
        $result.ExitCode = $proc.ExitCode
    } catch {
        Write-Text "Failed to start ${FilePath}: $($_.Exception.Message)" 91
    } finally {
        Restore-ConsoleMode
    }
    return $result
}

function Set-ClipboardText {
    param([string]$Text)
    $done = $false
    try {
        if ([Threading.Thread]::CurrentThread.GetApartmentState() -eq [Threading.ApartmentState]::STA) {
            Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
            [System.Windows.Forms.Clipboard]::SetDataObject($Text, $true, 10, 100)
            $done = $true
        }
    } catch { $done = $false }
    if (-not $done) {
        try { Set-Clipboard -Value $Text -ErrorAction Stop } catch { return $false }
    }
    # Read it back to prove the clipboard holds exactly the key, with no trailing newline.
    try { $check = Get-Clipboard -Raw -ErrorAction Stop } catch { return $true }
    return ([string]$check -ceq $Text)
}

function Write-Utf8File {
    param([string]$Path, [string]$Text, [switch]$Append)
    $enc = New-Object System.Text.UTF8Encoding $false   # OpenSSH cannot read files with a BOM
    if ($Append) { [IO.File]::AppendAllText($Path, $Text, $enc) } else { [IO.File]::WriteAllText($Path, $Text, $enc) }
}

#endregion
#region ---------- Rendering -------------------------------------------------------------------

# ANSI colors: 30-37 / 90-97 foreground, 40-47 / 100-107 background, 0 = default.
function Get-Sgr {
    param([int]$Fg, [int]$Bg = 0)
    if ($Fg -le 0) { $Fg = 39 }
    if ($Bg -le 0) { $Bg = 49 }
    return "$ESC[0;$Fg;${Bg}m"
}

# Renders segments (@{T = text; F = fg}) as one line exactly $Width columns wide.
function Format-Row {
    param([object[]]$Segments = @(), [int]$Width, [int]$Bg = 0)
    $sb = New-Object System.Text.StringBuilder
    $used = 0
    foreach ($seg in $Segments) {
        if ($used -ge $Width) { break }
        $text = [string]$seg.T
        if ($text.Length -gt ($Width - $used)) { $text = $text.Substring(0, $Width - $used) }
        [void]$sb.Append((Get-Sgr $seg.F $Bg)).Append($text)
        $used += $text.Length
    }
    if ($used -lt $Width) { [void]$sb.Append((Get-Sgr 39 $Bg)).Append(' ' * ($Width - $used)) }
    [void]$sb.Append("$ESC[0m")
    return $sb.ToString()
}

function Get-Fit {
    param([string]$Text, [int]$Width)
    if ($Width -le 0) { return '' }
    $Text = $Text -replace '[\x00-\x1F\x7F]', ' '
    if ($Text.Length -gt $Width) { return $Text.Substring(0, $Width - 1) + [char]0x2026 }
    return $Text.PadRight($Width)
}

function Get-TypeColor {
    param($Entry)
    switch ($Entry.Label) {
        'ED25519'    { return 92 }
        'ED448'      { return 92 }
        'ECDSA'      { return 96 }
        'ED25519-SK' { return 95 }
        'ECDSA-SK'   { return 95 }
        'CERT'       { return 35 }
        'DSA'        { return 91 }
        'RSA' {
            if (-not $Entry.Bits -or $Entry.Bits -ge 3072) { return 93 }
            if ($Entry.Bits -ge 2048) { return 33 }
            return 91
        }
    }
    return 90
}

function Show-Main {
    $cols = [Math]::Max(40, [Console]::WindowWidth - 1)
    $rows = [Math]::Max(16, [Console]::WindowHeight)
    $rule = [string][char]0x2500 * $cols
    $lines = New-Object 'System.Collections.Generic.List[string]'
    $keys = $script:Keys

    # Title bar
    $left = ' SSH Key Manager'
    $dirText = $SshDir
    if ($env:USERPROFILE -and $dirText.StartsWith($env:USERPROFILE, [StringComparison]::OrdinalIgnoreCase)) {
        $dirText = '~' + $dirText.Substring($env:USERPROFILE.Length)
    }
    $right = "$dirText  ($($keys.Count) key$(if ($keys.Count -ne 1) { 's' })) "
    $gap = ' ' * [Math]::Max(1, $cols - $left.Length - $right.Length)
    $lines.Add((Format-Row @(@{ T = $left; F = 97 }, @{ T = $gap; F = 97 }, @{ T = $right; F = 37 }) $cols 44))
    $lines.Add((Format-Row @() $cols))

    # Column widths
    $nameW = 4
    foreach ($k in $keys) { if ($k.Name.Length -gt $nameW) { $nameW = $k.Name.Length } }
    $nameW = [Math]::Min($nameW, 28)
    $fixed = 2 + $nameW + 2 + 10 + 2 + 5 + 2 + 4 + 2 + 9 + 2 + 10 + 2
    $commentW = [Math]::Max(0, $cols - $fixed)

    $hdr = '  ' + (Get-Fit 'NAME' $nameW) + '  ' + (Get-Fit 'TYPE' 10) + '  ' + 'BITS'.PadLeft(5) + '  ' +
           (Get-Fit 'PASS' 4) + '  ' + (Get-Fit 'FILES' 9) + '  ' + (Get-Fit 'MODIFIED' 10) + '  ' + 'COMMENT'
    $lines.Add((Format-Row @(@{ T = $hdr; F = 36 }) $cols))
    $lines.Add((Format-Row @(@{ T = $rule; F = 90 }) $cols))

    # Key list (scrolling)
    $listRows = [Math]::Max(3, $rows - 1 - 13)
    $script:ListRows = $listRows
    if ($script:Sel -lt $script:Top) { $script:Top = $script:Sel }
    if ($script:Sel -ge $script:Top + $listRows) { $script:Top = $script:Sel - $listRows + 1 }
    if ($script:Top -gt [Math]::Max(0, $keys.Count - $listRows)) { $script:Top = [Math]::Max(0, $keys.Count - $listRows) }

    for ($r = 0; $r -lt $listRows; $r++) {
        $i = $script:Top + $r
        if ($keys.Count -eq 0 -and $r -eq 0) {
            $lines.Add((Format-Row @(@{ T = "  No SSH keys found in $SshDir"; F = 93 }) $cols))
        } elseif ($keys.Count -eq 0 -and $r -eq 1) {
            $lines.Add((Format-Row @(@{ T = '  Press N to create one (Ed25519, recommended for GitHub).'; F = 37 }) $cols))
        } elseif ($i -lt $keys.Count) {
            $e = $keys[$i]
            $isSel = ($i -eq $script:Sel)
            $bg = 0; $marker = '  '
            if ($isSel) { $bg = 100; $marker = '> ' }
            $bits = ''
            if ($e.Bits) { $bits = [string]$e.Bits }
            if ($null -eq $e.Priv) { $pass = '-'; $passFg = 90 }
            elseif ($e.Priv.Encrypted -eq $true) { $pass = 'yes'; $passFg = 92 }
            elseif ($e.Priv.Encrypted -eq $false) { $pass = 'no'; $passFg = 93 }
            else { $pass = '?'; $passFg = 90 }
            $segs = @(
                @{ T = $marker; F = 93 },
                @{ T = (Get-Fit $e.Name $nameW); F = 97 },
                @{ T = '  ' + (Get-Fit $e.Label 10); F = (Get-TypeColor $e) },
                @{ T = '  ' + $bits.PadLeft(5); F = 37 },
                @{ T = '  ' + (Get-Fit $pass 4); F = $passFg },
                @{ T = '  ' + (Get-Fit $e.State 9); F = $e.StateFg },
                @{ T = '  ' + $e.Modified.ToString('yyyy-MM-dd'); F = 90 },
                @{ T = '  ' + (Get-Fit $e.Comment $commentW).TrimEnd(); F = 37 }
            )
            $lines.Add((Format-Row $segs $cols $bg))
        } else {
            $lines.Add((Format-Row @() $cols))
        }
    }
    $lines.Add((Format-Row @(@{ T = $rule; F = 90 }) $cols))

    # Details of the selected key
    $e = Get-SelectedKey
    $detail = @()
    if ($e) {
        $lblW = 13
        $fp = '(unknown)'
        if ($e.Key) { $fp = $e.Key.Fingerprint }
        $privTxt = '(missing)'; $privFg = 90
        if ($e.PrivFile) {
            $privTxt = $e.PrivFile.FullName; $privFg = 37
            if ($e.Priv.Encrypted -eq $true) { $privTxt += '   [passphrase protected]' }
            elseif ($e.Priv.Encrypted -eq $false) { $privTxt += '   [no passphrase]' }
        }
        $pubTxt = '(missing)'; $pubFg = 90
        if ($e.PubFile) { $pubTxt = $e.PubFile.FullName; $pubFg = 37 }
        $keyTxt = '(not available)'; $keyFg = 90
        if ($e.Key) {
            $keyTxt = $e.Key.Line; $keyFg = 32
            if ($e.Derived) { $keyTxt += '   (derived from private key)' }
        }
        if ($e.Warning) { $hint = $e.Warning; $hintFg = 91 }
        elseif (-not $e.PubFile) { $hint = 'No .pub file - press P to recreate it from the private key.'; $hintFg = 93 }
        else { $hint = "Press Enter to copy this key, then paste it at $GitHubKeyUrl"; $hintFg = 90 }
        $detail = @(
            @(@{ T = ' Fingerprint'.PadRight($lblW); F = 36 }, @{ T = $fp; F = 96 }),
            @(@{ T = ' Private'.PadRight($lblW); F = 36 }, @{ T = $privTxt; F = $privFg }),
            @(@{ T = ' Public'.PadRight($lblW); F = 36 }, @{ T = $pubTxt; F = $pubFg }),
            @(@{ T = ' Key'.PadRight($lblW); F = 36 }, @{ T = (Get-Fit $keyTxt ($cols - $lblW)); F = $keyFg }),
            @(, @{ T = " $hint"; F = $hintFg })
        )
    }
    for ($d = 0; $d -lt 5; $d++) {
        if ($d -lt $detail.Count) { $lines.Add((Format-Row $detail[$d] $cols)) }
        else { $lines.Add((Format-Row @() $cols)) }
    }
    $lines.Add((Format-Row @(@{ T = $rule; F = 90 }) $cols))

    # Footer: hotkeys and status
    $footer = New-Object System.Collections.ArrayList
    $arrows = [string][char]0x2191 + [char]0x2193
    foreach ($pair in @(@($arrows, 'Move'), @('Enter', 'Copy'), @('N', 'New'), @('S', 'Send to host'), @('V', 'View'),
                        @('P', 'Restore .pub'), @('O', 'Open folder'), @('R', 'Refresh'), @('Q', 'Quit'))) {
        [void]$footer.Add(@{ T = ' ' + $pair[0]; F = 93 })
        [void]$footer.Add(@{ T = ' ' + $pair[1] + ' '; F = 37 })
    }
    $lines.Add((Format-Row $footer.ToArray() $cols))
    $lines.Add((Format-Row @(@{ T = ' ' + $script:Status; F = $script:StatusFg }) $cols))

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append("$ESC[?25l")
    for ($i = 0; $i -lt $lines.Count; $i++) {
        [void]$sb.Append("$ESC[$($i + 1);1H").Append($lines[$i])
    }
    [void]$sb.Append("$ESC[$($lines.Count + 1);1H$ESC[0m$ESC[J")
    [Console]::Write($sb.ToString())
}

function Set-Status {
    param([string]$Message, [int]$Fg = 37)
    $script:Status = $Message
    $script:StatusFg = $Fg
}

#endregion
#region ---------- Dialog helpers --------------------------------------------------------------

function Clear-Screen {
    [Console]::Write("$ESC[0m$ESC[2J$ESC[H")
}

function Write-Title {
    param([string]$Title)
    $cols = [Math]::Max(40, [Console]::WindowWidth - 1)
    [Console]::Write((Format-Row @(@{ T = " $Title"; F = 97 }) $cols 44) + "`r`n`r`n")
}

function Write-Text {
    param([string]$Text = '', [int]$Fg = 37)
    [Console]::Write("$ESC[0;${Fg}m$Text$ESC[0m`r`n")
}

function Write-Field {
    param([string]$Label, [string]$Value, [int]$Fg = 37)
    [Console]::Write("$ESC[0;36m  $($Label.PadRight(14))$ESC[0;${Fg}m$Value$ESC[0m`r`n")
}

# Single-line editor with an editable default. Returns $null when the user presses Esc.
function Read-Input {
    param([string]$Prompt, [string]$Default = '')
    [Console]::Write("$ESC[0;96m$Prompt$ESC[0m $ESC[?25h")
    $buf = New-Object System.Text.StringBuilder $Default
    [Console]::Write($Default)
    while ($true) {
        $k = [Console]::ReadKey($true)
        if ($k.Key -eq 'Enter') { [Console]::Write("`r`n"); return $buf.ToString().Trim() }
        if ($k.Key -eq 'Escape') { [Console]::Write("$ESC[0;90m (cancelled)$ESC[0m`r`n"); return $null }
        if ($k.Key -eq 'Backspace') {
            if ($buf.Length -gt 0) { $buf.Length = $buf.Length - 1; [Console]::Write("`b `b") }
        } elseif (($k.Modifiers -band [ConsoleModifiers]::Control) -and $k.Key -eq 'U') {
            [Console]::Write(("`b `b") * $buf.Length); $buf.Length = 0
        } elseif (-not [char]::IsControl($k.KeyChar)) {
            [void]$buf.Append($k.KeyChar); [Console]::Write($k.KeyChar)
        }
    }
}

function Read-YesNo {
    param([string]$Prompt, [bool]$Default = $true)
    $hint = '[y/N]'
    if ($Default) { $hint = '[Y/n]' }
    [Console]::Write("$ESC[0;96m$Prompt$ESC[0m $hint $ESC[?25h")
    while ($true) {
        $k = [Console]::ReadKey($true)
        $c = [string]$k.KeyChar
        if ($k.Key -eq 'Enter') { $answer = $Default; break }
        if ($k.Key -eq 'Escape' -or $c -eq 'n') { $answer = $false; break }
        if ($c -eq 'y') { $answer = $true; break }
    }
    if ($answer) { Write-Text 'Yes' 97 } else { Write-Text 'No' 97 }
    return $answer
}

# Arrow-key menu. Returns the chosen index, or -1 when cancelled with Esc.
function Select-Option {
    param([string[]]$Options, [int]$Default = 0)
    $sel = $Default; $n = $Options.Count; $first = $true
    [Console]::Write("$ESC[?25l")
    while ($true) {
        if (-not $first) { [Console]::Write("$ESC[${n}A") }
        $first = $false
        for ($i = 0; $i -lt $n; $i++) {
            $text = " $($i + 1)) $($Options[$i]) "
            if ($i -eq $sel) { [Console]::Write("`r$ESC[2K  $ESC[0;30;106m>$text$ESC[0m`r`n") }
            else { [Console]::Write("`r$ESC[2K  $ESC[0;37m $text$ESC[0m`r`n") }
        }
        $k = [Console]::ReadKey($true)
        if ($k.Key -eq 'UpArrow') { $sel = ($sel - 1 + $n) % $n }
        elseif ($k.Key -eq 'DownArrow') { $sel = ($sel + 1) % $n }
        elseif ($k.Key -eq 'Enter') { Write-Text; return $sel }
        elseif ($k.Key -eq 'Escape') { Write-Text; return -1 }
        elseif ([string]$k.KeyChar -match '^[1-9]$' -and [int][string]$k.KeyChar -le $n) { $sel = [int][string]$k.KeyChar - 1 }
    }
}

function Wait-AnyKey {
    [Console]::Write("`r`n$ESC[0;90m  Press any key to return to the key list...$ESC[0m$ESC[?25l")
    while ([Console]::KeyAvailable) { [void][Console]::ReadKey($true) }
    [void][Console]::ReadKey($true)
}

#endregion
#region ---------- Actions ---------------------------------------------------------------------

function Invoke-CopyKey {
    param($Entry)
    if (-not $Entry) { Set-Status 'No key selected.' 93; return }
    if (-not $Entry.Key) {
        if ($Entry.Warning) { Set-Status "Cannot copy: $($Entry.Warning)" 91 }
        else { Set-Status 'No public key available - press P to recreate the .pub file from the private key.' 93 }
        return
    }
    if (Set-ClipboardText $Entry.Key.Line) {
        $msg = "Copied $($Entry.Name) public key ($($Entry.Label), $($Entry.Key.Line.Length) chars, one line) - paste at $GitHubKeyUrl"
        if ($Entry.Derived) { $msg = "Copied $($Entry.Name) public key (derived from private key, no comment) - consider pressing P to save a .pub" }
        Set-Status $msg 92
    } else {
        Set-Status 'Could not copy to the clipboard (clipboard in use or unavailable). Try again.' 91
    }
}

function Invoke-NewKey {
    Clear-Screen
    Write-Title 'Create a new SSH key'
    $keygen = Find-SshTool 'ssh-keygen'
    if (-not $keygen) {
        Write-Text 'ssh-keygen.exe was not found. Install "OpenSSH Client" under Settings > System > Optional features.' 91
        Wait-AnyKey; return
    }

    Write-Text 'Key type:' 97
    $types = @(
        @{ Label = 'Ed25519       recommended: fast, secure, supported by GitHub/GitLab/Bitbucket'; Type = 'ed25519'; Bits = $null; File = 'id_ed25519' },
        @{ Label = 'RSA 4096      only for old servers that do not support Ed25519'; Type = 'rsa'; Bits = '4096'; File = 'id_rsa' },
        @{ Label = 'Ed25519-SK    stored on a FIDO2 security key (YubiKey etc.), needs the device'; Type = 'ed25519-sk'; Bits = $null; File = 'id_ed25519_sk' }
    )
    $choice = Select-Option @($types | ForEach-Object { $_.Label }) 0
    if ($choice -lt 0) { Set-Status 'Key creation cancelled.' 93; return }
    $t = $types[$choice]

    $defaultComment = ''
    if (Get-Command git.exe -CommandType Application -ErrorAction SilentlyContinue) {
        try { $defaultComment = [string](& git.exe config --get user.email 2>$null | Select-Object -First 1) } catch { }
    }
    if (-not $defaultComment) { $defaultComment = "$env:USERNAME@$env:COMPUTERNAME".ToLowerInvariant() }
    Write-Text 'The comment is a label shown next to the key; GitHub suggests your e-mail address.' 90
    $comment = Read-Input 'Comment:' $defaultComment
    if ($null -eq $comment) { Set-Status 'Key creation cancelled.' 93; return }
    $comment = ($comment -replace '[\x00-\x1F\x7F"]', '' -replace '\s+', ' ').Trim()

    $default = $t.File
    $n = 1
    while ((Test-Path -LiteralPath (Join-Path $SshDir $default)) -or (Test-Path -LiteralPath (Join-Path $SshDir "$default.pub"))) {
        $default = $t.File + '_github'
        if ($n -gt 1) { $default += $n }
        $n++
    }
    Write-Text
    Write-Text "Keys are saved in $SshDir" 90
    while ($true) {
        $name = Read-Input 'File name:' $default
        if ($null -eq $name -or $name -eq '') { Set-Status 'Key creation cancelled.' 93; return }
        if ($name -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$' -or $name -like '*.pub') {
            Write-Text '  Use letters, digits, dot, dash or underscore only (no path, no .pub).' 91; continue
        }
        $path = Join-Path $SshDir $name
        if ((Test-Path -LiteralPath $path) -or (Test-Path -LiteralPath "$path.pub")) {
            Write-Text "  $name already exists - choose another name (existing keys are never overwritten)." 91; continue
        }
        break
    }

    $kgArgs = @('-t', $t.Type)
    if ($t.Bits) { $kgArgs += @('-b', $t.Bits) }
    if ($comment) { $kgArgs += @('-C', $comment) }
    $kgArgs += @('-f', $path)

    Write-Text
    Write-Text ('Running: ssh-keygen ' + (ConvertTo-ArgumentString $kgArgs)) 90
    Write-Text 'ssh-keygen will ask for a passphrase. A passphrase is strongly recommended - it protects' 93
    Write-Text 'the key if this computer is compromised. Press Enter twice for no passphrase.' 93
    if ($t.Type -like '*-sk') { Write-Text 'Touch your security key when it blinks.' 93 }
    Write-Text

    if (-not (Test-Path -LiteralPath $SshDir)) { New-Item -ItemType Directory -Path $SshDir -Force | Out-Null }
    $r = Invoke-Native $keygen $kgArgs
    Write-Text
    if ($r.ExitCode -ne 0 -or -not (Test-Path -LiteralPath "$path.pub")) {
        Write-Text "ssh-keygen failed (exit code $($r.ExitCode)). No key was created." 91
        Set-Status 'Key creation failed.' 91
        Wait-AnyKey; return
    }

    Update-Keys -SelectName $name
    $entry = Get-SelectedKey
    Write-Text "Created $path and $path.pub" 92
    if ($entry -and $entry.Key) { Write-Field 'Fingerprint' $entry.Key.Fingerprint 96 }
    Write-Text
    Set-Status "Created new key $name." 92

    if ($entry -and $entry.Key -and (Read-YesNo 'Copy the public key to the clipboard now?' $true)) {
        Invoke-CopyKey $entry
        if ($script:StatusFg -eq 92) {
            Write-Text "Copied. Add it to GitHub at $GitHubKeyUrl (Title: this computer's name, Type: Authentication Key)." 92
        } else { Write-Text $script:Status 91 }
    }

    if ($DefaultIdNames -notcontains $name) {
        Write-Text
        Write-Text "ssh only uses keys with default names (id_ed25519, id_rsa, ...) automatically." 90
        if (Read-YesNo "Add a 'Host github.com' entry to $SshDir\config that uses this key?" $true) {
            Add-GitHubConfig $name
        }
    }
    Write-Text
    Write-Text "Test the GitHub connection with:  ssh -T git@github.com" 90
    Wait-AnyKey
}

function Add-GitHubConfig {
    param([string]$Name)
    $cfg = Join-Path $SshDir 'config'
    $existing = ''
    if (Test-Path -LiteralPath $cfg) {
        $bytes = [IO.File]::ReadAllBytes($cfg)
        if ($bytes.Length -ge 2 -and (($bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) -or ($bytes[0] -eq 0xFE -and $bytes[1] -eq 0xFF))) {
            Write-Text "  $cfg is saved as UTF-16, which OpenSSH cannot read. Re-save it as UTF-8 and add the entry manually." 91
            return
        }
        $existing = [IO.File]::ReadAllText($cfg)
        if ($existing -match '(?im)^\s*Host\s+(?:.*\s)?github\.com(?:\s|$)') {
            Write-Text "  $cfg already has a 'Host github.com' section. Add this line to it manually:" 93
            Write-Text "      IdentityFile ~/.ssh/$Name" 97
            return
        }
    }
    $block = "Host github.com`n    HostName github.com`n    User git`n    IdentityFile ~/.ssh/$Name`n    IdentitiesOnly yes`n"
    if ($existing.Length -gt 0) {
        if (-not $existing.EndsWith("`n")) { $block = "`n`n" + $block } else { $block = "`n" + $block }
    }
    try {
        Write-Utf8File -Path $cfg -Text $block -Append
        Write-Text "  Added to ${cfg}:" 92
        foreach ($l in ($block.Trim() -split "`n")) { Write-Text "      $l" 37 }
    } catch {
        Write-Text "  Could not write ${cfg}: $($_.Exception.Message)" 91
    }
}

# Builds the remote shell command that installs a key idempotently, like ssh-copy-id.
# The key line only contains shell-safe characters, so no quoting is needed inside sh -c '...'.
function Get-RemoteInstallCommand {
    param([string]$KeyLine, [string]$Blob)
    $ak = '~/.ssh/authorized_keys'
    $sh = "umask 077; mkdir -p ~/.ssh && chmod 700 ~/.ssh && touch $ak && chmod 600 $ak || exit 1; " +
          "if grep -qF $Blob $ak; then echo SSHKM:EXISTS; else " +
          "tail -c1 $ak | grep -q . && echo >> $ak; " +
          "echo $KeyLine >> $ak && echo SSHKM:ADDED; fi; " +
          "command -v restorecon >/dev/null 2>&1 && restorecon -F ~/.ssh $ak >/dev/null 2>&1; exit 0"
    return "exec sh -c '$sh'"
}

function Invoke-SendKey {
    param($Entry)
    if (-not $Entry) { Set-Status 'No key selected.' 93; return }
    if (-not $Entry.Key) { Set-Status 'This entry has no usable public key - press P to recreate it first.' 93; return }
    Clear-Screen
    Write-Title "Send public key to a remote host (like ssh-copy-id)"
    $ssh = Find-SshTool 'ssh'
    if (-not $ssh) {
        Write-Text 'ssh.exe was not found. Install "OpenSSH Client" under Settings > System > Optional features.' 91
        Wait-AnyKey; return
    }

    Write-Field 'Key' "$($Entry.Name)  ($($Entry.Label))" 97
    Write-Field 'Fingerprint' $Entry.Key.Fingerprint 96
    Write-Text
    Write-Text 'The key is appended to ~/.ssh/authorized_keys on the remote host (Linux, macOS, BSD).' 90
    Write-Text 'You will be asked for your password on the remote host. Esc cancels.' 90
    Write-Text

    $target = $null
    while ($true) {
        $defaultTarget = $script:LastTarget
        if (-not $defaultTarget) { $defaultTarget = "$env:USERNAME@".ToLowerInvariant() }
        $target = Read-Input 'Remote (user@host or ssh config alias):' $defaultTarget
        if ($null -eq $target -or $target -eq '') { Set-Status 'Send cancelled.' 93; return }
        if ($target -match '^-' -or $target -match '[\s''"`;&|<>()$\\]' -or $target.EndsWith('@')) {
            Write-Text '  Enter a destination such as alice@server.example.com or an alias from ~/.ssh/config.' 91; continue
        }
        break
    }
    while ($true) {
        $port = Read-Input 'Port:' $script:LastPort
        if ($null -eq $port) { Set-Status 'Send cancelled.' 93; return }
        $pn = 0
        if ([int]::TryParse($port, [ref]$pn) -and $pn -ge 1 -and $pn -le 65535) { break }
        Write-Text '  Port must be a number between 1 and 65535.' 91
    }
    $script:LastTarget = $target
    $script:LastPort = $port

    # Keep only shell-safe characters in the comment; the key material itself is always safe.
    $safeComment = (($Entry.Key.Comment -replace '[^A-Za-z0-9@._+,:=/ -]', '_') -replace '\s+', ' ').Trim()
    $keyLine = "$($Entry.Key.Type) $($Entry.Key.Blob)"
    if ($safeComment) { $keyLine += " $safeComment" }
    if ($safeComment -ne $Entry.Key.Comment) { Write-Text "  Note: comment will be stored as '$safeComment' (special characters replaced)." 93 }

    Write-Text
    Write-Text "Connecting to $target on port $port ..." 90
    $sshArgs = @('-p', $port, '-o', 'ConnectTimeout=15', $target, (Get-RemoteInstallCommand $keyLine $Entry.Key.Blob))
    $r = Invoke-Native $ssh $sshArgs -CaptureOutput
    Write-Text
    if ($r.Output -match 'SSHKM:ADDED') {
        Write-Text "Key installed on $target." 92
        Set-Status "Installed $($Entry.Name) on $target." 92
    } elseif ($r.Output -match 'SSHKM:EXISTS') {
        Write-Text "The key is already installed on $target - nothing changed." 93
        Set-Status "$($Entry.Name) was already installed on $target." 93
    } else {
        Write-Text "Failed to install the key (ssh exit code $($r.ExitCode))." 91
        if ($r.Output.Trim()) { Write-Text $r.Output.Trim() 37 }
        Write-Text 'Check the host name, user name and password. Windows SSH servers are not supported.' 90
        Set-Status "Sending key to $target failed." 91
        Wait-AnyKey; return
    }

    if ($Entry.PrivFile) {
        Write-Text
        if (Read-YesNo 'Test logging in with this key now?' $true) {
            Write-Text
            $testArgs = @('-p', $port, '-o', 'ConnectTimeout=15', '-o', 'PreferredAuthentications=publickey',
                          '-o', 'IdentitiesOnly=yes', '-i', $Entry.PrivFile.FullName, $target, 'echo SSHKM:LOGIN-OK')
            $t = Invoke-Native $ssh $testArgs -CaptureOutput
            if ($t.Output -match 'SSHKM:LOGIN-OK') {
                Write-Text "Success: key login to $target works. Connect with:" 92
                $cmd = "ssh $target"
                if ($port -ne '22') { $cmd = "ssh -p $port $target" }
                Write-Text "    $cmd" 97
            } else {
                Write-Text "Key login test failed (exit code $($t.ExitCode)). The server may not allow this key type" 91
                Write-Text 'or may use a non-standard AuthorizedKeysFile location.' 91
            }
        }
    }
    Wait-AnyKey
}

function Invoke-ViewKey {
    param($Entry)
    if (-not $Entry) { Set-Status 'No key selected.' 93; return }
    Clear-Screen
    Write-Title "Key details: $($Entry.Name)"
    $k = $Entry.Key
    if ($k) {
        Write-Field 'Algorithm' "$($Entry.Label)  ($($k.Type))" (Get-TypeColor $Entry)
        if ($Entry.Bits) { Write-Field 'Bits' $Entry.Bits }
        Write-Field 'Comment' $k.Comment
        Write-Field 'SHA256' $k.Fingerprint 96
        if ($k.Md5) { Write-Field 'MD5' $k.Md5 90 }
    } else {
        Write-Field 'Algorithm' $Entry.Label
    }
    if ($Entry.PrivFile) {
        $pp = 'unknown'
        if ($Entry.Priv.Encrypted -eq $true) { $pp = 'yes' } elseif ($Entry.Priv.Encrypted -eq $false) { $pp = 'NO' }
        Write-Field 'Private key' $Entry.PrivFile.FullName
        $fmt = $Entry.Priv.Format
        if (-not $fmt) { $fmt = 'PKCS#8' }
        Write-Field 'Format' $fmt
        Write-Field 'Passphrase' $pp
    } else {
        Write-Field 'Private key' '(missing - this key cannot be used to log in from this computer)' 90
    }
    if ($Entry.PubFile) { Write-Field 'Public key' $Entry.PubFile.FullName } else { Write-Field 'Public key' '(missing)' 90 }
    Write-Field 'Modified' $Entry.Modified.ToString('yyyy-MM-dd HH:mm')
    if ($Entry.Warning) { Write-Text; Write-Text "  $($Entry.Warning)" 91 }

    if ($k) {
        Write-Text
        Write-Text '  Public key (what Enter copies):' 36
        Write-Text $k.Line 32
        $keygen = Find-SshTool 'ssh-keygen'
        if ($keygen -and $Entry.PubFile -and -not $Entry.Pub.Error) {
            $r = Invoke-Native $keygen @('-lv', '-f', $Entry.PubFile.FullName) -CaptureOutput
            if ($r.ExitCode -eq 0) {
                Write-Text
                foreach ($l in ($r.Output -split '\r?\n' | Select-Object -Skip 1)) { if ($l) { Write-Text "  $l" 90 } }
            }
        }
    }
    Wait-AnyKey
}

function Invoke-RestorePub {
    param($Entry)
    if (-not $Entry) { Set-Status 'No key selected.' 93; return }
    if (-not $Entry.PrivFile) { Set-Status 'There is no private key to recreate the public key from.' 93; return }
    if ($Entry.PubFile -and $Entry.State -eq 'pair') { Set-Status "$($Entry.Name).pub already exists and matches the private key." 93; return }
    Clear-Screen
    Write-Title "Recreate $($Entry.Name).pub"
    $keygen = Find-SshTool 'ssh-keygen'
    if (-not $keygen) {
        Write-Text 'ssh-keygen.exe was not found. Install "OpenSSH Client" under Settings > System > Optional features.' 91
        Wait-AnyKey; return
    }
    $pubPath = $Entry.PrivFile.FullName + '.pub'
    if ($Entry.PubFile) {
        Write-Text "The existing $($Entry.Name).pub is invalid or belongs to a different key." 93
        if (-not (Read-YesNo "Replace it (the old file is renamed to $($Entry.Name).pub.bak)?" $false)) { Set-Status 'Cancelled.' 93; return }
    }
    Write-Text 'Reading the public key from the private key. If it has a passphrase, ssh-keygen will ask for it.' 90
    Write-Text
    $r = Invoke-Native $keygen @('-y', '-f', $Entry.PrivFile.FullName) -CaptureOutput
    $info = $null
    if ($r.ExitCode -eq 0 -and $r.Output) { $info = ConvertFrom-PublicKeyText $r.Output }
    if (-not $info -or $info.Error) {
        Write-Text "ssh-keygen could not read the private key (exit code $($r.ExitCode))." 91
        Set-Status "Could not recreate $($Entry.Name).pub." 91
        Wait-AnyKey; return
    }
    try {
        if (Test-Path -LiteralPath $pubPath) { Move-Item -LiteralPath $pubPath -Destination "$pubPath.bak" -Force }
        Write-Utf8File -Path $pubPath -Text ($info.Line + "`n")
    } catch {
        Write-Text "Could not write ${pubPath}: $($_.Exception.Message)" 91
        Wait-AnyKey; return
    }
    Update-Keys -SelectName $Entry.Name
    Set-Status "Recreated $pubPath" 92
}

function Invoke-OpenFolder {
    if (-not (Test-Path -LiteralPath $SshDir)) { Set-Status "$SshDir does not exist yet." 93; return }
    Invoke-Item -LiteralPath $SshDir
    Set-Status "Opened $SshDir in Explorer." 37
}

#endregion
#region ---------- Main loop -------------------------------------------------------------------

function Start-KeyManager {
    if ($Host.Name -notmatch 'ConsoleHost|Visual Studio Code Host') {
        Write-Error "SSH-KeyManager needs an interactive console (current host: $($Host.Name)). Run it from Windows Terminal or powershell.exe."
        return
    }
    try { [void][Console]::KeyAvailable } catch {
        Write-Error 'SSH-KeyManager needs an interactive console; input is redirected.'
        return
    }
    if (-not (Initialize-NativeConsole)) {
        Write-Error 'This console does not support ANSI escape sequences. Use Windows Terminal or Windows 10/11 console.'
        return
    }

    $origEncoding = [Console]::OutputEncoding
    try {
        [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false
        [Console]::Write("$ESC[?1049h$ESC[?25l")     # alternate screen, hide cursor
        Update-Keys
        if ($script:Keys.Count -gt 0) { Set-Status "Found $($script:Keys.Count) key(s). Press Enter to copy the selected public key." 37 }
        else { Set-Status 'Press N to create your first SSH key.' 93 }

        while ($true) {
            $w = [Console]::WindowWidth; $h = [Console]::WindowHeight
            Show-Main
            while (-not [Console]::KeyAvailable) {
                Start-Sleep -Milliseconds 50
                if ([Console]::WindowWidth -ne $w -or [Console]::WindowHeight -ne $h) {
                    $w = [Console]::WindowWidth; $h = [Console]::WindowHeight
                    [Console]::Write("$ESC[2J")
                    Show-Main
                }
            }
            $k = [Console]::ReadKey($true)
            $c = [string]$k.KeyChar
            $count = $script:Keys.Count

            if ($k.Key -eq 'UpArrow' -or $c -eq 'k') { $script:Sel-- }
            elseif ($k.Key -eq 'DownArrow' -or $c -eq 'j') { $script:Sel++ }
            elseif ($k.Key -eq 'PageUp') { $script:Sel -= $script:ListRows }
            elseif ($k.Key -eq 'PageDown') { $script:Sel += $script:ListRows }
            elseif ($k.Key -eq 'Home') { $script:Sel = 0 }
            elseif ($k.Key -eq 'End') { $script:Sel = $count - 1 }
            elseif ($k.Key -eq 'Enter' -or $c -eq 'c') { Invoke-CopyKey (Get-SelectedKey) }
            elseif ($c -eq 'n') { Invoke-NewKey }
            elseif ($c -eq 's') { Invoke-SendKey (Get-SelectedKey) }
            elseif ($c -eq 'v') { Invoke-ViewKey (Get-SelectedKey) }
            elseif ($c -eq 'p') { Invoke-RestorePub (Get-SelectedKey) }
            elseif ($c -eq 'o') { Invoke-OpenFolder }
            elseif ($c -eq 'r' -or $k.Key -eq 'F5') { Update-Keys; Set-Status "Refreshed - $($script:Keys.Count) key(s)." 37 }
            elseif ($c -eq 'q' -or $k.Key -eq 'Escape') { break }

            if ($script:Sel -ge $script:Keys.Count) { $script:Sel = $script:Keys.Count - 1 }
            if ($script:Sel -lt 0) { $script:Sel = 0 }
        }
    } finally {
        [Console]::Write("$ESC[0m$ESC[?25h$ESC[?1049l")   # restore normal screen and cursor
        [Console]::OutputEncoding = $origEncoding
        Restore-ConsoleMode
    }
}

#endregion

# Dot-sourcing (". .\SSH-KeyManager.ps1") loads the functions without starting the UI.
if ($MyInvocation.InvocationName -ne '.') { Start-KeyManager }
