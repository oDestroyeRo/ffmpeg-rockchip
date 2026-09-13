#!/usr/bin/env bash
set -euo pipefail

package=$(realpath "${1:?Usage: smoke-test.sh PACKAGE_DIRECTORY}")
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT

# Do not let the build environment hide missing libraries in the package.
unset LD_LIBRARY_PATH
# Exercise the supplied font configuration, even on a host with installed fonts.
export FONTCONFIG_FILE="$package/share/fonts/fonts.conf"
for binary in "$package"/bin/*; do
    ldd "$binary" > "$test_dir/ldd"
    if grep -q 'not found' "$test_dir/ldd"; then cat "$test_dir/ldd"; exit 1; fi
    while read -r library; do
        case "$(basename "$library")" in
            libc.so.*|libm.so.*|libmvec.so.*|libpthread.so.*|libdl.so.*|librt.so.*|libresolv.so.*) continue ;;
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
for codec in libx264 libx264rgb libx265 libwebp libwebp_anim libvpx libvpx-vp9 \
    libaom-av1 libopus libmp3lame libvorbis; do
    grep -w "$codec" "$test_dir/encoders"
done
grep -w libdav1d "$test_dir/decoders"
for filter in ass subtitles drawtext; do
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

encode_video() {
    local encoder=$1 codec=$2 extension=$3
    shift 3
    local sample="$test_dir/$encoder.$extension"
    "$package/bin/ffmpeg" -hide_banner -loglevel error \
        -f lavfi -i testsrc2=size=128x96:rate=10 -frames:v 2 \
        -c:v "$encoder" -threads 2 "$@" -y "$sample"
    test "$("$package/bin/ffprobe" -v error -select_streams v:0 \
        -show_entries stream=codec_name -of default=nw=1:nk=1 "$sample")" = "$codec"
    "$package/bin/ffmpeg" -hide_banner -loglevel error -i "$sample" -f null -
}
encode_video libx264 h264 mp4 -preset ultrafast
encode_video libx265 hevc mp4 -preset ultrafast -x265-params pools=1:frame-threads=1:log-level=error
encode_video libvpx vp8 webm -deadline realtime -cpu-used 8
encode_video libvpx-vp9 vp9 webm -deadline realtime -cpu-used 8
encode_video libaom-av1 av1 ivf -cpu-used 8 -crf 40 -b:v 0
"$package/bin/ffmpeg" -hide_banner -loglevel error -c:v libdav1d \
    -i "$test_dir/libaom-av1.ivf" -f null -

for encoder in libwebp libwebp_anim mjpeg; do
    extension=webp
    if [[ $encoder == mjpeg ]]; then extension=jpg; fi
    "$package/bin/ffmpeg" -hide_banner -loglevel error \
        -f lavfi -i testsrc2=size=128x96 -frames:v 1 -c:v "$encoder" \
        -threads 2 -update 1 -y "$test_dir/$encoder.$extension"
    "$package/bin/ffmpeg" -hide_banner -loglevel error \
        -i "$test_dir/$encoder.$extension" -f null -
done

for encoder in libopus libmp3lame libvorbis; do
    case "$encoder" in
        libopus) extension=ogg; codec=opus ;;
        libmp3lame) extension=mp3; codec=mp3 ;;
        libvorbis) extension=ogg; codec=vorbis ;;
    esac
    sample="$test_dir/$encoder.$extension"
    "$package/bin/ffmpeg" -hide_banner -loglevel error \
        -f lavfi -i sine=frequency=440:sample_rate=32000 -t 0.2 \
        -af aresample=48000:resampler=soxr -c:a "$encoder" -y "$sample"
    test "$("$package/bin/ffprobe" -v error -select_streams a:0 \
        -show_entries stream=codec_name -of default=nw=1:nk=1 "$sample")" = "$codec"
    "$package/bin/ffmpeg" -hide_banner -loglevel error -i "$sample" -f null -
done

# A bundled font makes text/subtitle rendering usable on minimal installations.
cp "$package/share/fonts/DejaVuSans.ttf" "$test_dir/"
cd "$test_dir"
printf '1\n00:00:00,000 --> 00:00:01,000\nRockchip subtitle test\n' > subtitles.srt
"$package/bin/ffmpeg" -hide_banner -loglevel error \
    -f lavfi -i testsrc2=size=320x240 -frames:v 1 \
    -vf "drawtext=fontfile=DejaVuSans.ttf:text=Rockchip,subtitles=subtitles.srt:fontsdir=." -f null -

# Exercise libjpeg-turbo separately, then decode its output with FFmpeg.
"$package/bin/ffmpeg" -hide_banner -loglevel error \
    -f lavfi -i testsrc2=size=128x96 -frames:v 1 -threads 2 -y input.ppm
"$package/bin/cjpeg" -quality 85 -outfile turbo.jpg input.ppm
"$package/bin/jpegtran" -rotate 90 -outfile rotated.jpg turbo.jpg
"$package/bin/djpeg" -outfile decoded.ppm rotated.jpg
test -s decoded.ppm
"$package/bin/ffmpeg" -hide_banner -loglevel error -i rotated.jpg -f null -
test "$("$package/bin/ffprobe" -v error -select_streams v:0 \
    -show_entries stream=width,height -of csv=p=0 rotated.jpg)" = 96,128
