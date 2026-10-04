# VideoCull FFmpeg

The FFmpeg and FFprobe binaries bundled with [VideoCull](https://github.com/StippieDot/VideoCull),
built from source on GitHub Actions, together with their complete corresponding source.

Everything in this repository is licensed under the GNU General Public License, version 3 or later
(see [LICENSE](LICENSE)). The binaries are FFmpeg built with `--enable-gpl --enable-version3`.

## What is built

FFmpeg as shared libraries plus `ffmpeg.exe` and `ffprobe.exe`, for 64-bit Windows 10 22H2 or newer.
Only what VideoCull needs is enabled, and nothing is detected automatically from the build machine:

- all of FFmpeg's built-in decoders, demuxers and filters
- `libdav1d` (AV1 decoding) and `libx264` (H.264 encoding)
- zlib and bzip2
- hardware decoding through D3D11VA, D3D12VA, DXVA2, NVDEC/CUVID and Intel QSV (libvpl)
- hardware encoding through NVENC, AMF, QSV and Media Foundation
- no network protocols, no `ffplay`, and no capture devices: `libavdevice` only provides the `lavfi`
  test-signal input that VideoCull's tests use

The gcc runtime is linked statically, so the runtime folder contains only FFmpeg's own files and
imports nothing but Windows system DLLs.

## Inputs

- [`sources.lock`](sources.lock): every source archive, with its SHA-256 and download URL.
- [`msys2.lock`](msys2.lock): the exact MSYS2 compiler packages, with their SHA-256.
- [`patches/`](patches): our fixes to upstream sources, applied when a source is unpacked.
- [`scripts/build.sh`](scripts/build.sh): the whole build. It never downloads anything.

## Releases

Each release `ffmpeg-<version>-r<revision>` contains:

| File | Contents |
|---|---|
| `videocull-ffmpeg-<version>-r<revision>-win64.zip` | The runtime folder VideoCull bundles |
| `videocull-ffmpeg-<version>-r<revision>-source.tar` | Complete corresponding source: this recipe, every source archive and the sources of the statically linked compiler runtime |
| `videocull-ffmpeg-<version>-r<revision>-manifest.json` | FFmpeg version, configure options, and hashes of every input and output file |
| `SHA256SUMS` | Checksums of the files above |

GitHub's automatic "Source code" archives contain only this recipe, not the FFmpeg source; use the
`-source.tar` file. Releases are never changed or deleted after publication.

## Building

On Windows, in an MSYS2 UCRT64 shell:

```sh
bash scripts/install-toolchain.sh   # compiler packages from msys2.lock
bash scripts/fetch-sources.sh       # downloads and checks every file in sources.lock
bash scripts/build.sh               # output in out/
bash scripts/smoke-test.sh out
```

The source archive of a release can be rebuilt the same way without network access for sources; CI
does this for every build. Rebuilt binaries have the same files and configuration but are not
expected to be byte-identical.

## Updating

- **FFmpeg or a library:** change its line in `sources.lock` (version, file, SHA-256, URL), raise
  `REVISION` or reset it to 1 for a new FFmpeg version, and push.
- **Compiler toolchain:** delete `msys2.lock`, run the workflow, and commit the `msys2.lock` it
  uploads.
