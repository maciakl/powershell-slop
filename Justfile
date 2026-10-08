# Each sub-folder of `source` is its own git repo, mirrored here as a subtree
# under a prefix of the same name. Folders prefixed with `_` and folders that
# are not git repos are ignored.

source := "D:/code/powershell"

# Add every sub-folder of {{source}} that is not yet a subtree
[script("pwsh", "-NoProfile")]
add:
    $ErrorActionPreference = 'Stop'
    $PSNativeCommandUseErrorActionPreference = $true
    foreach ($dir in Get-ChildItem -Directory '{{source}}' | Where-Object { $_.Name -notlike '_*' -and (Test-Path (Join-Path $_.FullName '.git')) }) {
        $name = $dir.Name
        if (git log -1 --format=%H --grep="^git-subtree-dir: $name`$") {
            Write-Host "skip: $name (already a subtree)"
            continue
        }
        $branch = git -C $dir.FullName branch --show-current
        Write-Host "add: $name ($branch)"
        git subtree add --prefix=$name $dir.FullName $branch
    }

# Pull the latest changes into every subtree
[script("pwsh", "-NoProfile")]
update: add
    $ErrorActionPreference = 'Stop'
    $PSNativeCommandUseErrorActionPreference = $true
    foreach ($dir in Get-ChildItem -Directory '{{source}}' | Where-Object { $_.Name -notlike '_*' -and (Test-Path (Join-Path $_.FullName '.git')) }) {
        $name = $dir.Name
        $branch = git -C $dir.FullName branch --show-current
        Write-Host "pull: $name ($branch)"
        git subtree pull --prefix=$name $dir.FullName $branch -m "Update $name subtree"
    }

dest := "R:/Misc/Scripts"

# Copy each sub-folder's .ps1 file to {{dest}} when it is newer than the copy there
[script("pwsh", "-NoProfile")]
deploy:
    $ErrorActionPreference = 'Stop'
    New-Item -ItemType Directory -Force '{{dest}}' | Out-Null
    foreach ($file in Get-ChildItem -Directory | Get-ChildItem -File -Filter *.ps1) {
        $target = Join-Path '{{dest}}' $file.Name
        if ((Test-Path $target) -and $file.LastWriteTimeUtc -le (Get-Item $target).LastWriteTimeUtc) {
            Write-Host "skip: $($file.Name) (up to date)"
            continue
        }
        Write-Host "copy: $($file.Name)"
        Copy-Item $file.FullName $target
    }

# Pick which sub-folder .ps1 files to install (or update) into Bin in the user's OneDrive
[script("pwsh", "-NoProfile")]
install:
    $ErrorActionPreference = 'Stop'
    if (-not $env:OneDrive) { throw 'OneDrive environment variable is not set' }
    $bin = Join-Path $env:OneDrive 'Bin'
    $items = @(foreach ($file in Get-ChildItem -Directory | Get-ChildItem -File -Filter *.ps1) {
        $target = Join-Path $bin $file.Name
        if (-not (Test-Path $target)) { $status = 'new' }
        elseif ($file.LastWriteTimeUtc -gt (Get-Item $target).LastWriteTimeUtc) { $status = 'update' }
        else { continue }
        [pscustomobject]@{ File = $file; Target = $target; Status = $status; Checked = $true }
    })
    if (-not $items) {
        Write-Host "Everything in $bin is up to date"
        return
    }
    $width = ($items.File.Name | Measure-Object -Maximum Length).Maximum
    $pos = 0
    $done = $false
    Write-Host "Install into ${bin}"
    Write-Host 'up/down: move  space: toggle  a: all/none  enter: install  esc/q: cancel'
    # Reserve the lines first so a scroll at the bottom of the window doesn't shift the list
    1..$items.Count | ForEach-Object { Write-Host '' }
    $top = [Console]::CursorTop - $items.Count
    [Console]::CursorVisible = $false
    try {
        while (-not $done) {
            [Console]::SetCursorPosition(0, $top)
            for ($i = 0; $i -lt $items.Count; $i++) {
                $item = $items[$i]
                $line = '{0} [{1}] {2}  {3}' -f ($i -eq $pos ? '>' : ' '), ($item.Checked ? 'x' : ' '), $item.File.Name.PadRight($width), $item.Status.PadRight(6)
                Write-Host $line -ForegroundColor ($i -eq $pos ? 'Cyan' : 'Gray')
            }
            switch ([Console]::ReadKey($true).Key) {
                'UpArrow'   { $pos = ($pos - 1 + $items.Count) % $items.Count }
                'DownArrow' { $pos = ($pos + 1) % $items.Count }
                'Spacebar'  { $items[$pos].Checked = -not $items[$pos].Checked }
                'A' {
                    $all = @($items | Where-Object Checked).Count -ne $items.Count
                    foreach ($item in $items) { $item.Checked = $all }
                }
                'Enter'  { $done = $true }
                'Escape' { Write-Host 'Cancelled'; return }
                'Q'      { Write-Host 'Cancelled'; return }
            }
        }
    }
    finally {
        [Console]::CursorVisible = $true
    }
    $selected = @($items | Where-Object Checked)
    if (-not $selected) {
        Write-Host 'Nothing selected'
        return
    }
    New-Item -ItemType Directory -Force $bin | Out-Null
    foreach ($item in $selected) {
        Write-Host "$($item.Status): $($item.File.Name)"
        Copy-Item $item.File.FullName $item.Target
    }
