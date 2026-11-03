#!/usr/bin/env bash
# Builds the FFmpeg runtime VideoCull ships, using only the verified files in SOURCES_DIR.
# Every platform builds the same FFmpeg, dav1d, x264, zlib and bzip2 from sources.lock; only the
# hardware acceleration differs. Never downloads anything, so the published source archive is enough
# to repeat it. Toolchains:
#   win64        MSYS2 UCRT64 shell with the packages from msys2.lock (install-toolchain.sh)
#   linux-x64    Debian 11 image (install-toolchain-linux.sh)
#   macos-*      Xcode plus Homebrew tools (install-toolchain-macos.sh)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/scripts/lib.sh"
SRC="${SOURCES_DIR:-$ROOT/sources}"
WORK="${WORK_DIR:-$ROOT/work}"
OUT="${OUT_DIR:-$ROOT/out}"
PREFIX="$WORK/prefix"
PLATFORM="$(build_platform)"
JOBS="$(nproc 2> /dev/null || sysctl -n hw.ncpu)"

SOURCES_DIR="$SRC" bash "$ROOT/scripts/fetch-sources.sh" --offline
mkdir -p "$PREFIX/include" "$PREFIX/lib/pkgconfig" "$OUT"

# Dependencies come only from our own prefix, never from packages that happen to be installed on the
# build machine. FFmpeg's --disable-autodetect below enforces the same for its optional libraries.
export PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig"
export PKG_CONFIG_PATH=""

# Strings, not arrays: macOS ships bash 3.2, where an empty array fails under set -u.
PIC=""
case "$PLATFORM" in
  win64)
    # The linker prefers libwinpthread.dll.a over libwinpthread.a in the same folder, which would make
    # the DLLs import libwinpthread-1.dll. Static copies in our prefix (searched first) avoid that.
    cp "$MINGW_PREFIX/lib/libwinpthread.a" "$PREFIX/lib/libwinpthread.a"
    cp "$MINGW_PREFIX/lib/libwinpthread.a" "$PREFIX/lib/libpthread.a"
    ;;
  linux-x64)
    PIC=-fPIC
    # The one system library used on purpose: libva needs libdrm, which every system that runs
    # Electron already has (through libgbm), so it is not bundled.
    cp /usr/lib/x86_64-linux-gnu/pkgconfig/libdrm.pc "$PREFIX/lib/pkgconfig/"
    ;;
  macos-*)
    # The oldest macOS that VideoCull's Electron version supports.
    export MACOSX_DEPLOYMENT_TARGET=12.0
    ;;
esac

step() { echo "::group::$1"; SECONDS=0; }
done_step() { echo "$1 took ${SECONDS}s"; echo "::endgroup::"; }

step zlib
d="$(unpack zlib)"
if [[ "$PLATFORM" == win64 ]]; then
  make -C "$d" -f win32/Makefile.gcc -j"$JOBS" libz.a
  cp "$d/zlib.h" "$d/zconf.h" "$PREFIX/include/"
  cp "$d/libz.a" "$PREFIX/lib/"
else
  (cd "$d" && CFLAGS="-O2 $PIC" ./configure --static --prefix="$PREFIX" && make -j"$JOBS" && make install)
fi
done_step zlib

step bzip2
d="$(unpack bzip2)"
make -C "$d" -j"$JOBS" libbz2.a CC=gcc CFLAGS="-O2 $PIC -D_FILE_OFFSET_BITS=64"
cp "$d/bzlib.h" "$PREFIX/include/"
cp "$d/libbz2.a" "$PREFIX/lib/"
done_step bzip2

step x264
d="$(unpack x264)"
x264_pic=""
[[ "$PLATFORM" == win64 ]] || x264_pic=--enable-pic
(cd "$d" && ./configure --prefix="$PREFIX" --enable-static $x264_pic --disable-cli --disable-opencl \
  --disable-lavf --disable-swscale --disable-ffms --disable-gpac --disable-lsmash \
  && make -j"$JOBS" && make install)
