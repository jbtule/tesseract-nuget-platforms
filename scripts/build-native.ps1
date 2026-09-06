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

switch ($Rid) {
    # CMAKE_SYSTEM_PROCESSOR is passed explicitly to Tesseract's configure
    # below: we're not doing a "real" CMake cross-compile (just pointing
    # cl.exe at the ARM64 toolset via vcvars on an x64 host), so CMake would
    # otherwise still report the host's AMD64, and Tesseract's CMakeLists
    # branches its SIMD codepath on this value -- it'd wrongly enable x86
    # AVX/SSE intrinsics for the ARM64 target, which don't exist there and
    # fail to compile (__cpuid/_xgetbv "identifier not found").
    "win-x64"   { $Triplet = "x64-windows";   $SystemProcessor = "AMD64" }
    "win-arm64" { $Triplet = "arm64-windows"; $SystemProcessor = "arm64" }
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
  -DCMAKE_SYSTEM_PROCESSOR="$SystemProcessor" `
  -DSW_BUILD=OFF
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
