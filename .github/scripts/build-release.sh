#!/usr/bin/env bash
set -euo pipefail

series=${1:?Usage: build-release.sh SERIES COMMIT OUTPUT_DIRECTORY}
ffmpeg_commit=${2:?Usage: build-release.sh SERIES COMMIT OUTPUT_DIRECTORY}
output=${3:?Usage: build-release.sh SERIES COMMIT OUTPUT_DIRECTORY}
scripts=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
manifest="$scripts/../release-sources.json"
repository=$(jq -er '.ffmpeg.repository' "$manifest")
jobs=${JOBS:-$(nproc)}

[[ $(uname -s) == Linux && $(uname -m) == aarch64 ]] || {
    echo 'Build on Debian 12 or 13 ARM64.' >&2
    exit 1
}
# shellcheck source=/dev/null
source /etc/os-release
case "${ID:-}:${VERSION_ID:-}" in
    debian:12) openssl_package=libssl3; glibc_baseline=2.36 ;;
    debian:13) openssl_package=libssl3t64; glibc_baseline=2.41 ;;
    *) echo 'Build on Debian 12 or 13 ARM64.' >&2; exit 1 ;;
esac
jq -e --arg series "$series" '.ffmpeg.branches | index($series) != null' "$manifest" > /dev/null
mpp_repository=$(jq -er '.mpp.repository' "$manifest")
mpp_commit=${MPP_COMMIT:?Set MPP_COMMIT from resolve-sources.sh}
rga_repository=$(jq -er '.rga.repository' "$manifest")
rga_commit=${RGA_COMMIT:?Set RGA_COMMIT from resolve-sources.sh}
for commit in "$ffmpeg_commit" "$mpp_commit" "$rga_commit"; do
    [[ $commit =~ ^[0-9a-f]{40}$ ]] || exit 1
done

mkdir -p "$output"
output=$(realpath "$output")
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
prefix="$work/prefix"

checkout_source() {
    local url=$1 commit=$2 destination=$3 attempt
    git init --quiet "$destination"
    # Retry transient transfer failures without changing the resolved source.
    for attempt in 1 2 3; do
        if git -C "$destination" -c http.version=HTTP/1.1 \
            fetch --quiet --depth=1 "$url" "$commit"; then
            break
        fi
        if [[ $attempt == 3 ]]; then return 1; fi
    done
    git -C "$destination" checkout --quiet --detach FETCH_HEAD
    test "$(git -C "$destination" rev-parse HEAD)" = "$commit"
}

checkout_source "$repository" "$ffmpeg_commit" "$work/ffmpeg"
checkout_source "$mpp_repository" "$mpp_commit" "$work/mpp"
checkout_source "$rga_repository" "$rga_commit" "$work/rga"
version=$(cat "$work/ffmpeg/RELEASE")
[[ $version == "$series" || $version == "$series".* ]] || {
    echo "Expected FFmpeg $series, got $version." >&2
    exit 1
}
[[ $version =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] || exit 1
name="ffmpeg-${version}-rockchip-linux-arm64-debian${VERSION_ID}"
package="$work/$name"
mkdir -p "$prefix" "$package/bin" "$package/lib" "$package/share/licenses"

cmake -S "$work/mpp" -B "$work/mpp-build" \
    -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$prefix" \
    -DCMAKE_INSTALL_LIBDIR=lib -DBUILD_SHARED_LIBS=ON -DBUILD_TEST=OFF
cmake --build "$work/mpp-build" --parallel "$jobs"
cmake --install "$work/mpp-build"
meson setup "$work/rga-build" "$work/rga" \
    --prefix="$prefix" --libdir=lib --buildtype=release --default-library=shared \
    -Dcpp_args=-fpermissive -Dlibdrm=false -Dlibrga_demo=false
ninja -C "$work/rga-build" -j "$jobs" install

export PKG_CONFIG_PATH="$prefix/lib/pkgconfig"
export LD_LIBRARY_PATH="$prefix/lib"
mkdir "$work/ffmpeg-build"
cd "$work/ffmpeg-build"
"$work/ffmpeg/configure" \
    --prefix="$prefix" --arch=aarch64 --cpu=generic \
    --disable-autodetect --disable-debug --disable-doc --disable-ffplay \
    --disable-shared --enable-static --enable-gpl --enable-version3 \
    --enable-libdrm --enable-rkmpp --enable-rkrga --enable-openssl --enable-zlib
make -j "$jobs"
make install
cp "$prefix/bin/ffmpeg" "$prefix/bin/ffprobe" "$package/bin/"

# Bundle the transitive runtime libraries, leaving glibc and its loader to the OS.
ldd "$package/bin/ffmpeg" "$package/bin/ffprobe" > "$work/ldd.txt"
if grep -q 'not found' "$work/ldd.txt"; then cat "$work/ldd.txt"; exit 1; fi
while read -r library; do
    case "$(basename "$library")" in
        libc.so.*|libm.so.*|libpthread.so.*|libdl.so.*|librt.so.*|libresolv.so.*) continue ;;
    esac
    cp -L "$library" "$package/lib/"
