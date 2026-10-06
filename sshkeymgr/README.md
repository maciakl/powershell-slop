# SSH-KeyManager

A terminal UI for managing SSH keys on Windows, in a single PowerShell script.

It lists the key pairs in your `.ssh` directory and lets you:

- **Copy a public key** to the clipboard as one clean line, ready to paste into GitHub, GitLab, Bitbucket, etc.
- **Create a new key** with GitHub-friendly defaults (Ed25519), and optionally add a `Host github.com` entry to `~/.ssh/config`
- **Install a public key on a remote host**, like `ssh-copy-id`, then test the key login
- **View key details**: algorithm, bit length, SHA256/MD5 fingerprints, passphrase status, randomart
- **Recreate a missing or mismatched `.pub` file** from the private key

## Requirements

- Windows 10/11
- Windows PowerShell 5.1 (included with Windows) or PowerShell 7+
- Windows OpenSSH client (`ssh.exe`, `ssh-keygen.exe`), installed by default on Windows 11. If it is missing, add **OpenSSH Client** under *Settings > System > Optional features*.
- An interactive console that supports ANSI escape sequences (Windows Terminal, the standard console host, or the VS Code terminal)

No modules or other dependencies.

## Usage

```powershell
# Run with the default directory (%USERPROFILE%\.ssh)
powershell -ExecutionPolicy Bypass -File .\SSH-KeyManager.ps1

# Manage keys in another directory
.\SSH-KeyManager.ps1 -SshDir D:\keys
```

| Parameter | Description |
|-----------|-------------|
| `-SshDir` | Directory to manage. Defaults to `%USERPROFILE%\.ssh`, the directory Windows OpenSSH uses. |

Dot-sourcing the script (`. .\SSH-KeyManager.ps1`) loads its functions without starting the UI.

## Keys

| Key | Action |
|-----|--------|
| `Up` / `Down` (or `k` / `j`) | Move selection |
| `PgUp` / `PgDn`, `Home` / `End` | Jump through the list |
| `Enter` / `C` | Copy the selected public key to the clipboard |
| `N` | Create a new key |
| `S` | Send the public key to a remote host |
| `V` | View key details |
| `P` | Recreate the missing or mismatched `.pub` file |
| `O` | Open the SSH directory in Explorer |
| `R` / `F5` | Refresh the list |
| `Q` / `Esc` | Quit |

## Key list

Each row shows the key name, type, bit length, whether the private key is passphrase-protected, file state, modification date and comment.

The **FILES** column reports:

| State | Meaning |
|-------|---------|
| `pair` | Private key and matching `.pub` file |
| `no .pub` | Private key only (press `P` to recreate the `.pub`) |
| `pub only` | Public key only; it cannot be used to log in from this computer |
| `MISMATCH` | The `.pub` file does not belong to the private key |
| `bad .pub` | The `.pub` file is corrupt or not in OpenSSH format (e.g. PuTTY/RFC4716) |

Warnings are shown for obsolete or weak keys, such as DSA keys and RSA keys shorter than 2048 bits, which GitHub rejects.

## Notes

- **Clean copies.** The copied key has BOMs, zero-width characters, line breaks and extra whitespace stripped, and the clipboard is read back to verify the result.
- **Missing `.pub` files.** For OpenSSH-format private keys, the public key is read from the unencrypted header, so it can be copied even without a `.pub` file and without entering the passphrase.
- **No overwrites.** Creating a key never overwrites an existing file. Recreating a `.pub` renames the old file to `.pub.bak`.
- **Sending keys** appends to `~/.ssh/authorized_keys` on Linux, macOS and BSD hosts, fixing directory and file permissions and skipping keys that are already installed. Windows SSH servers are not supported.
- **Windows OpenSSH first.** The Windows OpenSSH client in `System32\OpenSSH` is preferred over other copies on `PATH`, such as Git for Windows' bundled `ssh`.
- **File encoding.** Files are written as UTF-8 without a BOM, because OpenSSH cannot read files with a BOM. The script itself is pure ASCII so Windows PowerShell 5.1 parses it correctly regardless of encoding.
