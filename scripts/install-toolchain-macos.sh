#!/usr/bin/env bash
# Installs the macOS build tools with Homebrew. The compiler is the runner's Xcode. Homebrew cannot
# pin versions, so the versions used are recorded in toolchain-installed.txt and in the manifest.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TOOLS=(nasm pkgconf meson ninja)

brew install "${TOOLS[@]}"
{
  echo "macOS $(sw_vers -productVersion) $(uname -m)"
  xcodebuild -version | tr '\n' ' '; echo
  clang --version | head -n 1
  brew list --versions "${TOOLS[@]}"
} > "$ROOT/toolchain-installed.txt"
