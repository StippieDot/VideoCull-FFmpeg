# VideoCull FFmpeg

The FFmpeg and FFprobe binaries bundled with [VideoCull](https://github.com/StippieDot/VideoCull),
built from source on GitHub Actions, together with their complete corresponding source.

Everything in this repository is licensed under the GNU General Public License, version 3 or later
(see [LICENSE](LICENSE)). The binaries are FFmpeg built with `--enable-gpl --enable-version3`.

## What is built

FFmpeg as shared libraries plus `ffmpeg` and `ffprobe`, for four platforms, all from the same
[`sources.lock`](sources.lock) and the same configure options except hardware acceleration:

| Platform | Runs on | Hardware acceleration |
|---|---|---|
| `win64` | Windows 10 22H2 or newer, x64 | D3D11VA, D3D12VA, DXVA2, NVDEC/CUVID and Intel QSV (libvpl) decoding; NVENC, AMF, QSV and Media Foundation encoding |
| `linux-x64` | glibc 2.31 or newer (Ubuntu 20.04, Debian 11, Fedora, RHEL 9 and later), x64 | VAAPI (libva, bundled; uses the system's GPU drivers) and NVDEC/CUVID decoding; VAAPI and NVENC encoding |
| `macos-arm64`, `macos-x64` | macOS 12 or newer | VideoToolbox decoding and encoding |

Only what VideoCull needs is enabled, and nothing is detected automatically from the build machine:

- all of FFmpeg's built-in decoders, demuxers and filters
- `libdav1d` (AV1 decoding) and `libx264` (H.264 encoding)
- zlib and bzip2
- no network protocols, no `ffplay`, and no capture devices: `libavdevice` only provides the `lavfi`
  test-signal input that VideoCull's tests use

Each runtime folder loads only its own files and system libraries:

- **Windows:** the gcc runtime is linked statically, so the folder imports nothing but Windows DLLs.
- **Linux:** built in Debian 11, so nothing newer than glibc 2.31 is needed. Besides glibc it loads
  only libdrm, which every system that runs Electron has. The libraries find each other through
  `$ORIGIN`.
- **macOS:** the libraries find each other through `@rpath`, and every file is ad-hoc signed.

## Inputs

- [`sources.lock`](sources.lock): every source archive, with its SHA-256 and download URL.
- [`msys2.lock`](msys2.lock): the exact MSYS2 compiler packages for Windows, with their SHA-256.
- [`scripts/install-toolchain-linux.sh`](scripts/install-toolchain-linux.sh): the Linux toolchain,
  from a fixed snapshot.debian.org date inside a Debian 11 image pinned by digest.
- [`scripts/install-toolchain-macos.sh`](scripts/install-toolchain-macos.sh): the macOS build tools
  (Homebrew; the versions used are recorded in each manifest).
- [`patches/`](patches): our fixes to upstream sources, applied when a source is unpacked.
- [`scripts/build.sh`](scripts/build.sh): the whole build. It never downloads anything.

## Releases

Each release `ffmpeg-<version>-r<revision>` contains:

| File | Contents |
|---|---|
| `videocull-ffmpeg-<version>-r<revision>-win64.zip` | The Windows runtime folder VideoCull bundles |
| `videocull-ffmpeg-<version>-r<revision>-linux-x64.tar.xz`, `-macos-arm64.tar.xz`, `-macos-x64.tar.xz` | The Linux and macOS runtime folders |
| `videocull-ffmpeg-<version>-r<revision>-source.tar` | Complete corresponding source for all four platforms: this recipe, every source archive and the sources of the compiler runtime linked statically into the Windows build |
| `videocull-ffmpeg-<version>-r<revision>-<platform>-manifest.json` | FFmpeg version, configure options, toolchain, and hashes of every input and output file |
| `SHA256SUMS` | Checksums of the files above |

GitHub's automatic "Source code" archives contain only this recipe, not the FFmpeg source; use the
`-source.tar` file. Releases are never changed or deleted after publication.

## Building

```sh
# Windows, in an MSYS2 UCRT64 shell
bash scripts/install-toolchain.sh        # compiler packages from msys2.lock
# Linux, as root in debian:bullseye-slim (digest in .github/workflows/build.yml)
bash scripts/install-toolchain-linux.sh
# macOS, with Xcode
bash scripts/install-toolchain-macos.sh

bash scripts/fetch-sources.sh            # downloads and checks every file in sources.lock
bash scripts/build.sh                    # output in out/
bash scripts/check-runtime.sh out
bash scripts/smoke-test.sh out
```

The source archive of a release can be rebuilt the same way without network access for sources; CI
does this for every Windows build. Rebuilt binaries have the same files and configuration but are not
expected to be byte-identical.

## Updating

- **FFmpeg or a library:** change its line in `sources.lock` (version, file, SHA-256, URL), raise
  `REVISION` or reset it to 1 for a new FFmpeg version, and push.
  Every platform picks up the change; VideoCull then moves all of them with one new release tag.
- **Compiler toolchain:** on Windows, delete `msys2.lock`, run the workflow, and commit the
  `msys2.lock` it uploads. On Linux, change the snapshot date in `install-toolchain-linux.sh` (and the
  image digest in the workflow).
