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
