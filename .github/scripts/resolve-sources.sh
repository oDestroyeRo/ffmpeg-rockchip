#!/usr/bin/env bash
set -euo pipefail

scripts=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
manifest="$scripts/../release-sources.json"
repository=$(jq -er '.ffmpeg.repository' "$manifest")
matrix='{"include":[]}'
while read -r series; do
    commit=$(git ls-remote --exit-code "$repository" "refs/heads/$series" | cut -f1)
    [[ $commit =~ ^[0-9a-f]{40}$ ]] || exit 1
    matrix=$(jq -c --arg series "$series" --arg commit "$commit" \
        '.include += [{series: $series, commit: $commit}]' <<< "$matrix")
done < <(jq -er '.ffmpeg.branches[]' "$manifest")
printf '%s\n' "$matrix"
