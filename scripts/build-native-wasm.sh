#!/usr/bin/env bash
# Builds Leptonica + Tesseract from upstream source for the browser-wasm RID via
# Emscripten, and stages the resulting static libraries under
# stage/browser-wasm/native.
#
# Usage: scripts/build-native-wasm.sh
#
# Unlike scripts/build-native.sh (which consumes vcpkg's tesseract/leptonica
# ports), vcpkg's tesseract port explicitly excludes Emscripten
# ("supports": "!emscripten") -- confirmed in the WASM backlog plan's Phase 0,
# not assumed -- so this builds directly against upstream source via emcmake/
# emmake instead. Uses the Emscripten toolchain the installed wasm-tools SDK
# workload already carries (no separate emsdk install): emcc, emcmake, emmake,
# node, clang, wasm-ld, wasm-opt, all under
# Microsoft.NET.Runtime.Emscripten.<EMSDK_REF>.*.<host-rid> packs. Requires
# that workload installed (`dotnet workload install wasm-tools`).
#
# Produces static libs (.a), not the dynamic libs build-native.sh produces:
# browser-wasm has no dlopen-style runtime loader -- a consumer statically
# links these in at their own `dotnet publish -r browser-wasm` time via
# <NativeFileReference>, which is what Tesseract.Native.browser-wasm's
# buildTransitive targets inject (see nuget/wasm/).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/versions.env"

HOST_RID="$(dotnet --info | awk -F': *' '/^ *RID:/ {print $2; exit}')"
if [ -z "$HOST_RID" ]; then
  echo "Could not determine host RID from 'dotnet --info'." >&2
  exit 1
fi

# Derived from `dotnet --info`'s own "Base Path" (<dotnet-root>/sdk/<ver>/),
# not from resolving `command -v dotnet`: on this dev machine dotnet is a
# Homebrew-installed symlink whose target's directory isn't the real SDK
# root, so that approach found no packs/ at all.
DOTNET_BASE_PATH="$(dotnet --info | awk -F': *' '/^ *Base Path:/ {print $2; exit}')"
PACKS_DIR="$(dirname "$(dirname "${DOTNET_BASE_PATH%/}")")/packs"
if [ ! -d "$PACKS_DIR" ]; then
  echo "Could not find a packs/ directory next to the .NET SDK root ($DOTNET_BASE_PATH)." >&2
  exit 1
fi

SDK_PACK="$(find "$PACKS_DIR" -maxdepth 1 -type d -name "Microsoft.NET.Runtime.Emscripten.${EMSDK_REF}.Sdk.${HOST_RID}" | head -1)"
NODE_PACK="$(find "$PACKS_DIR" -maxdepth 1 -type d -name "Microsoft.NET.Runtime.Emscripten.${EMSDK_REF}.Node.${HOST_RID}" | head -1)"
CACHE_PACK="$(find "$PACKS_DIR" -maxdepth 1 -type d -name "Microsoft.NET.Runtime.Emscripten.${EMSDK_REF}.Cache.${HOST_RID}" | head -1)"
if [ -z "$SDK_PACK" ] || [ -z "$NODE_PACK" ] || [ -z "$CACHE_PACK" ]; then
  echo "Could not find Emscripten $EMSDK_REF packs for $HOST_RID under $PACKS_DIR." >&2
  echo "Install the wasm-tools workload for a net10.0-targeting SDK: dotnet workload install wasm-tools" >&2
  exit 1
fi
# Each pack directory has exactly one version-numbered subdirectory (e.g.
# 10.0.11) -- the SDK's own patch version, not EMSDK_REF (which pins the
# Emscripten toolchain version inside it).
SDK_PACK="$(find "$SDK_PACK" -mindepth 1 -maxdepth 1 -type d | head -1)"
NODE_PACK="$(find "$NODE_PACK" -mindepth 1 -maxdepth 1 -type d | head -1)"
CACHE_PACK="$(find "$CACHE_PACK" -mindepth 1 -maxdepth 1 -type d | head -1)"

