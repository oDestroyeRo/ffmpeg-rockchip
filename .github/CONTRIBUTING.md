# Contributing to this Rockchip build fork

Create a branch such as `ci/update-release-builds` or `fix/package-runtime` and
open a pull request into the default branch (`master`). Keep each pull request
focused and use a Conventional Commit title, for example
`ci: update the release build dependencies`. The pull request title and body
become the squash commit title and message.

The default branch, `master`, and `main` require a pull request, resolved review
conversations, and these successful GitHub Actions checks against the current
base branch:

- `Resolve upstream Rockchip branches`
- `FFmpeg 7.0 / Debian 13 ARM64`
- `FFmpeg 7.1 / Debian 13 ARM64`
- `FFmpeg 8.0 / Debian 13 ARM64`
- `FFmpeg 8.1 / Debian 13 ARM64`

Squash merging is the only merge method. Force pushes and deletion are blocked
on protected branches. Merged feature branches are deleted automatically. Use
the update-branch button when the base changes, and optionally enable auto-merge
to merge once the required checks pass. Human approval is optional while this
repository has one maintainer; review conversations must still be resolved.

Every pull request runs the release checks, including documentation changes.
The builds validate this fork's release recipe against the configured upstream
FFmpeg branches; they do not compile FFmpeg source changes made only in this
fork. Hardware acceleration must be tested separately on Rockchip hardware.

GitHub Actions must use full commit SHAs and GitHub-authored actions or local
actions. External contributors need maintainer approval before their fork PR
workflows run. Dependabot proposes grouped weekly GitHub Actions updates; MPP
and RGA continue to track their configured upstream branch heads on each build.

Release publication remains manual: run **Release Rockchip FFmpeg** on the
default branch with **Publish all four builds as a GitHub Release** enabled.
Only the publishing job receives write access. It attaches all assets to a
draft before publishing. Published `rockchip-*` tags cannot be changed or
deleted, and immutable releases protect assets for releases published after
immutability is enabled. Corrections must use a new release.
