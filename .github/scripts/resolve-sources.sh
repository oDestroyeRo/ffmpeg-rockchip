#!/usr/bin/env bash
set -euo pipefail

scripts=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
manifest="$scripts/../release-sources.json"
repository=$(jq -er '.ffmpeg.repository' "$manifest")

resolve_commit() {
    local repository=$1 branch=$2 commit
    commit=$(git ls-remote --exit-code "$repository" "refs/heads/$branch" | cut -f1)
    [[ $commit =~ ^[0-9a-f]{40}$ ]] || {
        echo "Cannot resolve $repository branch $branch." >&2
        return 1
    }
    printf '%s\n' "$commit"
}

# Resolve dependencies once so every FFmpeg version uses the same source snapshot.
mpp_commit=$(resolve_commit "$(jq -er '.mpp.repository' "$manifest")" "$(jq -er '.mpp.branch' "$manifest")")
rga_commit=$(resolve_commit "$(jq -er '.rga.repository' "$manifest")" "$(jq -er '.rga.branch' "$manifest")")
matrix='{"include":[]}'
while read -r series; do
    commit=$(resolve_commit "$repository" "$series")
    matrix=$(jq -c --arg series "$series" --arg commit "$commit" \
        --arg mpp_commit "$mpp_commit" --arg rga_commit "$rga_commit" \
        '.include += [{series: $series, commit: $commit, mpp_commit: $mpp_commit, rga_commit: $rga_commit}]' <<< "$matrix")
done < <(jq -er '.ffmpeg.branches[]' "$manifest")
printf '%s\n' "$matrix"