EMSCRIPTEN_ROOT="$SDK_PACK/tools/emscripten"
NODE_BIN="$NODE_PACK/tools/bin/node"
TOOLCHAIN_FILE="$EMSCRIPTEN_ROOT/cmake/Modules/Platform/Emscripten.cmake"

WORK="$(mktemp -d)"
STAGE="$ROOT/stage/browser-wasm/native"
mkdir -p "$STAGE"

# The packs' own prebuilt sysroot cache is read-only; embuilder/first-use
# sysroot generation during configure needs to write into it, so work off a
# writable copy rather than the pack's own directory.
EM_CACHE="$WORK/em_cache"
cp -R "$CACHE_PACK/tools/emscripten/cache" "$EM_CACHE"

# FROZEN_CACHE must be empty, not "0": Python's bool(os.getenv(...)) treats
# any non-empty string (including "0") as truthy.
export EM_CONFIG="$WORK/emconfig.py"
export FROZEN_CACHE=
cat > "$EM_CONFIG" <<EOF
LLVM_ROOT = "$SDK_PACK/tools/bin"
BINARYEN_ROOT = "$SDK_PACK/tools"
NODE_JS = "$NODE_BIN"
EMSCRIPTEN_ROOT = "$EMSCRIPTEN_ROOT"
CACHE = "$EM_CACHE"
FROZEN_CACHE = False
EOF

PATH="$EMSCRIPTEN_ROOT:$PATH"
export PATH

echo "== Cloning leptonica $LEPTONICA_WASM_REF =="
git clone --branch "$LEPTONICA_WASM_REF" --depth 1 https://github.com/DanBloomberg/leptonica.git "$WORK/src-leptonica"

echo "== Cloning tesseract $TESSERACT_WASM_REF =="
git clone --branch "$TESSERACT_WASM_REF" --depth 1 https://github.com/tesseract-ocr/tesseract.git "$WORK/src-tesseract"

# Everything statically linked into the app -- our own libs included -- must
# match .NET's wasm runtime's exception-handling model
# (-fwasm-exceptions -sSUPPORT_LONGJMP=wasm), confirmed the hard way in Phase 1:
# Emscripten's *default* flags link fine in isolation but fail at the .NET
# SDK's own final link step ("invoke_ functions exported but exceptions and
# longjmp are both disabled").
WASM_EH_FLAGS="-fwasm-exceptions -sSUPPORT_LONGJMP=wasm"

echo "== Configuring leptonica =="
mkdir -p "$WORK/build-leptonica"
(cd "$WORK/build-leptonica" && emcmake cmake ../src-leptonica \
  -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DBUILD_SHARED_LIBS=OFF \
  -DLIBWEBP_SUPPORT=OFF \
  -DOPENJPEG_SUPPORT=OFF \
  -DCMAKE_INSTALL_PREFIX="$WORK/install-leptonica" \
  -DCMAKE_C_FLAGS="$WASM_EH_FLAGS" \
  -DCMAKE_EXE_LINKER_FLAGS="$WASM_EH_FLAGS" \
  -DCMAKE_TOOLCHAIN_FILE="$TOOLCHAIN_FILE" \
  -DCMAKE_CROSSCOMPILING_EMULATOR="$NODE_BIN")

echo "== Building + installing leptonica =="
ninja -C "$WORK/build-leptonica" install

