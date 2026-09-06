#!/usr/bin/env bash
# Builds Leptonica + Tesseract from source for one RID and stages the
# resulting shared libraries under stage/<rid>/native.
#
# Usage: scripts/build-native.sh <linux-x64|osx-x64|osx-arm64>
#
# Image-codec dependencies (zlib/libpng/libjpeg-turbo/tiff/libwebp) are
# pulled in as static libs via vcpkg so the packaged .so/.dylib doesn't
# drag in a pile of system-library version requirements on the consumer's
# machine. Leptonica and Tesseract themselves are always built from their
# pinned source tags in versions.env.
set -euo pipefail

RID="${1:?usage: build-native.sh <linux-x64|osx-x64|osx-arm64>}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/versions.env"

WORK="$(mktemp -d)"
STAGE="$ROOT/stage/$RID/native"
mkdir -p "$STAGE"

case "$RID" in
  linux-x64)  TRIPLET=x64-linux-release;  ARCH_DIR=x64 ;;
  osx-x64)    TRIPLET=x64-osx-release;    ARCH_DIR=x64 ;;
  osx-arm64)  TRIPLET=arm64-osx-release;  ARCH_DIR=arm64 ;;
  *) echo "unknown RID: $RID" >&2; exit 1 ;;
esac
# charlesw/tesseract's LibraryLoader always appends a platform-name subfolder
# ("x86"/"x64", or "arm64" with the vendor/tesseract patch) under whatever
# base directory it's given -- so the actual libraries need to live one
# level deeper than "native/", at "native/<ARCH_DIR>/".
STAGE="$STAGE/$ARCH_DIR"
mkdir -p "$STAGE"

# custom release-only triplets so vcpkg doesn't waste time on debug builds
VCPKG_OVERLAY="$WORK/triplets"
mkdir -p "$VCPKG_OVERLAY"
BASE_TRIPLET="${TRIPLET%-release}"
cat > "$VCPKG_OVERLAY/$TRIPLET.cmake" <<EOF
include(\${CMAKE_CURRENT_LIST_DIR}/../../vcpkg/triplets/$BASE_TRIPLET.cmake OPTIONAL)
if(NOT DEFINED VCPKG_TARGET_ARCHITECTURE)
  include(\${CMAKE_CURRENT_LIST_DIR}/../../vcpkg/triplets/community/$BASE_TRIPLET.cmake OPTIONAL)
endif()
set(VCPKG_BUILD_TYPE release)
EOF

git clone --depth 1 https://github.com/microsoft/vcpkg "$WORK/vcpkg"
"$WORK/vcpkg/bootstrap-vcpkg.sh" -disableMetrics
"$WORK/vcpkg/vcpkg" install zlib libpng libjpeg-turbo tiff libwebp \
  --triplet "$BASE_TRIPLET" --overlay-triplets="$VCPKG_OVERLAY" --clean-after-build

VCPKG_TOOLCHAIN="$WORK/vcpkg/scripts/buildsystems/vcpkg.cmake"

if [ "$RID" = "osx-arm64" ]; then
  OSX_ARCH=arm64
else
  OSX_ARCH=x86_64
fi

git clone --depth 1 --branch "$LEPTONICA_VERSION" https://github.com/DanBloomberg/leptonica "$WORK/leptonica"
cmake -S "$WORK/leptonica" -B "$WORK/leptonica/build" \
  -DCMAKE_BUILD_TYPE=Release \
  -DBUILD_SHARED_LIBS=ON \
  -DCMAKE_TOOLCHAIN_FILE="$VCPKG_TOOLCHAIN" \
  -DVCPKG_TARGET_TRIPLET="$BASE_TRIPLET" \
  -DCMAKE_OSX_ARCHITECTURES="$OSX_ARCH" \
  -DCMAKE_INSTALL_PREFIX="$WORK/install" \
  -DCMAKE_INSTALL_RPATH='$ORIGIN' \
  -DSW_BUILD=OFF
cmake --build "$WORK/leptonica/build" --config Release -j"$(nproc 2>/dev/null || sysctl -n hw.ncpu)"
cmake --install "$WORK/leptonica/build"

git clone --depth 1 --branch "$TESSERACT_VERSION" https://github.com/tesseract-ocr/tesseract "$WORK/tesseract"
cmake -S "$WORK/tesseract" -B "$WORK/tesseract/build" \
  -DCMAKE_BUILD_TYPE=Release \
  -DBUILD_SHARED_LIBS=ON \
  -DBUILD_TRAINING_TOOLS=OFF \
  -DDISABLE_CURL=ON \
  -DDISABLE_ARCHIVE=ON \
  -DGRAPHICS_DISABLED=ON \
  -DCMAKE_TOOLCHAIN_FILE="$VCPKG_TOOLCHAIN" \
  -DVCPKG_TARGET_TRIPLET="$BASE_TRIPLET" \
  -DCMAKE_PREFIX_PATH="$WORK/install" \
  -DLeptonica_DIR="$WORK/install/lib/cmake/leptonica" \
  -DCMAKE_OSX_ARCHITECTURES="$OSX_ARCH" \
  -DCMAKE_INSTALL_PREFIX="$WORK/install" \
  -DCMAKE_INSTALL_RPATH='$ORIGIN' \
  -DSW_BUILD=OFF
cmake --build "$WORK/tesseract/build" --config Release -j"$(nproc 2>/dev/null || sysctl -n hw.ncpu)"
cmake --install "$WORK/tesseract/build"

case "$RID" in
  linux-x64)
    cp -P "$WORK"/install/lib/libtesseract*.so* "$STAGE/"
    cp -P "$WORK"/install/lib/libleptonica*.so* "$STAGE/"
    ;;
  osx-x64|osx-arm64)
    cp -P "$WORK"/install/lib/libtesseract*.dylib "$STAGE/"
    cp -P "$WORK"/install/lib/libleptonica*.dylib "$STAGE/"
    ;;
esac

cp "$WORK/leptonica/leptonica-license.txt" "$ROOT/stage/$RID/leptonica-LICENSE.txt" 2>/dev/null || true
cp "$WORK/tesseract/LICENSE" "$ROOT/stage/$RID/tesseract-LICENSE.txt" 2>/dev/null || true

echo "== Staged $RID =="
ls -la "$STAGE"

# NOTE: charlesw/tesseract's interop layer resolves the library by a base
# name (see TesseractEnviornment / InteropDotNet in the consuming project).
# If the consumer expects an exact filename (e.g. "libtesseract.so" rather
# than a versioned "libtesseract.5.5.0.so"), add a symlink/copy step here
# to match it -- confirm against the exact DllImport name in use before
# first release.
