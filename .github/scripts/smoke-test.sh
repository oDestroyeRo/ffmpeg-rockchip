#!/usr/bin/env bash
set -euo pipefail

package=$(realpath "${1:?Usage: smoke-test.sh PACKAGE_DIRECTORY}")
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT

# Do not let the build environment hide missing libraries in the package.
unset LD_LIBRARY_PATH
for binary in "$package"/bin/*; do
    ldd "$binary" > "$test_dir/ldd"
    if grep -q 'not found' "$test_dir/ldd"; then cat "$test_dir/ldd"; exit 1; fi
    while read -r library; do
        case "$(basename "$library")" in
            libc.so.*|libm.so.*|libpthread.so.*|libdl.so.*|librt.so.*|libresolv.so.*) continue ;;
        esac
        if [[ $(realpath "$library") != "$package/lib/"* ]]; then
            echo "Unbundled runtime library: $library" >&2
            exit 1
        fi
    done < <(awk '/=> \// { print $3 }' "$test_dir/ldd")
done
"$package/bin/ffmpeg" -hide_banner -version
"$package/bin/ffprobe" -hide_banner -version
"$package/bin/ffmpeg" -hide_banner -hwaccels > "$test_dir/hwaccels"
"$package/bin/ffmpeg" -hide_banner -decoders > "$test_dir/decoders"
"$package/bin/ffmpeg" -hide_banner -encoders > "$test_dir/encoders"
"$package/bin/ffmpeg" -hide_banner -filters > "$test_dir/filters"
grep -x rkmpp "$test_dir/hwaccels"
for codec in h264 hevc mjpeg; do
    grep -w "${codec}_rkmpp" "$test_dir/decoders"
    grep -w "${codec}_rkmpp" "$test_dir/encoders"
done
for filter in scale_rkrga vpp_rkrga overlay_rkrga; do
    grep -w "$filter" "$test_dir/filters"
done

# Hosted ARM64 runners have no Rockchip devices; exercise software processing.
"$package/bin/ffmpeg" -hide_banner -loglevel error \
    -f lavfi -i testsrc2=size=128x96:rate=10 -t 1 \
    -c:v mpeg4 -y "$test_dir/video.mp4"
test "$("$package/bin/ffprobe" -v error -select_streams v:0 \
    -show_entries stream=codec_name -of default=nw=1:nk=1 "$test_dir/video.mp4")" = mpeg4
"$package/bin/ffmpeg" -hide_banner -loglevel error \
    -i "$test_dir/video.mp4" -f null -