# Not just -DBUILD_TESSERACT_BINARY=OFF: tesseract's CMakeLists silently
# ignores that flag entirely (a real "Manually-specified variables were not
# used" CMake warning) -- building the specific `libtesseract` target instead
# sidesteps the CLI binary's own separate (and broken, for this build) link
# step. -DDISABLED_LEGACY_ENGINE stays OFF: turning it ON fails to *compile*
# osdetect.cpp in tesseract 5.5.2 (TBLOB incomplete, AdaptiveClassifier/
# get_fontinfo_table missing) -- osdetect.cpp isn't guarded for that flag in
# this version. HAVE_AVX/AVX2/AVX512F/FMA/SSE4_1 all forced FALSE: Emscripten's
# CMake toolchain reports CMAKE_SYSTEM_PROCESSOR=x86, so check_cxx_compiler_flag
# false-positives on -mavx (clang accepts it for wasm32 without erroring but
# provides no real AVX intrinsics), and -DHAVE_SSE4_1=ON alone drags in real
# x86 inline-asm CPUID detection with no __EMSCRIPTEN__ guard in current
# tesseract's simddetect.cpp. Matches tesseract-wasm's own build flags for
# this same reason. A real, separate follow-up: this is a non-SIMD build --
# tesseract-wasm also passes -msimd128 -DHAVE_SSE4_1=ON against an *older*
# pinned tesseract (5.3.0) whose simddetect.cpp predates the unguarded CPUID
# code, which isn't safely available to a current-tesseract build like this
# one without upstreaming a fix first.
echo "== Configuring tesseract =="
mkdir -p "$WORK/build-tesseract"
(cd "$WORK/build-tesseract" && emcmake cmake ../src-tesseract \
  -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DBUILD_SHARED_LIBS=OFF \
  -DBUILD_TRAINING_TOOLS=OFF \
  -DDISABLE_CURL=ON \
  -DDISABLED_LEGACY_ENGINE=OFF \
  -DGRAPHICS_DISABLED=ON \
  -DOPENMP_BUILD=OFF \
  -DCMAKE_INSTALL_PREFIX="$WORK/install-tesseract" \
  -DCMAKE_PREFIX_PATH="$WORK/install-leptonica" \
  -DLeptonica_DIR="$WORK/install-leptonica/lib/cmake/leptonica" \
  -DHAVE_AVX=FALSE -DHAVE_AVX2=FALSE -DHAVE_AVX512F=FALSE -DHAVE_FMA=FALSE -DHAVE_SSE4_1=FALSE \
  -DCMAKE_C_FLAGS="$WASM_EH_FLAGS" \
  -DCMAKE_CXX_FLAGS="$WASM_EH_FLAGS" \
  -DCMAKE_EXE_LINKER_FLAGS="$WASM_EH_FLAGS" \
  -DCMAKE_TOOLCHAIN_FILE="$TOOLCHAIN_FILE" \
  -DCMAKE_CROSSCOMPILING_EMULATOR="$NODE_BIN")

echo "== Building tesseract (libtesseract target only) =="
ninja -C "$WORK/build-tesseract" libtesseract

# The shipped filename *is* the DllImport library name under wasm (confirmed
# in Phase 0/1: a "libtesseract.a" name registers the linked-in module as
# "libtesseract", not "tesseract", and Tesseract.CrossPlatform's
# Constants.TesseractDllName/LeptonicaDllName are "tesseract"/"leptonica" with
# no "lib" prefix) -- rename on stage, not just copy.
cp "$WORK/install-leptonica/lib/libleptonica.a" "$STAGE/leptonica.a"
cp "$WORK/build-tesseract/libtesseract.a" "$STAGE/tesseract.a"

mkdir -p "$ROOT/stage/browser-wasm/licenses"
[ -f "$WORK/src-leptonica/leptonica-license.txt" ] && cp "$WORK/src-leptonica/leptonica-license.txt" "$ROOT/stage/browser-wasm/licenses/leptonica.txt"
[ -f "$WORK/src-tesseract/LICENSE" ] && cp "$WORK/src-tesseract/LICENSE" "$ROOT/stage/browser-wasm/licenses/tesseract.txt"

echo "== Staged browser-wasm (leptonica $LEPTONICA_WASM_REF, tesseract $TESSERACT_WASM_REF, emscripten $EMSDK_REF) =="
ls -la "$STAGE"
