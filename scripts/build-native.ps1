# Builds Leptonica + Tesseract from source for win-x64 and stages the
# resulting DLLs under stage/win-x64/native.
#
# Usage: pwsh scripts/build-native.ps1
#
# See build-native.sh for the rationale (vcpkg for static codec deps,
# source builds for leptonica/tesseract themselves).
$ErrorActionPreference = "Stop"

$Root = Resolve-Path "$PSScriptRoot/.."
Get-Content "$Root/versions.env" | ForEach-Object {
    if ($_ -match '^\s*#' -or $_ -match '^\s*$') { return }
    $name, $value = $_ -split '=', 2
    Set-Variable -Name $name -Value $value
}

$Work = Join-Path ([System.IO.Path]::GetTempPath()) ([System.IO.Path]::GetRandomFileName())
New-Item -ItemType Directory -Path $Work | Out-Null
$Stage = "$Root/stage/win-x64/native"
New-Item -ItemType Directory -Path $Stage -Force | Out-Null

$Triplet = "x64-windows"

git clone --depth 1 https://github.com/microsoft/vcpkg "$Work/vcpkg"
& "$Work/vcpkg/bootstrap-vcpkg.bat" -disableMetrics
& "$Work/vcpkg/vcpkg.exe" install zlib libpng libjpeg-turbo tiff libwebp --triplet $Triplet --clean-after-build

$VcpkgToolchain = "$Work/vcpkg/scripts/buildsystems/vcpkg.cmake"

git clone --depth 1 --branch $LEPTONICA_VERSION https://github.com/DanBloomberg/leptonica "$Work/leptonica"
cmake -S "$Work/leptonica" -B "$Work/leptonica/build" -G "Visual Studio 17 2022" -A x64 `
  -DBUILD_SHARED_LIBS=ON `
  -DCMAKE_TOOLCHAIN_FILE="$VcpkgToolchain" `
  -DVCPKG_TARGET_TRIPLET=$Triplet `
  -DCMAKE_INSTALL_PREFIX="$Work/install" `
  -DSW_BUILD=OFF
cmake --build "$Work/leptonica/build" --config Release --parallel
cmake --install "$Work/leptonica/build" --config Release

git clone --depth 1 --branch $TESSERACT_VERSION https://github.com/tesseract-ocr/tesseract "$Work/tesseract"
cmake -S "$Work/tesseract" -B "$Work/tesseract/build" -G "Visual Studio 17 2022" -A x64 `
  -DBUILD_SHARED_LIBS=ON `
  -DBUILD_TRAINING_TOOLS=OFF `
  -DDISABLE_CURL=ON `
  -DDISABLE_ARCHIVE=ON `
  -DGRAPHICS_DISABLED=ON `
  -DCMAKE_TOOLCHAIN_FILE="$VcpkgToolchain" `
  -DVCPKG_TARGET_TRIPLET=$Triplet `
  -DCMAKE_PREFIX_PATH="$Work/install" `
  -DLeptonica_DIR="$Work/install/lib/cmake/leptonica" `
  -DCMAKE_INSTALL_PREFIX="$Work/install"
cmake --build "$Work/tesseract/build" --config Release --parallel
cmake --install "$Work/tesseract/build" --config Release

Copy-Item "$Work/install/bin/tesseract*.dll" $Stage
Copy-Item "$Work/install/bin/leptonica*.dll" $Stage

Copy-Item "$Work/leptonica/leptonica-license.txt" "$Root/stage/win-x64/leptonica-LICENSE.txt" -ErrorAction SilentlyContinue
Copy-Item "$Work/tesseract/LICENSE" "$Root/stage/win-x64/tesseract-LICENSE.txt" -ErrorAction SilentlyContinue

Write-Host "== Staged win-x64 =="
Get-ChildItem $Stage

# NOTE: confirm the exact DllImport base name charlesw/tesseract's interop
# layer expects (e.g. "libtesseract" vs "tesseract5") before first release
# and rename/copy the DLL here to match if needed.
