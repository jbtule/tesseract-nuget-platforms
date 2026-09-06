#!/usr/bin/env bash
# Builds Leptonica + Tesseract via vcpkg's own ports for one RID and stages
# the resulting shared libraries under stage/<rid>/native.
#
# Usage: scripts/build-native.sh <linux-x64|linux-arm64|osx-arm64>
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

RID="${1:?usage: build-native.sh <linux-x64|linux-arm64|osx-arm64>}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/versions.env"

WORK="$(mktemp -d)"
STAGE="$ROOT/stage/$RID/native"
mkdir -p "$STAGE"

case "$RID" in
  linux-x64)   TRIPLET=x64-linux-dynamic ;;
  linux-arm64) TRIPLET=arm64-linux-dynamic ;;
  osx-arm64)   TRIPLET=arm64-osx-dynamic ;;
  *) echo "unknown RID: $RID" >&2; exit 1 ;;
esac

git clone --branch "$VCPKG_REF" --depth 1 https://github.com/microsoft/vcpkg "$WORK/vcpkg"
"$WORK/vcpkg/bootstrap-vcpkg.sh" -disableMetrics
"$WORK/vcpkg/vcpkg" install tesseract leptonica --triplet "$TRIPLET" --clean-after-build

INSTALLED="$WORK/vcpkg/installed/$TRIPLET"

# Copy every shared library vcpkg installed, not just libtesseract*/
# libleptonica*: with a dynamic triplet, Leptonica's own codec dependencies
# (giflib, libjpeg-turbo, openjpeg, libpng, zlib, tiff, libwebp) and
# Tesseract's own mandatory curl/libarchive dependencies (each with further
# transitive deps of their own) all become separate shared libraries that
# have to be present at runtime too -- confirmed missing ones (started with
# libgif) cause a silent dlopen failure, not a clear error, since
# InteropDotNet's Unix loader swallows the underlying exception.
case "$RID" in
  linux-x64|linux-arm64) cp -P "$INSTALLED"/lib/*.so* "$STAGE/" ;;
  osx-arm64)             cp -P "$INSTALLED"/lib/*.dylib "$STAGE/" ;;
esac

# Best-effort: grab every dependency's license text too, not just
# tesseract/leptonica's own -- there are a lot more of them now.
mkdir -p "$ROOT/stage/$RID/licenses"
for copyright in "$INSTALLED"/share/*/copyright; do
  [ -f "$copyright" ] || continue
  pkg="$(basename "$(dirname "$copyright")")"
  cp "$copyright" "$ROOT/stage/$RID/licenses/$pkg.txt"
done

# Fail loud (not just "the app breaks weirdly downstream") if either main
# library is somehow missing from what got copied.
shopt -s nullglob
tesseract_libs=("$STAGE"/libtesseract*)
leptonica_libs=("$STAGE"/libleptonica*)
shopt -u nullglob
if [ ${#tesseract_libs[@]} -eq 0 ]; then
  echo "No libtesseract* found in $STAGE after copying $INSTALLED/lib -- vcpkg install must have failed silently." >&2
  exit 1
fi
if [ ${#leptonica_libs[@]} -eq 0 ]; then
  echo "No libleptonica* found in $STAGE after copying $INSTALLED/lib -- vcpkg install must have failed silently." >&2
  exit 1
fi

echo "== Staged $RID (tesseract/leptonica versions from vcpkg $VCPKG_REF) =="
ls -la "$STAGE"
