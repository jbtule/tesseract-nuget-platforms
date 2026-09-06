#!/usr/bin/env bash
# Builds Leptonica + Tesseract via vcpkg's own ports for one RID and stages
# the resulting shared libraries under stage/<rid>/native.
#
# Usage: scripts/build-native.sh <linux-x64|osx-arm64>
#
# We consume vcpkg's tesseract/leptonica ports rather than building from
# their upstream source tags ourselves: vcpkg's maintainers already carry
# a set of ARM64/cross-compile/CMake patches on top of upstream (see the
# README's "Vendored patches"-adjacent notes on win-arm64) that we'd
# otherwise have to reproduce and maintain by hand. Dynamic (non-default)
# triplets are used explicitly because vcpkg's Linux/macOS triplets default
# to static libraries, and we need real shared libs for dlopen-style
# loading via CustomSearchPath.
set -euo pipefail

RID="${1:?usage: build-native.sh <linux-x64|osx-arm64>}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/versions.env"

WORK="$(mktemp -d)"
STAGE="$ROOT/stage/$RID/native"
mkdir -p "$STAGE"

case "$RID" in
  linux-x64)  TRIPLET=x64-linux-dynamic ;;
  osx-arm64)  TRIPLET=arm64-osx-dynamic ;;
  *) echo "unknown RID: $RID" >&2; exit 1 ;;
esac

git clone --branch "$VCPKG_REF" --depth 1 https://github.com/microsoft/vcpkg "$WORK/vcpkg"
"$WORK/vcpkg/bootstrap-vcpkg.sh" -disableMetrics
"$WORK/vcpkg/vcpkg" install tesseract leptonica --triplet "$TRIPLET" --clean-after-build

INSTALLED="$WORK/vcpkg/installed/$TRIPLET"

case "$RID" in
  linux-x64)
    cp -P "$INSTALLED"/lib/libtesseract*.so* "$STAGE/"
    cp -P "$INSTALLED"/lib/libleptonica*.so* "$STAGE/"
    ;;
  osx-arm64)
    cp -P "$INSTALLED"/lib/libtesseract*.dylib "$STAGE/"
    cp -P "$INSTALLED"/lib/libleptonica*.dylib "$STAGE/"
    ;;
esac

cp "$INSTALLED/share/tesseract/copyright" "$ROOT/stage/$RID/tesseract-LICENSE.txt" 2>/dev/null || true
cp "$INSTALLED/share/leptonica/copyright" "$ROOT/stage/$RID/leptonica-LICENSE.txt" 2>/dev/null || true

echo "== Staged $RID (tesseract/leptonica versions from vcpkg $VCPKG_REF) =="
ls -la "$STAGE"

# NOTE: charlesw/tesseract's interop layer resolves the library by a base
# name (see TesseractEnviornment / InteropDotNet in the consuming project).
# If the consumer expects an exact filename (e.g. "libtesseract.so" rather
# than a versioned "libtesseract.5.5.2.so"), add a symlink/copy step here
# to match it -- confirm against the exact DllImport name in use before
# first release.
