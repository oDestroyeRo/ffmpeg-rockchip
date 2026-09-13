ffmpeg-rockchip
=============
This project aims to provide full hardware transcoding pipeline in FFmpeg CLI for Rockchip platforms that support MPP ([Media Process Platform](https://github.com/rockchip-linux/mpp)) and RGA ([2D Raster Graphic Acceleration](https://github.com/airockchip/librga)). This includes hardware decoders, encoders and filters. A typical target platform is RK3588/3588s based devices.

## Hightlights
* MPP decoders support up to 8K 10-bit H.264, HEVC, VP9 and AV1 decoding
* MPP decoders support producing AFBC (ARM Frame Buffer Compression) image
* MPP decoders support de-interlace using IEP (Image Enhancement Processor)
* MPP decoders support allocator half-internal and pure-external modes
* MPP encoders support up to 8K H.264 and HEVC encoding
* MPP encoders support async encoding, AKA frame-parallel
* MPP encoders support consuming AFBC image
* RGA filters support image scaling and pixel format conversion
* RGA filters support image cropping
* RGA filters support image transposing
* RGA filters support blending two images
* RGA filters support async operation
* RGA filters support producing and consuming AFBC image
* Zero-copy DMA in above stages

## How to use
The documentation is available on the [Wiki](https://github.com/nyanmisaka/ffmpeg-rockchip/wiki) page of this project.

## Prebuilt Rockchip releases

This fork includes a [Release Rockchip FFmpeg](.github/workflows/release.yml)
workflow for **Linux ARM64**. Each run tracks the upstream Rockchip branches
`7.0`, `7.1`, `8.0`, and `8.1`, resolves their commit IDs once, and builds the
latest version on each branch. It does not build unpatched FFmpeg release tags.
The recipe lives on this fork's default branch (`master` currently; `main` is
also supported). MPP and RGA revisions are pinned in
[release-sources.json](.github/release-sources.json).

To create a release after installing the workflow on the default branch:

1. Open **Actions → Release Rockchip FFmpeg → Run workflow**.
2. Select the repository's default branch and enable **Publish all four builds
   as a GitHub Release**.
3. Run the workflow. A dated release is published only after all four builds and
   smoke tests pass. A failed asset upload leaves an unpublished draft.

Leave publishing disabled to produce downloadable Actions artifacts only.
Changes under `.github/` also run builds on pushes to `main`/`master` and pull
requests. There is no scheduled build or automatic release on push. Upstream
branch updates are picked up on the next run; custom FFmpeg changes made only
on this fork's default branch are not included in those upstream sources.

Each version provides a binary `.tar.xz`, a matching `-sources.tar.xz`, a
`.sha256` checksum file, and `BUILDINFO.txt`. The binary archive contains
`bin/ffmpeg`, `bin/ffprobe`, and runtime libraries in `lib/`, including MPP,
RGA, DRM, OpenSSL, and zlib. The source archive includes the exact FFmpeg,
MPP, and RGA source trees and the build scripts. Build information records
the resolved source revisions, configure flags, and distribution packages.

Extract the binary archive and keep its `bin/` and `lib/` directories together:

```sh
# Example filename; use the version provided by your release.
tar -xf ffmpeg-8.1.2-rockchip-linux-arm64.tar.xz
./ffmpeg-8.1.2-rockchip-linux-arm64/bin/ffmpeg -hide_banner -hwaccels
./ffmpeg-8.1.2-rockchip-linux-arm64/bin/ffmpeg -hide_banner -filters
```

These builds require a 64-bit ARM Linux userspace with **glibc 2.35 or newer**
(for example Ubuntu 22.04+ or Debian 12+). They are not fully static binaries
and do not target ARM32, Android, or musl-based systems. Hardware acceleration
also requires the Rockchip BSP kernel and device permissions described below.
Hosted ARM64 runners verify startup, RKMPP/RGA registration, and a software
encode/decode round trip; they cannot verify hardware transcoding.

To reproduce a build on Ubuntu 22.04 ARM64:

```sh
sudo bash .github/scripts/install-build-deps.sh
matrix=$(bash .github/scripts/resolve-sources.sh)
commit=$(printf '%s\n' "$matrix" | jq -r '.include[] | select(.series == "8.1") | .commit')
bash .github/scripts/build-release.sh 8.1 "$commit" "$PWD/dist"
```

To rebuild a previous release, use its FFmpeg commit from `BUILDINFO.txt` and
the recipe from its source archive instead of resolving the current branch.


## Codecs and filters
### Decoders/Hwaccel
```
 V..... av1_rkmpp            Rockchip MPP (Media Process Platform) AV1 decoder (codec av1)
 V..... h263_rkmpp           Rockchip MPP (Media Process Platform) H263 decoder (codec h263)
 V..... h264_rkmpp           Rockchip MPP (Media Process Platform) H264 decoder (codec h264)
 V..... hevc_rkmpp           Rockchip MPP (Media Process Platform) HEVC decoder (codec hevc)
 V..... mjpeg_rkmpp          Rockchip MPP (Media Process Platform) MJPEG decoder (codec mjpeg)
 V..... mpeg1_rkmpp          Rockchip MPP (Media Process Platform) MPEG1VIDEO decoder (codec mpeg1video)
 V..... mpeg2_rkmpp          Rockchip MPP (Media Process Platform) MPEG2VIDEO decoder (codec mpeg2video)
 V..... mpeg4_rkmpp          Rockchip MPP (Media Process Platform) MPEG4 decoder (codec mpeg4)
 V..... vp8_rkmpp            Rockchip MPP (Media Process Platform) VP8 decoder (codec vp8)
 V..... vp9_rkmpp            Rockchip MPP (Media Process Platform) VP9 decoder (codec vp9)
```

### Encoders
```
 V..... h264_rkmpp           Rockchip MPP (Media Process Platform) H264 encoder (codec h264)
 V..... hevc_rkmpp           Rockchip MPP (Media Process Platform) HEVC encoder (codec hevc)
 V..... mjpeg_rkmpp          Rockchip MPP (Media Process Platform) MJPEG encoder (codec mjpeg)
```

### Filters
```
 ... overlay_rkrga     VV->V      Rockchip RGA (2D Raster Graphic Acceleration) video compositor
 ... scale_rkrga       V->V       Rockchip RGA (2D Raster Graphic Acceleration) video resizer and format converter
 ... vpp_rkrga         V->V       Rockchip RGA (2D Raster Graphic Acceleration) video post-process (scale/crop/transpose)
```

## Important
* Rockchip BSP/vendor kernel is necessary, 5.10 and 6.1 are two tested versions.
* For the supported maximum resolution and FPS you can refer to the datasheet or TRM.
* User MUST be granted permission to access these device files.
```
# DRM allocator
/dev/dri

# DMA_HEAP allocator
/dev/dma_heap

# RGA filters
/dev/rga

# MPP codecs
/dev/mpp_service

# Optional, for compatibility with older kernels and socs
/dev/iep
/dev/mpp-service
/dev/vpu_service
/dev/vpu-service
/dev/hevc_service
/dev/hevc-service
/dev/rkvdec
/dev/rkvenc
/dev/vepu
/dev/h265e
```

## Todo
* Support MPP VP8 video encoder
* ...

## Acknowledgments

@[hbiyik](https://github.com/hbiyik) @[rigaya](https://github.com/rigaya)

## Disclaimer

This project is an UNOFFICIAL fork of FFmpeg and is NOT the property of Rockchip Electronics Co., Ltd.
The MPP and RGA components used are compatible with FFmpeg by enabling the LGPLv3 license: "./configure --enable-version3".

---

FFmpeg README
=============

FFmpeg is a collection of libraries and tools to process multimedia content
such as audio, video, subtitles and related metadata.

## Libraries

* `libavcodec` provides implementation of a wider range of codecs.
* `libavformat` implements streaming protocols, container formats and basic I/O access.
* `libavutil` includes hashers, decompressors and miscellaneous utility functions.
* `libavfilter` provides means to alter decoded audio and video through a directed graph of connected filters.
* `libavdevice` provides an abstraction to access capture and playback devices.
* `libswresample` implements audio mixing and resampling routines.
* `libswscale` implements color conversion and scaling routines.

## Tools

* [ffmpeg](https://ffmpeg.org/ffmpeg.html) is a command line toolbox to
  manipulate, convert and stream multimedia content.
* [ffplay](https://ffmpeg.org/ffplay.html) is a minimalistic multimedia player.
* [ffprobe](https://ffmpeg.org/ffprobe.html) is a simple analysis tool to inspect
  multimedia content.
* Additional small tools such as `aviocat`, `ismindex` and `qt-faststart`.

## Documentation

The offline documentation is available in the **doc/** directory.

The online documentation is available in the main [website](https://ffmpeg.org)
and in the [wiki](https://trac.ffmpeg.org).

### Examples

Coding examples are available in the **doc/examples** directory.

## License

FFmpeg codebase is mainly LGPL-licensed with optional components licensed under
GPL. Please refer to the LICENSE file for detailed information.

## Contributing

Patches should be submitted to the ffmpeg-devel mailing list using
`git format-patch` or `git send-email`. Github pull requests should be
avoided because they are not part of our review process and will be ignored.
