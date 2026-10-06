<#
.SYNOPSIS
Use locally available keys to authorise logins on a remote machine.

.DESCRIPTION
A PowerShell drop-in replacement for the OpenSSH ssh-copy-id script. It runs on
the Windows PowerShell 5.1 that ships with Windows 11 and uses the Windows
OpenSSH client (ssh.exe, ssh-add.exe, sftp.exe). No other dependencies.

Usage: SSH-CopyId.ps1 [-h|-?|-f|-n|-s|-x] [-i [identity_file]] [-p port]
                      [-F alternative ssh_config file] [-t target_path]
                      [[-o <ssh -o options>] ...] [user@]hostname

  -i identity_file  Use only the key(s) contained in identity_file. If the
                    filename does not end in .pub this is added. If the
                    filename is omitted, the default_ID_file is used.
  -f                Force mode: don't check whether the keys are already
                    installed on the remote server (the private key is not
                    needed).
  -n                Dry run: print the key(s) that would have been installed.
  -s                Use sftp instead of executing remote commands (useful if
                    the remote only allows sftp).
  -x                Debug: print the commands being executed.
  -t target_path    Path on the remote host to install the keys into
                    (default: .ssh/authorized_keys).
  -p port, -o ssh_option, -F ssh_config
                    Passed through untouched to ssh.
  -h, -?            Print usage summary.

