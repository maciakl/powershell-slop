# Each sub-folder of `source` is its own git repo, mirrored here as a subtree
# under a prefix of the same name.

source := "D:/code/powershell"

# Add every sub-folder of {{source}} that is not yet a subtree
add:
    #!/usr/bin/env bash
    set -euo pipefail
    for dir in "{{source}}"/*/; do
        name=$(basename "$dir")
        if git log -1 --format=%H --grep="^git-subtree-dir: $name\$" | grep -q .; then
            echo "skip: $name (already a subtree)"
            continue
        fi
        branch=$(git -C "$dir" branch --show-current)
        echo "add: $name ($branch)"
        git subtree add --prefix="$name" "$dir" "$branch"
    done

# Pull the latest changes into every subtree
update: add
    #!/usr/bin/env bash
    set -euo pipefail
    for dir in "{{source}}"/*/; do
        name=$(basename "$dir")
        branch=$(git -C "$dir" branch --show-current)
        echo "pull: $name ($branch)"
        git subtree pull --prefix="$name" "$dir" "$branch" -m "Update $name subtree"
    done