done < <(awk '/=> \// { print $3 }' "$work/ldd.txt" | sort -u)
for binary in "$package"/bin/*; do
    # The dynamic loader, not this shell, expands ORIGIN.
    # shellcheck disable=SC2016
    patchelf --set-rpath '$ORIGIN/../lib' "$binary"
done
for library in "$package"/lib/*; do
    # shellcheck disable=SC2016
    patchelf --set-rpath '$ORIGIN' "$library"
done
cp "$work/ffmpeg"/COPYING* "$work/ffmpeg/LICENSE.md" "$package/share/licenses/"
cp -R "$work/mpp/LICENSES" "$package/share/licenses/mpp"
cp "$work/rga/COPYING" "$package/share/licenses/rga.txt"
for dependency in libdrm2 "$openssl_package" libzstd1 zlib1g libstdc++6 libgcc-s1; do
    cp "/usr/share/doc/$dependency/copyright" "$package/share/licenses/$dependency.txt"
done

{
    printf 'FFmpeg %s (series %s)\n' "$version" "$series"
    printf 'FFmpeg: %s (branch %s) @ %s\n' "$repository" "$series" "$ffmpeg_commit"
    printf 'MPP: %s @ %s\nRGA: %s @ %s\n' "$mpp_repository" "$mpp_commit" "$rga_repository" "$rga_commit"
    printf 'Workflow commit: %s\n' "${GITHUB_SHA:-local}"
    printf 'Build OS: %s\n' "$PRETTY_NAME"
    printf 'Architecture: aarch64; runtime baseline: Debian %s (glibc %s)\n' "$VERSION_ID" "$glibc_baseline"
    printf 'Hardware transcoding requires a Rockchip BSP kernel and device permissions.\n'
    dpkg-query -W -f='${Package}=${Version}\n' \
        gcc g++ libc6 libdrm2 "$openssl_package" libzstd1 zlib1g libstdc++6 libgcc-s1
    "$package/bin/ffmpeg" -version
} > "$package/BUILDINFO.txt"

# Relink against bundled libraries and smoke-test the relocatable package.
unset LD_LIBRARY_PATH
bash "$scripts/smoke-test.sh" "$package"
tar -C "$work" -cJf "$output/$name.tar.xz" "$name"
cp "$package/BUILDINFO.txt" "$output/$name.BUILDINFO.txt"

# Publish the exact FFmpeg/MPP/RGA sources alongside the binary distribution.
sources="$work/$name-sources"
mkdir -p "$sources/recipe/.github/scripts"
for component in ffmpeg mpp rga; do
    mkdir "$sources/$component"
    git -C "$work/$component" archive HEAD | tar -x -C "$sources/$component"
done
cp "$manifest" "$sources/recipe/.github/"
cp "$scripts/"*.sh "$sources/recipe/.github/scripts/"
cp "$package/BUILDINFO.txt" "$sources/"
tar -C "$work" -cJf "$output/$name-sources.tar.xz" "$name-sources"
cd "$output"
sha256sum "$name.tar.xz" "$name-sources.tar.xz" > "$name.sha256"