done_step x264

step dav1d
d="$(unpack dav1d)"
meson setup "$d/build" "$d" --prefix="$PREFIX" --libdir=lib --buildtype=release \
  --default-library=static --wrap-mode=nodownload -Denable_tools=false -Denable_tests=false
ninja -C "$d/build" install
done_step dav1d

if [[ "$PLATFORM" == win64 ]]; then
  step libvpl
  d="$(unpack libvpl)"
  cmake -S "$d" -B "$d/build" -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$PREFIX" \
    -DCMAKE_INSTALL_LIBDIR=lib -DBUILD_SHARED_LIBS=OFF -DBUILD_TOOLS=OFF -DBUILD_EXAMPLES=OFF \
    -DBUILD_TESTS=OFF -DINSTALL_EXAMPLES=OFF
  ninja -C "$d/build" install
  done_step libvpl
fi

if [[ "$PLATFORM" == linux-x64 ]]; then
  step libva
  d="$(unpack libva)"
  # Shipped next to FFmpeg so it starts on systems without libva; the GPU drivers it loads are the
  # system's. Distributions keep them in different folders, and libva searches each in turn
  # (LIBVA_DRIVERS_PATH, which Flatpak sets, still takes precedence).
  meson setup "$d/build" "$d" --prefix="$PREFIX" --libdir=lib --buildtype=release \
    -Ddriverdir=/usr/lib/x86_64-linux-gnu/dri:/usr/lib64/dri:/usr/lib/dri \
    -Dwith_x11=no -Dwith_glx=no -Dwith_wayland=no -Dwith_win32=no -Denable_docs=false
  ninja -C "$d/build" install
  done_step libva
fi

if [[ "$PLATFORM" == win64 || "$PLATFORM" == linux-x64 ]]; then
  step headers
  d="$(unpack nv-codec-headers)"
  make -C "$d" PREFIX="$PREFIX" install
  if [[ "$PLATFORM" == win64 ]]; then
    d="$(unpack amf-headers)"
    mkdir -p "$PREFIX/include/AMF"
    cp -r "$d/AMF/." "$PREFIX/include/AMF/"
  fi
  done_step headers
fi

step ffmpeg
d="$(unpack ffmpeg)"
INSTALL="$WORK/ffmpeg-install"
# Everything optional is listed explicitly; nothing is auto-detected from the build machine.
common=(
  --prefix="$INSTALL"
  --enable-gpl --enable-version3
  --enable-shared --disable-static
  --disable-autodetect
  --disable-debug --disable-doc --disable-ffplay --disable-network
  --disable-indevs --enable-indev=lavfi --disable-outdevs
  --enable-zlib --enable-bzlib
  --enable-libdav1d --enable-libx264
  --pkg-config-flags=--static
  --extra-cflags="-I$PREFIX/include"
  --extra-version=videocull
)
case "$PLATFORM" in
  win64) platform=(
    --enable-w32threads
    --enable-d3d11va --enable-d3d12va --enable-dxva2 --enable-mediafoundation
    --enable-ffnvcodec --enable-cuvid --enable-nvdec --enable-nvenc
    --enable-amf --enable-libvpl
    # gcc runtime libraries are linked statically so the runtime folder needs no MinGW DLLs.
    --extra-ldflags="-L$PREFIX/lib -static-libgcc -static-libstdc++"
    --extra-libs="-Wl,-Bstatic -lstdc++ -lwinpthread -Wl,-Bdynamic"
  ) ;;
  linux-x64) platform=(
    --enable-pthreads
    --enable-vaapi
    --enable-ffnvcodec --enable-cuvid --enable-nvdec --enable-nvenc
    --extra-ldflags="-L$PREFIX/lib"
    # Binaries and libraries find each other in their own folder. Make turns $$ into $, and the
    # quotes keep the shell from expanding $ORIGIN.
    --extra-ldexeflags="-Wl,-rpath,'\$\$ORIGIN'"
    --extra-ldsoflags="-Wl,-rpath,'\$\$ORIGIN'"
  ) ;;
  macos-*) platform=(
    --enable-pthreads
    --enable-videotoolbox
    --extra-ldflags="-L$PREFIX/lib"
    # Binaries and libraries find each other in their own folder.
    --install-name-dir=@rpath
    --extra-ldexeflags=-Wl,-rpath,@loader_path
  ) ;;
