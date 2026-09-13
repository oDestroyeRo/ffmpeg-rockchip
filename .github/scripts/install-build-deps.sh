#!/usr/bin/env bash
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive
# Source packages accompany the bundled Debian libraries in the source archive.
sed -i 's/^Types: deb$/Types: deb deb-src/' /etc/apt/sources.list.d/debian.sources
apt-get update
apt-get install --yes --no-install-recommends \
    build-essential ca-certificates cmake fonts-dejavu-core git jq \
    libaom-dev libass-dev libdav1d-dev libdrm-dev libfontconfig-dev \
    libfreetype-dev libharfbuzz-dev libjpeg-turbo-progs libmp3lame-dev \
    libopus-dev libsoxr-dev libssl-dev libvorbis-dev libvpx-dev \
    libwebp-dev libx264-dev libx265-dev \
    meson ninja-build patchelf pkg-config python3 xz-utils zlib1g-dev
