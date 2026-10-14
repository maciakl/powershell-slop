# Sudo.ps1

A `sudo` for PowerShell on Windows. It shows a UAC prompt, runs your command
in an elevated PowerShell process and streams the output back into your
current console.

Useful where the built-in Windows `sudo` (Settings > System > For developers)
is turned off or unavailable.

Works in Windows PowerShell 5.1 and PowerShell 7+. It's a single script with
no dependencies.

## Installation

1. Save `Sudo.ps1` somewhere, for example `C:\Tools\Sudo.ps1`.
2. Add an alias to your `$PROFILE`:

   ```powershell
   Set-Alias sudo C:\Tools\Sudo.ps1
   ```

If your execution policy blocks the script, unblock it with
`Unblock-File C:\Tools\Sudo.ps1` or allow local scripts with
`Set-ExecutionPolicy -Scope CurrentUser RemoteSigned`.

## Usage

```powershell
sudo [options] [command]
```

The command can be given in several forms:

| Form | Example |
| --- | --- |
| Plain words | `sudo Stop-Service -Name Spooler -Force` |
| Native program | `sudo netsh winsock reset` |
| Script block | `sudo { Get-Service Spool* \| Restart-Service }` |
| String | `sudo 'Get-Process \| Sort-Object CPU \| Select -Last 5'` |
| Repeat last command | `sudo !!` |

With no command, an elevated PowerShell window opens in the current
directory. The same happens for `sudo cmd`, `sudo powershell` and
`sudo pwsh`.

### Options

Options must come before the command.

| Option | Description |
| --- | --- |
| `-n`, `-NewWindow`, `--new-window` | Run in a new elevated console window that supports input, and wait for it to close. |
| `-k`, `-NoExit`, `--no-exit` | Like `-NewWindow`, but leave an elevated prompt open afterwards and don't wait. |
| `-h`, `-Help`, `--help` | Show help. |
| `--` | Stop parsing sudo options. |

## Examples

Restart a service:

```powershell
sudo Restart-Service Spooler
```

List a protected directory:

```powershell
sudo Get-ChildItem C:\Windows\System32\config
```

Pass variables into a script block with `$using:`:

```powershell
$svc = 'Spooler'
sudo { Stop-Service $using:svc; Get-Service $using:svc }
```

Run an interactive program in a new elevated window:

```powershell
sudo -n diskpart
```

Retry the last command elevated:

```powershell
PS> Set-Content C:\Windows\test.txt hi
Set-Content: Access to the path 'C:\Windows\test.txt' is denied.
PS> sudo !!
```

## How it works

- The elevated process runs the same PowerShell edition as the caller,
  starts in the current directory and skips profiles.
- By default it runs in a hidden window. Output, errors, warnings, verbose,
  debug and information messages are sent back over a named pipe and written
  to your console.
- The exit code of the elevated command becomes the exit code of `sudo`.
- The syntax is checked before the UAC prompt appears, so typos don't cost
  you a prompt.
- The pipe is created before the elevated process starts and the process
  must present a one-time token, so no other process can hijack it.

## Notes and limitations

- **Output is text, not objects.** Results streamed back from the elevated
  process are formatted text. If your session is already elevated, the
  command runs directly in it and returns objects as usual.
- **Input is not forwarded.** Use `-NewWindow` for commands that prompt or
  read from the console.
- **Variables.** Variables in plain-word commands are expanded before
  elevating. Inside a script block or string, use `$using:Name` to refer to
  your variables; their values are serialized into the elevated process.
- **Aliases and functions** defined in your session are carried over when
  used as the command name. Module functions are left to autoloading.
- Common parameters such as `-Verbose` or `-ErrorAction` are passed to the
  elevated command, not consumed by `sudo`.

## Help

```powershell
sudo --help
Get-Help C:\Tools\Sudo.ps1 -Full
```