esac
(cd "$d" && ./configure "${common[@]}" "${platform[@]}" && make -j"$JOBS" && make install)
done_step ffmpeg

case "$PLATFORM" in
  win64)
    cp "$INSTALL/bin/ffmpeg.exe" "$INSTALL/bin/ffprobe.exe" "$INSTALL"/bin/*.dll "$OUT/"
    strip --strip-unneeded "$OUT"/*.exe "$OUT"/*.dll
    ;;
  linux-x64)
    cp "$INSTALL/bin/ffmpeg" "$INSTALL/bin/ffprobe" "$OUT/"
    # Each library once, under the name the binaries load (its SONAME), not the development symlinks.
    for so in "$INSTALL"/lib/*.so "$PREFIX"/lib/libva.so "$PREFIX"/lib/libva-drm.so; do
      soname="$(readelf -d "$so" | sed -n 's/.*(SONAME).*\[\(.*\)\]/\1/p')"
      cp -L "$(dirname "$so")/$soname" "$OUT/"
    done
    strip --strip-unneeded "$OUT"/*
    ;;
  macos-*)
    cp "$INSTALL/bin/ffmpeg" "$INSTALL/bin/ffprobe" "$OUT/"
    # Each library once, under its install name (@rpath/libavcodec.62.dylib and so on).
    for dylib in "$INSTALL"/lib/*.dylib; do
      name="$(otool -D "$dylib" | tail -n 1)"
      cp -L "$INSTALL/lib/${name#@rpath/}" "$OUT/"
    done
    strip -x "$OUT"/*
    # Stripping invalidates the linker's ad-hoc signature, and Apple silicon runs no unsigned code.
    codesign --force --sign - "$OUT"/*
    ;;
esac
cp "$d/COPYING.GPLv3" "$OUT/LICENSE.txt"

# Licence texts of everything compiled into the binaries. The permissive licences among them
# require their notice to travel with the binaries.
L="$OUT/licenses"
mkdir -p "$L"
cp "$WORK/ffmpeg/LICENSE.md" "$L/ffmpeg.txt"
cp "$WORK/dav1d/COPYING" "$L/dav1d.txt"
cp "$WORK/x264/COPYING" "$L/x264.txt"
cp "$WORK/zlib/LICENSE" "$L/zlib.txt"
cp "$WORK/bzip2/LICENSE" "$L/bzip2.txt"
if [[ "$PLATFORM" == win64 || "$PLATFORM" == linux-x64 ]]; then
  # The header package carries its MIT notice only in the header comments.
  sed -n '1,/^ \*\//p' "$WORK/nv-codec-headers/include/ffnvcodec/nvEncodeAPI.h" > "$L/nv-codec-headers.txt"
fi
if [[ "$PLATFORM" == linux-x64 ]]; then
  cp "$WORK/libva/COPYING" "$L/libva.txt"
fi
if [[ "$PLATFORM" == win64 ]]; then
  cp "$WORK/libvpl/LICENSE" "$L/libvpl.txt"
  sed -n '1,/^#ifndef/p' "$WORK/amf-headers/AMF/core/Factory.h" | sed '$d' > "$L/amf-headers.txt"
  for runtime in winpthreads crt; do
    found="$(find "$MINGW_PREFIX/share/licenses" -maxdepth 2 -ipath "*$runtime*" -type f | head -n 1)"
    [[ -n "$found" ]] || { echo "no licence file for $runtime in $MINGW_PREFIX/share/licenses" >&2; exit 1; }
    cp "$found" "$L/mingw-w64-$runtime.txt"
  done
fi
ls -lR "$OUT"