Without -i, keys listed by 'ssh-add -L' are used if there are any; otherwise
the default_ID_file is used. The default_ID_file is the most recently modified
file matching ~/.ssh/id*.pub (excluding ~/.ssh/*-cert.pub).

Remote hosts running OpenSSH for Windows are detected automatically; keys are
installed into %USERPROFILE%\.ssh\authorized_keys, or into
%ProgramData%\ssh\administrators_authorized_keys for members of the
Administrators group when sshd_config uses the default 'Match Group
administrators' block.

.EXAMPLE
SSH-CopyId.ps1 user@server

.EXAMPLE
SSH-CopyId.ps1 -i ~/.ssh/id_ed25519.pub -p 2222 user@server

.LINK
ssh-copy-id(1)
#>

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$ScriptArgs = @($args)
$ProgName = [IO.Path]::GetFileNameWithoutExtension($MyInvocation.MyCommand.Name)
$Utf8NoBom = New-Object Text.UTF8Encoding $false
$script:DebugMode = $false

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------

function Write-Log([string]$Level, [string]$Text) {
    [Console]::Error.WriteLine(('{0}: {1}: {2}' -f $ProgName, $Level, $Text))
}

function Exit-WithError([string]$Text) {
    Write-Log 'ERROR' $Text
    exit 1
}

function Show-Usage([string]$Problem) {
    if ($Problem) { [Console]::Error.WriteLine(('{0}: {1}' -f $ProgName, $Problem)) }
    $usage = @"
Usage: $ProgName [-h|-?|-f|-n|-s|-x] [-i [identity_file]] [-p port] [-F alternative ssh_config file] [-t target_path] [[-o <ssh -o options>] ...] [user@]hostname
	-f: force mode -- copy keys without trying to check if they are already installed
	-n: dry run    -- no keys are actually copied
	-s: use sftp   -- use sftp instead of executing remote-commands. Can be useful if the remote only allows sftp
	-x: debug      -- print the commands being executed, for debugging
	-h|-?: print this help
"@
    [Console]::Error.WriteLine($usage)
    exit 1
}

# Quote a string for display the way a POSIX shell would ('...').
function ConvertTo-ShellQuoted([string]$Text) {
    return "'" + $Text.Replace("'", "'\''") + "'"
}

# ---------------------------------------------------------------------------
# Native process helpers (Windows PowerShell 5.1 / .NET Framework compatible)
# ---------------------------------------------------------------------------

# Quote one argument following the MSVCRT / CommandLineToArgvW rules.
function ConvertTo-WinArg([string]$Arg) {
    if ($Arg.Length -gt 0 -and $Arg -notmatch '[\s"]') { return $Arg }
    $sb = New-Object Text.StringBuilder
    [void]$sb.Append('"')
    $slashes = 0
    foreach ($c in $Arg.ToCharArray()) {
        if ($c -eq [char]'\') { $slashes++; continue }
        if ($c -eq [char]'"') {
            [void]$sb.Append([char]'\', 2 * $slashes + 1)
        } elseif ($slashes -gt 0) {
            [void]$sb.Append([char]'\', $slashes)
        }
        $slashes = 0
        [void]$sb.Append($c)
    }
    [void]$sb.Append([char]'\', 2 * $slashes)
    [void]$sb.Append('"')
    return $sb.ToString()
}

# Run a native executable. stdin is always a pipe: it receives $InputText (if
# any) and is then closed, so the child never steals the console's stdin.
# Password / passphrase / host-key prompts from ssh go straight to the console.
function Invoke-Native {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [string[]]$Arguments = @(),
        [string]$InputText = $null,
        [switch]$Capture
    )
    $argLine = (@($Arguments) | ForEach-Object { ConvertTo-WinArg ([string]$_) }) -join ' '
    if ($script:DebugMode) { [Console]::Error.WriteLine("+ $FilePath $argLine") }

    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = $FilePath
    $psi.Arguments = $argLine
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true
    if ($Capture) {
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
    }

    # .NET Framework writes the console input encoding's preamble (BOM) into a
    # redirected stdin; make sure there is none while the process starts.
    $savedEncoding = $null
    try {
        if ([Console]::InputEncoding.GetPreamble().Length -gt 0) {
            $savedEncoding = [Console]::InputEncoding
            [Console]::InputEncoding = $Utf8NoBom
        }
    } catch { $savedEncoding = $null }

    try {
        $proc = [Diagnostics.Process]::Start($psi)
    } finally {
        if ($savedEncoding) { try { [Console]::InputEncoding = $savedEncoding } catch { } }
    }

    $outTask = $null; $errTask = $null
    if ($Capture) {
        $outTask = $proc.StandardOutput.ReadToEndAsync()
        $errTask = $proc.StandardError.ReadToEndAsync()
    }
    try {
        if ($InputText) {
            $bytes = $Utf8NoBom.GetBytes($InputText)
            $proc.StandardInput.BaseStream.Write($bytes, 0, $bytes.Length)
            $proc.StandardInput.BaseStream.Flush()
        }
        $proc.StandardInput.Close()
    } catch {
        # The child may have exited before reading its input; its exit code tells the story.
    }
    $proc.WaitForExit()

    $out = ''; $err = ''
    if ($Capture) { $out = $outTask.Result; $err = $errTask.Result }
    $code = $proc.ExitCode
    $proc.Dispose()
    return New-Object PSObject -Property @{ ExitCode = $code; StdOut = $out; StdErr = $err; Output = ($out + $err) }
}

function Find-Executable([string]$Name, [string]$PreferDir) {
    if ($PreferDir) {
        $candidate = Join-Path $PreferDir "$Name.exe"
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
    }
    $cmd = Get-Command $Name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cmd) { return $cmd.Path }
    $fallback = Join-Path $env:SystemRoot "System32\OpenSSH\$Name.exe"
    if (Test-Path -LiteralPath $fallback -PathType Leaf) { return $fallback }
    return $null
}

function New-TempDir {
    $dir = Join-Path ([IO.Path]::GetTempPath()) ('ssh-copy-id.' + [Guid]::NewGuid().ToString('N').Substring(0, 10))
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    return $dir
}

# ---------------------------------------------------------------------------
# Key discovery
# ---------------------------------------------------------------------------

function Resolve-LocalPath([string]$Path) {
    if ($Path -eq '~') { $Path = $HOME }
    elseif ($Path -match '^~[\\/]') { $Path = Join-Path $HOME $Path.Substring(2) }
    return $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
}

function Get-DefaultIdFile {
    $sshDir = Join-Path $HOME '.ssh'
    if (-not (Test-Path -LiteralPath $sshDir -PathType Container)) { return $null }
    $file = Get-ChildItem -LiteralPath $sshDir -Filter 'id*.pub' -File -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like 'id*.pub' -and $_.Name -notlike '*-cert.pub' } |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1
    if ($file) { return $file.FullName }
    return $null
}

function Get-KeyLines([string]$Text) {
    $keys = @()
    foreach ($line in ($Text -split "`r?`n")) {
        $l = $line.Trim()
        if ($l -and -not $l.StartsWith('#')) { $keys += $l }
    }
    return , $keys
}

function Get-AgentKeys {
    $sshAdd = Find-Executable 'ssh-add' $script:SshDir
    if (-not $sshAdd) { return , @() }
    try {
        $r = Invoke-Native -FilePath $sshAdd -Arguments @('-L') -Capture
    } catch { return , @() }
    if ($r.ExitCode -ne 0) { return , @() }
    return , (Get-KeyLines $r.StdOut)
}

# ---------------------------------------------------------------------------
# Argument parsing (getopts compatible: clustered flags, -p22, -oOpt=val, ...)
# ---------------------------------------------------------------------------

$Force = $false
$DryRun = $false
$UseSftp = $false
$IdentityGiven = $false
$IdentityArg = $null
$Port = $null
$ConfigFile = $null
$TargetPath = $null
$SshOptions = New-Object Collections.Generic.List[string]
$Positional = New-Object Collections.Generic.List[string]

$i = 0
while ($i -lt $ScriptArgs.Count) {
    $a = [string]$ScriptArgs[$i]
    $i++
    if ($a -eq '--') {
        while ($i -lt $ScriptArgs.Count) { $Positional.Add([string]$ScriptArgs[$i]); $i++ }
        break
    }
    if (-not $a.StartsWith('-') -or $a -eq '-') { $Positional.Add($a); continue }

    $j = 1
    while ($j -lt $a.Length) {
        $c = $a[$j]
        $j++
        switch -CaseSensitive ([string]$c) {
            'f' { $Force = $true; continue }
            'n' { $DryRun = $true; continue }
            's' { $UseSftp = $true; continue }
            'x' { $script:DebugMode = $true; continue }
            'h' { Show-Usage }
            '?' { Show-Usage }
            { 'i', 'p', 'o', 'F', 't' -ccontains $_ } {
                $value = $null
                if ($j -lt $a.Length) {
                    $value = $a.Substring($j)
                } elseif ($c -eq 'i') {
                    # -i takes an optional argument: it is absent if the next word
                    # looks like an option or is the last word (the hostname).
                    if ($i -lt ($ScriptArgs.Count - 1) -and -not ([string]$ScriptArgs[$i]).StartsWith('-')) {
                        $value = [string]$ScriptArgs[$i]; $i++
                    }
                } else {
                    if ($i -ge $ScriptArgs.Count) { Show-Usage "option requires an argument -- $c" }
                    $value = [string]$ScriptArgs[$i]; $i++
                }
                $j = $a.Length
                switch -CaseSensitive ([string]$c) {
                    'i' {
                        if ($IdentityGiven) { Show-Usage '-i option must not be specified more than once' }
                        $IdentityGiven = $true
                        $IdentityArg = $value
                    }
                    'p' { $Port = $value }
                    'o' { $SshOptions.Add($value) }
                    'F' { $ConfigFile = $value }
                    't' { $TargetPath = $value }
                }
                continue
            }
            default { Show-Usage "illegal option -- $c" }
        }
    }
}

if ($Positional.Count -eq 0) { Show-Usage }
if ($Positional.Count -gt 1) { Show-Usage ("unexpected argument -- " + $Positional[1]) }
$Target = $Positional[0]

$SshExe = Find-Executable 'ssh' $null
if (-not $SshExe) { Exit-WithError 'ssh.exe not found. Install the "OpenSSH Client" optional feature.' }
$script:SshDir = Split-Path -Parent $SshExe

if ($ConfigFile) { $ConfigFile = Resolve-LocalPath $ConfigFile }

# Options passed to every ssh invocation.
$SshArgs = New-Object Collections.Generic.List[string]
if ($ConfigFile) { $SshArgs.Add('-F'); $SshArgs.Add($ConfigFile) }
if ($Port) { $SshArgs.Add('-p'); $SshArgs.Add($Port) }
foreach ($o in $SshOptions) { $SshArgs.Add('-o'); $SshArgs.Add($o) }

# Normalise the remote target path: a leading ~/ just means "relative to home".
if ($TargetPath) {
    if ($TargetPath -eq '~') { Show-Usage 'target_path must name a file' }
    if ($TargetPath -match '^~[\\/]') { $TargetPath = $TargetPath.Substring(2) }
}

# ---------------------------------------------------------------------------
# Select the keys to install
# ---------------------------------------------------------------------------

$PrivIdFile = $null
$Keys = @()
$KeySource = $null

function Use-IdFile([string]$Path) {
    if ($Path -like '*.pub') {
        $pub = $Path
        $priv = $Path.Substring(0, $Path.Length - 4)
    } else {
        $pub = "$Path.pub"
        $priv = $Path
    }
    if (-not (Test-Path -LiteralPath $pub -PathType Leaf)) {
        Exit-WithError ("failed to open ID file '{0}': No such file" -f $pub)
    }
    if (-not $Force) {
        if (-not (Test-Path -LiteralPath $priv -PathType Leaf)) {
            Exit-WithError ("failed to open ID file '{0}': No such file`n`t(to install the contents of '{1}' anyway, look at the -f option)" -f $priv, $pub)
        }
        $script:PrivIdFile = $priv
    }
    $script:KeySource = $pub
    $script:Keys = Get-KeyLines ([IO.File]::ReadAllText($pub))
}

if ($IdentityGiven) {
    if ($IdentityArg) {
        Use-IdFile (Resolve-LocalPath $IdentityArg)
    } else {
        $default = Get-DefaultIdFile
        if (-not $default) { Exit-WithError 'No identities found' }
        Use-IdFile $default
    }
} else {
    $agentKeys = Get-AgentKeys
    if ($agentKeys.Count -gt 0) {
        $Keys = $agentKeys
        $KeySource = 'ssh-add -L'
    } else {
        $default = Get-DefaultIdFile
        if (-not $default) { Exit-WithError 'No identities found' }
        Use-IdFile $default
    }
}

if (@($Keys).Count -eq 0) { Exit-WithError ("No keys found in '{0}'" -f $KeySource) }

# Drop duplicate keys (same type and key material).
$seen = @{}
$Keys = @($Keys | Where-Object {
    $parts = $_ -split '\s+'
    $id = if ($parts.Count -ge 2) { $parts[0] + ' ' + $parts[1] } else { $_ }
    # Keys with options in front are compared as whole lines.
    if ($seen.ContainsKey($id)) { $false } else { $seen[$id] = $true; $true }
})

Write-Log 'INFO' ('Source of key(s) to be installed: "{0}"' -f $KeySource)

# ---------------------------------------------------------------------------
# Remote detection and filtering of already-installed keys
# ---------------------------------------------------------------------------

function Get-RemoteVersion {
    # Authentication is made to fail immediately; only the banner exchange matters.
    $a = @('-v', '-o', 'PreferredAuthentications=,', '-o', 'ControlPath=none', '-o', 'BatchMode=yes') + $SshArgs + @($Target)
    $r = Invoke-Native -FilePath $SshExe -Arguments $a -Capture
    $m = [regex]::Match($r.Output, 'remote software version (\S+)')
    if ($m.Success) { return $m.Groups[1].Value }
    return ''
}

function Get-NewKeys([string[]]$Candidates, [int]$SuccessCode) {
    if ($Force) { return , @($Candidates) }

    Write-Log 'INFO' 'attempting to log in with the new key(s), to filter out any that are already installed'
    $tmp = New-TempDir
    $new = @()
    try {
        $tmpId = Join-Path $tmp 'id'
        foreach ($key in $Candidates) {
            [IO.File]::WriteAllText($tmpId, "$key`n", $Utf8NoBom)
            [IO.File]::WriteAllText("$tmpId.pub", "$key`n", $Utf8NoBom)
            $idFile = if ($PrivIdFile) { $PrivIdFile } else { $tmpId }

            $a = @('-i', $idFile,
                   '-o', 'ControlPath=none',
                   '-o', 'LogLevel=INFO',
                   '-o', 'PreferredAuthentications=publickey',
                   '-o', 'IdentitiesOnly=yes') + $SshArgs + @($Target, 'exit')
            $r = Invoke-Native -FilePath $SshExe -Arguments $a -Capture

            if ($r.ExitCode -eq $SuccessCode -or
                ($UseSftp -and $r.Output -match 'allows sftp connections only')) {
                continue   # already installed
            }
            if ($r.Output -match 'Permission denied|Too many authentication failures') {
                $new += $key
                continue
            }
            $msg = $r.Output.Trim()
            if (-not $msg) { $msg = "ssh exited with status $($r.ExitCode)" }
            Exit-WithError $msg
        }
    } finally {
        Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }

    if ($new.Count -eq 0) {
        Write-Log 'WARNING' "All keys were skipped because they already exist on the remote system.`n`t`t(if you think this is a mistake, you may want to use -f option)`n"
        exit 0
    }
    Write-Log 'INFO' ('{0} key(s) remain to be installed -- if you are prompted now it is to install the new keys' -f $new.Count)
    return , $new
}

# ---------------------------------------------------------------------------
# Installers
# ---------------------------------------------------------------------------

function Get-KeysText([string[]]$List) {
    return (($List | ForEach-Object { $_ }) -join "`n") + "`n"
}

# Remote is a POSIX-ish system: append via sh, like upstream ssh-copy-id.
function Install-KeysPosix([string[]]$List) {
    if ($TargetPath) {
        if ($TargetPath.Contains("'")) { Exit-WithError 'target_path must not contain single quotes' }
        $escaped = $TargetPath -replace '([\\"$`])', '\$1'
        $setFile = 'AUTH_KEY_FILE="' + $escaped + '";'
    } else {
        $setFile = 'AUTH_KEY_FILE=.ssh/authorized_keys; [ -f /etc/openwrt_release ] && [ "$LOGNAME" = "root" ] && AUTH_KEY_FILE=/etc/dropbear/authorized_keys;'
    }
    # Same remote script as upstream ssh-copy-id (backquotes kept for old /bin/sh).
    $shScript = 'cd; umask 077; ' + $setFile +
        ' AUTH_KEY_DIR=`dirname "${AUTH_KEY_FILE}"`;' +
        ' mkdir -p "${AUTH_KEY_DIR}" &&' +
        ' { [ -z "`tail -1c ${AUTH_KEY_FILE} 2>/dev/null`" ] || echo >> "${AUTH_KEY_FILE}" || exit 1; } &&' +
        ' cat >> "${AUTH_KEY_FILE}" || exit 1;' +
        ' if type restorecon >/dev/null 2>&1; then restorecon -F "${AUTH_KEY_DIR}" "${AUTH_KEY_FILE}"; fi'
    $remoteCmd = "exec sh -c '" + $shScript + "'"

    $r = Invoke-Native -FilePath $SshExe -Arguments (@($SshArgs) + @($Target, $remoteCmd)) -InputText (Get-KeysText $List)
    if ($r.ExitCode -ne 0) { Exit-WithError "failed to install the key(s) (ssh exited with status $($r.ExitCode))" }
    return $List.Count
}

# Remote is OpenSSH for Windows: append via PowerShell on the remote side.
function Install-KeysWindows([string[]]$List) {
    $t = ''
    if ($TargetPath) { $t = $TargetPath.Replace("'", "''") }
    $remoteScript = @"
`$ErrorActionPreference='Stop'; `$ProgressPreference='SilentlyContinue'
try {
  `$ms=New-Object IO.MemoryStream; [Console]::OpenStandardInput().CopyTo(`$ms)
  `$enc=New-Object Text.UTF8Encoding `$false
  `$keys=`$enc.GetString(`$ms.ToArray())
  `$f='$t'; `$adm=`$false
  if(-not `$f){
    `$f='.ssh\authorized_keys'
    if(@([Security.Principal.WindowsIdentity]::GetCurrent().Groups|Where-Object{`$_.Value -eq 'S-1-5-32-544'}).Count){
      `$cfg=Join-Path `$env:ProgramData 'ssh\sshd_config'
      if((Test-Path -LiteralPath `$cfg) -and (Select-String -LiteralPath `$cfg -Pattern '^\s*Match\s+Group\s+administrators\b' -Quiet)){
        `$f=Join-Path `$env:ProgramData 'ssh\administrators_authorized_keys'; `$adm=`$true
      }
    }
  }
  if(-not [IO.Path]::IsPathRooted(`$f)){ `$f=Join-Path `$env:USERPROFILE `$f }
  `$d=Split-Path -Parent `$f
  if(`$d -and -not (Test-Path -LiteralPath `$d)){ New-Item -ItemType Directory -Path `$d -Force|Out-Null }
  `$pre=''
  if((Test-Path -LiteralPath `$f) -and (Get-Item -LiteralPath `$f).Length -gt 0){
    `$b=[IO.File]::ReadAllBytes(`$f); if(`$b[`$b.Length-1] -ne 10){ `$pre="``n" }
  }
  [IO.File]::AppendAllText(`$f,`$pre+`$keys,`$enc)
  if(`$adm){ icacls.exe `$f /inheritance:r /grant '*S-1-5-32-544:F' /grant '*S-1-5-18:F'|Out-Null; if(`$LASTEXITCODE){ throw "icacls failed on `$f" } }
  exit 0
} catch { [Console]::Error.WriteLine(`$_.Exception.Message); exit 1 }
"@
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($remoteScript))
    $remoteCmd = "powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -OutputFormat Text -EncodedCommand $encoded"

    $r = Invoke-Native -FilePath $SshExe -Arguments (@($SshArgs) + @($Target, $remoteCmd)) -InputText (Get-KeysText $List)
    if ($r.ExitCode -ne 0) { Exit-WithError "failed to install the key(s) (ssh exited with status $($r.ExitCode))" }
    return $List.Count
}

# NetScreen firewalls: use their 'set ssh pka-dsa key ...' command.
function Install-KeysNetScreen([string[]]$List) {
    $added = 0
    $n = 0
    foreach ($key in $List) {
        $n++
        if ($key -notmatch '^ssh-dss\s') {
            Write-Log 'WARNING' ('Non-dsa key (#{0}) skipped (NetScreen only supports DSA keys)' -f $n)
            continue
        }
        $body = ($key -split '\s+')[1]
        $r = Invoke-Native -FilePath $SshExe -Arguments (@('-T') + $SshArgs + @($Target)) `
            -InputText "set ssh pka-dsa key $body`nsave`nexit`n" -Capture
        if ($r.ExitCode -eq 255) {
            Write-Log 'ERROR' ('installation of key #{0} failed (please report a bug describing what caused this, so that we can make this message useful)' -f $n)
        } else {
            $added++
        }
    }
    return $added
}

function ConvertTo-SftpPath([string]$Path) {
    return '"' + ($Path -replace '([\\"])', '\$1') + '"'
}

# sftp-only remotes: download authorized_keys, append locally, upload it again.
function Install-KeysSftp([string[]]$List) {
    $sftpExe = Find-Executable 'sftp' $script:SshDir
    if (-not $sftpExe) { Exit-WithError 'sftp.exe not found' }

    $sftpArgs = New-Object Collections.Generic.List[string]
    if ($ConfigFile) { $sftpArgs.Add('-F'); $sftpArgs.Add($ConfigFile) }
    if ($Port) { $sftpArgs.Add('-P'); $sftpArgs.Add($Port) }
    foreach ($o in $SshOptions) { $sftpArgs.Add('-o'); $sftpArgs.Add($o) }
    # -b implies BatchMode=yes, which would forbid password logins.
    $sftpArgs.Add('-o'); $sftpArgs.Add('BatchMode=no')
    $sftpArgs.Add('-b'); $sftpArgs.Add('-')
    $sftpArgs.Add($Target)

    $remoteFile = if ($TargetPath) { $TargetPath.Replace('\', '/') } else { '.ssh/authorized_keys' }
    $slash = $remoteFile.LastIndexOf('/')
    $remoteDir = if ($slash -gt 0) { $remoteFile.Substring(0, $slash) } else { $null }

    $tmp = New-TempDir
    try {
        $local = Join-Path $tmp 'authorized_keys'
        $localSftp = ConvertTo-SftpPath ($local.Replace('\', '/'))

        $r = Invoke-Native -FilePath $sftpExe -Arguments $sftpArgs -Capture `
            -InputText ("get {0} {1}`n" -f (ConvertTo-SftpPath $remoteFile), $localSftp)
        if ($r.ExitCode -ne 0) {
            if ($r.Output -notmatch 'not found|No such file') {
                Exit-WithError ("failed to download '{0}': {1}" -f $remoteFile, $r.Output.Trim())
            }
            if (Test-Path -LiteralPath $local) { Remove-Item -LiteralPath $local -Force }
        }

        $prefix = ''
        if ((Test-Path -LiteralPath $local) -and (Get-Item -LiteralPath $local).Length -gt 0) {
            $bytes = [IO.File]::ReadAllBytes($local)
            if ($bytes[$bytes.Length - 1] -ne 10) { $prefix = "`n" }
        }
        [IO.File]::AppendAllText($local, $prefix + (Get-KeysText $List), $Utf8NoBom)

        $batch = @()
        if ($remoteDir) {
            $batch += '-mkdir ' + (ConvertTo-SftpPath $remoteDir)
            $batch += '-chmod 700 ' + (ConvertTo-SftpPath $remoteDir)
        }
        $batch += 'put {0} {1}' -f $localSftp, (ConvertTo-SftpPath $remoteFile)
        $batch += '-chmod 600 ' + (ConvertTo-SftpPath $remoteFile)

        $r = Invoke-Native -FilePath $sftpExe -Arguments $sftpArgs -Capture -InputText (($batch -join "`n") + "`n")
        if ($r.ExitCode -ne 0) { Exit-WithError ("failed to upload '{0}': {1}" -f $remoteFile, $r.Output.Trim()) }
    } finally {
        Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
    return $List.Count
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

$RemoteVersion = Get-RemoteVersion
if ($script:DebugMode) { [Console]::Error.WriteLine("+ remote software version: '$RemoteVersion'") }

$RemoteIsNetScreen = $RemoteVersion -like 'NetScreen*'
$RemoteIsWindows = $RemoteVersion -like '*Windows*'

$NewKeys = Get-NewKeys $Keys $(if ($RemoteIsNetScreen) { 1 } else { 0 })

if ($DryRun) {
    [Console]::Out.WriteLine("=-=-=-=-=-=-=-=`nWould have added the following key(s):`n`n" + (Get-KeysText $NewKeys) + "=-=-=-=-=-=-=-=")
    exit 0
}

if ($RemoteIsNetScreen) {
    $Added = Install-KeysNetScreen $NewKeys
} elseif ($UseSftp) {
    $Added = Install-KeysSftp $NewKeys
} elseif ($RemoteIsWindows) {
    $Added = Install-KeysWindows $NewKeys
} else {
    $Added = Install-KeysPosix $NewKeys
}

$tryCmd = if ($UseSftp) { 'sftp' } else { 'ssh' }
if ($ConfigFile) { $tryCmd += ' -F ' + (ConvertTo-ShellQuoted $ConfigFile) }
if ($Port) { $tryCmd += $(if ($UseSftp) { ' -P ' } else { ' -p ' }) + (ConvertTo-ShellQuoted $Port) }
foreach ($o in $SshOptions) { $tryCmd += ' -o ' + (ConvertTo-ShellQuoted $o) }
$tryCmd += ' ' + (ConvertTo-ShellQuoted $Target)

[Console]::Out.WriteLine("`nNumber of key(s) added: $Added`n`nNow try logging into the machine, with: `"$tryCmd`"`nand check to make sure that only the key(s) you wanted were added.`n")
exit 0
