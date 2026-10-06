# SSH-CopyId.ps1

A PowerShell drop-in replacement for OpenSSH's `ssh-copy-id`. It installs your
public keys into a remote host's `authorized_keys` so you can log in without a
password.

It runs on the Windows PowerShell 5.1 that ships with Windows 10/11 and uses the
built-in Windows OpenSSH client (`ssh.exe`, `ssh-add.exe`, `sftp.exe`). There are
no other dependencies.

## Features

- Same command-line interface as upstream `ssh-copy-id`, including clustered
  flags (`-fn`) and attached values (`-p22`, `-oPort=22`).
- Uses keys from the SSH agent (`ssh-add -L`), or falls back to the most
  recently modified `~/.ssh/id*.pub`.
- Skips keys that are already installed by trying to log in with each one first.
- Detects the remote system and installs keys the right way:
  - **Linux/Unix**: appends to `~/.ssh/authorized_keys` using the same remote
    shell script as upstream (including OpenWrt/Dropbear and SELinux
    `restorecon` handling).
  - **OpenSSH for Windows**: appends to `%USERPROFILE%\.ssh\authorized_keys`, or
    to `%ProgramData%\ssh\administrators_authorized_keys` for members of the
    Administrators group when `sshd_config` has the default
    `Match Group administrators` block. The ACL on that file is set the way
    sshd expects.
  - **sftp-only hosts** (`-s`): downloads `authorized_keys`, appends the keys
    locally and uploads the file again.
  - **NetScreen firewalls**: uses `set ssh pka-dsa key ...`.

## Requirements

- Windows PowerShell 5.1 or PowerShell 7+
- The **OpenSSH Client** Windows optional feature (installed by default on
  Windows 10 1809+ and Windows 11)

## Installation

Copy `SSH-CopyId.ps1` into a folder on your `PATH`. If you downloaded it from
the internet, unblock it first:

```powershell
Unblock-File .\SSH-CopyId.ps1
```

If your execution policy blocks local scripts, allow them for your user:

```powershell
Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
```

## Usage

```
SSH-CopyId.ps1 [-h|-?|-f|-n|-s|-x] [-i [identity_file]] [-p port]
               [-F alternative ssh_config file] [-t target_path]
               [[-o <ssh -o options>] ...] [user@]hostname
```

| Option             | Description |
|--------------------|-------------|
| `-i identity_file` | Use only the key(s) in `identity_file`. `.pub` is added if missing. With no filename, the default ID file is used. |
| `-f`               | Force mode: don't check whether the keys are already installed (the private key is not needed). |
| `-n`               | Dry run: print the key(s) that would have been installed. |
| `-s`               | Use sftp instead of running remote commands (for hosts that only allow sftp). |
| `-x`               | Debug: print the commands being executed. |
| `-t target_path`   | Path on the remote host to install the keys into (default: `.ssh/authorized_keys`). |
| `-p port`          | Remote port, passed through to ssh. |
| `-o ssh_option`    | ssh `-o` option, passed through to ssh. May be repeated. |
| `-F ssh_config`    | Alternative ssh config file, passed through to ssh. |
| `-h`, `-?`         | Print the usage summary. |

### Examples

Install your keys on a server:

```powershell
SSH-CopyId.ps1 user@server
```

Install a specific key on a non-standard port:

```powershell
SSH-CopyId.ps1 -i ~/.ssh/id_ed25519.pub -p 2222 user@server
```

See which keys would be installed, without changing anything:

```powershell
SSH-CopyId.ps1 -n user@server
```

Install into a host that only permits sftp:

```powershell
SSH-CopyId.ps1 -s user@server
```

Full help is available with:

```powershell
Get-Help .\SSH-CopyId.ps1 -Full
```

## How it works

1. Picks the keys to install (from `-i`, the agent, or the default ID file) and
   drops duplicates.
2. Connects once with authentication disabled to read the remote server's
   version banner, which identifies Windows and NetScreen hosts.
3. Unless `-f` is given, tries to log in with each key and keeps only those
   that are rejected.
4. Installs the remaining keys with the method that suits the remote host, then
   prints the command to test the login.

Password, passphrase and host-key prompts from ssh go straight to your console.
