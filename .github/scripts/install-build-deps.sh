#!/usr/bin/env bash
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install --yes --no-install-recommends \
    build-essential ca-certificates cmake git jq libdrm-dev libssl-dev \
    meson ninja-build patchelf pkg-config python3 xz-utils zlib1g-dev
