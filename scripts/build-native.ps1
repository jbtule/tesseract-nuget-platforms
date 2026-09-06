# Builds Leptonica + Tesseract from source for one Windows RID and stages
# the resulting DLLs under stage/<rid>/native.
#
# Usage: pwsh scripts/build-native.ps1 <win-x64|win-arm64>
#
# Must be run with cl.exe/link.exe already on PATH for the *target*
# architecture (see ilammy/msvc-dev-cmd in build-native.yml) -- win-arm64 is
# a cross-compile from the x64 runner host using MSVC's ARM64 toolset.
#
# See build-native.sh for the rationale (vcpkg for static codec deps,
# source builds for leptonica/tesseract themselves).
$ErrorActionPreference = "Stop"

$Rid = $args[0]
if (-not $Rid) {
    Write-Error "usage: build-native.ps1 <win-x64|win-arm64>"
    exit 1
}

# For win-arm64, CMAKE_SYSTEM_NAME/_PROCESSOR are passed explicitly to
# Tesseract's configure below: we're not doing a "real" CMake cross-compile
# (just pointing cl.exe at the ARM64 toolset via vcvars on an x64 host), so
# by default CMake still reports the host's AMD64 -- and Tesseract's own
# CMakeLists branches its SIMD codepath on that value, wrongly enabling x86
# AVX/SSE intrinsics for the ARM64 target, which don't exist there and fail
# to compile (__cpuid/_xgetbv "identifier not found"). Setting
# CMAKE_SYSTEM_PROCESSOR alone doesn't stick -- CMake only honors it once
# CMAKE_CROSSCOMPILING is true, which itself is only triggered by also
# setting CMAKE_SYSTEM_NAME explicitly (even to the same OS name).
$CrossCompileArgs = @()
switch ($Rid) {
    "win-x64"   { $Triplet = "x64-windows" }
    "win-arm64" {
        $Triplet = "arm64-windows"
        # CMAKE_SYSTEM_PROCESSOR must be lowercase "arm64" to match the
        # (case-sensitive) regex Tesseract's CMakeLists branches its SIMD
        # selection on -- "ARM64" matches neither its "arm64" nor its
        # "AARCH64.*" alternative, so NEON wouldn't get enabled even though
        # the (also gated on this same regex) x86 AVX/SSE codepath would
        # correctly stay disabled either way.
        #
        # LEPT_TIFF_RESULT is pre-seeded because CMake can't try_run() an
        # ARM64 test binary on this x64 host to check Leptonica's TIFF
        # support; 0 (success) reflects that our Leptonica build does have
        # real TIFF support, from vcpkg's tiff port.
        # HAVE_NEON is set to TRUE by CMakeLists' arm64 branch, but never
        # actually passed to the compiler via add_definitions (unlike every
        # x86 SIMD flag, which does get one) -- and dotproductneon.cpp /
        # intsimdmatrixneon.cpp / simddetect.cpp all guard their NEON code
        # on "#if defined(HAVE_NEON) || defined(__aarch64__)". __aarch64__
        # is a GCC/Clang macro that MSVC's ARM64 target never defines (MSVC
        # uses _M_ARM64 instead), so without this they silently compile to
        # empty translation units and every NEON symbol goes unresolved at
        # link time. Looks like a genuine gap in upstream Tesseract's
        # MSVC+ARM64 CMake support; defining the macro ourselves works
        # around it without patching source.
        $CrossCompileArgs = @(
            "-DCMAKE_SYSTEM_NAME=Windows",
            "-DCMAKE_SYSTEM_PROCESSOR=arm64",
            "-DLEPT_TIFF_RESULT=0",
            "-DCMAKE_CXX_FLAGS=/DHAVE_NEON"
        )
    }
    default { Write-Error "unknown RID: $Rid"; exit 1 }
}

$Root = Resolve-Path "$PSScriptRoot/.."
Get-Content "$Root/versions.env" | ForEach-Object {
    if ($_ -match '^\s*#' -or $_ -match '^\s*$') { return }
    $name, $value = $_ -split '=', 2
    Set-Variable -Name $name -Value $value
}

