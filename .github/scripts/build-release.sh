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
    debian:12) glibc_baseline=2.36 ;;
    debian:13) glibc_baseline=2.41 ;;
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
mkdir -p "$prefix" "$package/bin" "$package/lib" "$package/share/licenses" "$package/share/fonts"

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
text_options=(--enable-libass --enable-libfontconfig --enable-libfreetype)
# FFmpeg 6.0 predates the separate harfbuzz configure option.
if grep -q -- '--enable-libharfbuzz' "$work/ffmpeg/configure"; then
    text_options+=(--enable-libharfbuzz)
fi
"$work/ffmpeg/configure" \
    --prefix="$prefix" --arch=aarch64 --cpu=generic \
    --disable-autodetect --disable-debug --disable-doc --disable-ffplay \
    --disable-shared --enable-static --enable-gpl --enable-version3 \
    --enable-libdrm --enable-rkmpp --enable-rkrga --enable-openssl --enable-zlib \
    --enable-libx264 --enable-libx265 --enable-libwebp --enable-libvpx \
    --enable-libaom --enable-libdav1d --enable-libopus --enable-libmp3lame \
    --enable-libvorbis --enable-libsoxr "${text_options[@]}"
make -j "$jobs"
make install
cp "$prefix/bin/ffmpeg" "$prefix/bin/ffprobe" "$package/bin/"
# FFmpeg uses its native JPEG codec; these are separate libjpeg-turbo tools.
cp /usr/bin/cjpeg /usr/bin/djpeg /usr/bin/jpegtran "$package/bin/"
cp /usr/share/fonts/truetype/dejavu/DejaVuSans.ttf "$package/share/fonts/"
cat > "$package/share/fonts/fonts.conf" <<'EOF'
<?xml version="1.0"?>
<!DOCTYPE fontconfig SYSTEM "urn:fontconfig:fonts.dtd">
<fontconfig>
  <dir prefix="relative">.</dir>
  <cachedir prefix="xdg">fontconfig</cachedir>
</fontconfig>
EOF

# Bundle the transitive runtime libraries, leaving glibc and its loader to the OS.
ldd "$package"/bin/* > "$work/ldd.txt"
if grep -q 'not found' "$work/ldd.txt"; then cat "$work/ldd.txt"; exit 1; fi
runtime_packages=(libjpeg-turbo-progs fonts-dejavu-core)
while read -r library; do
    case "$(basename "$library")" in
        libc.so.*|libm.so.*|libmvec.so.*|libpthread.so.*|libdl.so.*|librt.so.*|libresolv.so.*) continue ;;
    esac
    cp -L "$library" "$package/lib/"
    if [[ $library != "$prefix/lib/"* ]]; then
        # Debian 12/13 may record the pre- or post-usrmerge pathname.
        owner=$(dpkg-query -S "$library" 2>/dev/null || \
            dpkg-query -S "/usr$library" 2>/dev/null || \
            dpkg-query -S "${library#/usr}" 2>/dev/null)
        runtime_packages+=("${owner%%: /*}")
    fi
done < <(awk '/=> \// { print $3 }' "$work/ldd.txt" | sort -u)
mapfile -t runtime_packages < <(printf '%s\n' "${runtime_packages[@]}" | sort -u)
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
for dependency in "${runtime_packages[@]}"; do
    dependency=${dependency%%:*}
    cp -L "/usr/share/doc/$dependency/copyright" "$package/share/licenses/$dependency.txt"
done
# Debian copyright notices can reference these complete license texts.
cp -R /usr/share/common-licenses "$package/share/licenses/"

{
    printf 'FFmpeg %s (series %s)\n' "$version" "$series"
    printf 'FFmpeg: %s (branch %s) @ %s\n' "$repository" "$series" "$ffmpeg_commit"
    printf 'MPP: %s @ %s\nRGA: %s @ %s\n' "$mpp_repository" "$mpp_commit" "$rga_repository" "$rga_commit"
    printf 'Workflow commit: %s\n' "${GITHUB_SHA:-local}"
    printf 'Build OS: %s\n' "$PRETTY_NAME"
    printf 'Architecture: aarch64; runtime baseline: Debian %s (glibc %s)\n' "$VERSION_ID" "$glibc_baseline"
    printf 'Hardware transcoding requires a Rockchip BSP kernel and device permissions.\n'
    dpkg-query -W -f='${Package}=${Version} (source ${source:Package}=${source:Version})\n' \
        gcc g++ libc6 "${runtime_packages[@]}"
    "$package/bin/ffmpeg" -version
} > "$package/BUILDINFO.txt"

# Relink against bundled libraries and smoke-test the relocatable package.
unset LD_LIBRARY_PATH
bash "$scripts/smoke-test.sh" "$package"
tar -C "$work" -cJf "$output/$name.tar.xz" "$name"
cp "$package/BUILDINFO.txt" "$output/$name.BUILDINFO.txt"

# Publish the exact FFmpeg/MPP/RGA and bundled Debian component sources.
sources="$work/$name-sources"
mkdir -p "$sources/recipe/.github/scripts" "$sources/debian"
for component in ffmpeg mpp rga; do
    mkdir "$sources/$component"
    git -C "$work/$component" archive HEAD | tar -x -C "$sources/$component"
done
cp "$manifest" "$sources/recipe/.github/"
cp "$scripts/"*.sh "$sources/recipe/.github/scripts/"
cp "$package/BUILDINFO.txt" "$sources/"
dpkg-query -W -f='${source:Package}=${source:Version}\n' "${runtime_packages[@]}" \
    | sort -u > "$sources/debian/SOURCES.txt"
mapfile -t debian_sources < "$sources/debian/SOURCES.txt"
(cd "$sources/debian" && apt-get source --download-only "${debian_sources[@]}")
tar -C "$work" -cJf "$output/$name-sources.tar.xz" "$name-sources"
cd "$output"
sha256sum "$name.tar.xz" "$name-sources.tar.xz" > "$name.sha256"
