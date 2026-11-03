#!/usr/bin/env bash
# Installs the Linux build toolchain. Runs as root inside the pinned Debian 11 image (see
# .github/workflows/build.yml). Packages come from one fixed snapshot.debian.org date, so every build
# gets the same compiler and tools. Debian 11's glibc 2.31 sets the oldest glibc the binaries need.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SNAPSHOT=20260815T000000Z

# Plain HTTP: the slim image has no CA certificates, and apt checks the signed Release files anyway.
rm -f /etc/apt/sources.list.d/*
cat > /etc/apt/sources.list <<LIST
deb http://snapshot.debian.org/archive/debian/$SNAPSHOT bullseye main
deb http://snapshot.debian.org/archive/debian/$SNAPSHOT bullseye-updates main
deb http://snapshot.debian.org/archive/debian-security/$SNAPSHOT bullseye-security main
LIST
apt-get -o Acquire::Check-Valid-Until=false update
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
  gcc libc6-dev make binutils nasm pkg-config meson ninja-build patch xz-utils bzip2 libdrm-dev
dpkg-query -W -f='${Package} ${Version}\n' > "$ROOT/toolchain-installed.txt"