$Work = Join-Path ([System.IO.Path]::GetTempPath()) ([System.IO.Path]::GetRandomFileName())
New-Item -ItemType Directory -Path $Work | Out-Null
$Stage = "$Root/stage/$Rid/native"
New-Item -ItemType Directory -Path $Stage -Force | Out-Null

git clone --depth 1 https://github.com/microsoft/vcpkg "$Work/vcpkg"
& "$Work/vcpkg/bootstrap-vcpkg.bat" -disableMetrics
& "$Work/vcpkg/vcpkg.exe" install zlib libpng libjpeg-turbo tiff libwebp --triplet $Triplet --clean-after-build

$VcpkgToolchain = "$Work/vcpkg/scripts/buildsystems/vcpkg.cmake"

# Ninja rather than the "Visual Studio 17 2022" CMake generator: the VS
# generator relies on CMake locating a registered VS *instance*, which has
# proven flaky on hosted runner images even when cl.exe/MSBuild are present
# and working (as evidenced by vcpkg building fine just above). Ninja just
# needs cl.exe on PATH, which the caller sets up via ilammy/msvc-dev-cmd
# before invoking this script (and is also what makes the win-arm64
# cross-compile straightforward -- it's just "whichever cl.exe is on PATH").
git clone --depth 1 --branch $LEPTONICA_VERSION https://github.com/DanBloomberg/leptonica "$Work/leptonica"
cmake -S "$Work/leptonica" -B "$Work/leptonica/build" -G Ninja `
  -DCMAKE_BUILD_TYPE=Release `
  -DBUILD_SHARED_LIBS=ON `
  -DCMAKE_TOOLCHAIN_FILE="$VcpkgToolchain" `
  -DVCPKG_TARGET_TRIPLET=$Triplet `
  -DCMAKE_INSTALL_PREFIX="$Work/install" `
  -DSW_BUILD=OFF
cmake --build "$Work/leptonica/build" --parallel
cmake --install "$Work/leptonica/build"

git clone --depth 1 --branch $TESSERACT_VERSION https://github.com/tesseract-ocr/tesseract "$Work/tesseract"
cmake -S "$Work/tesseract" -B "$Work/tesseract/build" -G Ninja `
  -DCMAKE_BUILD_TYPE=Release `
  -DBUILD_SHARED_LIBS=ON `
  -DBUILD_TRAINING_TOOLS=OFF `
  -DDISABLE_CURL=ON `
  -DDISABLE_ARCHIVE=ON `
  -DGRAPHICS_DISABLED=ON `
  -DCMAKE_TOOLCHAIN_FILE="$VcpkgToolchain" `
  -DVCPKG_TARGET_TRIPLET=$Triplet `
  -DCMAKE_PREFIX_PATH="$Work/install" `
  -DLeptonica_DIR="$Work/install/lib/cmake/leptonica" `
  -DCMAKE_INSTALL_PREFIX="$Work/install" `
  -DSW_BUILD=OFF `
  @CrossCompileArgs
cmake --build "$Work/tesseract/build" --parallel
cmake --install "$Work/tesseract/build"

# Copy-Item on a non-matching wildcard neither copies anything nor errors,
# so check explicitly rather than silently shipping an empty/partial package.
function Copy-RequiredDlls([string]$Pattern, [string]$Label) {
    $files = Get-ChildItem "$Work/install/bin/$Pattern" -ErrorAction SilentlyContinue
    if (-not $files) {
        Write-Error "No $Label DLLs matched '$Pattern' under $Work/install/bin -- build/install must have failed silently."
        exit 1
    }
    Copy-Item $files.FullName $Stage
}
Copy-RequiredDlls "tesseract*.dll" "tesseract"
Copy-RequiredDlls "leptonica*.dll" "leptonica"

Copy-Item "$Work/leptonica/leptonica-license.txt" "$Root/stage/$Rid/leptonica-LICENSE.txt" -ErrorAction SilentlyContinue
Copy-Item "$Work/tesseract/LICENSE" "$Root/stage/$Rid/tesseract-LICENSE.txt" -ErrorAction SilentlyContinue

Write-Host "== Staged $Rid =="
Get-ChildItem $Stage

# NOTE: confirm the exact DllImport base name charlesw/tesseract's interop
# layer expects (e.g. "libtesseract" vs "tesseract5") before first release
# and rename/copy the DLL here to match if needed.
