# Builds Leptonica + Tesseract via vcpkg's own ports for one Windows RID
# and stages the resulting DLLs under stage/<rid>/native.
#
# Usage: pwsh scripts/build-native.ps1 <win-x64|win-arm64>
#
# See build-native.sh for the rationale (consuming vcpkg's tesseract/
# leptonica ports rather than building from upstream source ourselves --
# vcpkg's maintainers already carry the ARM64/MSVC CMake patches this
# needs). vcpkg handles win-arm64 as a cross-compile from the x64 runner
# host internally; no manual toolchain setup (e.g. vcvars) is needed here,
# unlike the raw-CMake approach this replaced.
$ErrorActionPreference = "Stop"

$Rid = $args[0]
if (-not $Rid) {
    Write-Error "usage: build-native.ps1 <win-x64|win-arm64>"
    exit 1
}

switch ($Rid) {
    "win-x64"   { $Triplet = "x64-windows" }
    "win-arm64" { $Triplet = "arm64-windows" }
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

git clone --branch $VCPKG_REF --depth 1 https://github.com/microsoft/vcpkg "$Work/vcpkg"
& "$Work/vcpkg/bootstrap-vcpkg.bat" -disableMetrics
& "$Work/vcpkg/vcpkg.exe" install tesseract leptonica --triplet $Triplet --clean-after-build

$Installed = "$Work/vcpkg/installed/$Triplet"

# Copy every DLL vcpkg installed, not just tesseract*/leptonica*: with a
# dynamic triplet, Leptonica's own codec dependencies (giflib, libjpeg-turbo,
# openjpeg, libpng, zlib, tiff, libwebp) and Tesseract's own mandatory
# curl/libarchive dependencies (each with further transitive deps of their
# own) all become separate DLLs that have to be present at runtime too --
# confirmed missing ones (started with libgif on macOS) cause a silent
# dlopen/LoadLibrary failure, not a clear error, since InteropDotNet's
# loader logic swallows the underlying exception.
Copy-Item "$Installed/bin/*.dll" $Stage

# Get-ChildItem on a non-matching wildcard returns nothing without erroring,
# so check explicitly rather than silently shipping an empty/partial package
# (this bit us for real once already, back when this script used raw CMake).
function Assert-Copied([string]$Pattern, [string]$Label) {
    $files = Get-ChildItem "$Stage/$Pattern" -ErrorAction SilentlyContinue
    if (-not $files) {
        Write-Error "No $Label DLLs matched '$Pattern' in $Stage after copying $Installed/bin -- vcpkg install must have failed silently."
        exit 1
    }
}
Assert-Copied "tesseract*.dll" "tesseract"
Assert-Copied "leptonica*.dll" "leptonica"

# Unlike Linux/macOS -- where vcpkg's shared-library builds come with
# unversioned SONAME-style symlinks (libtesseract.so -> .so.5 -> .so.5.5.2,
# libtesseract.dylib likewise) -- vcpkg's Windows build only produces the
# exact versioned filename (tesseract55.dll, leptonica-1.87.0.dll), no
# generic alias. The patched wrapper's Constants.cs asks for generic
# "tesseract"/"leptonica" (FixUpLibraryName appends ".dll"), which
# resolves fine via those Unix symlinks but has nothing to match on
# Windows without this: confirmed via a real "Failed to find library
# leptonica.dll" failure. Copy each to the generic name it'll actually be
# looked up by, alongside the original versioned file.
function Copy-GenericAlias([string]$Pattern, [string]$GenericName) {
    $file = Get-ChildItem "$Stage/$Pattern" | Select-Object -First 1
    Copy-Item $file.FullName "$Stage/$GenericName.dll"
}
Copy-GenericAlias "tesseract*.dll" "tesseract"
Copy-GenericAlias "leptonica*.dll" "leptonica"

# Best-effort: grab every dependency's license text too, not just
# tesseract/leptonica's own -- there are a lot more of them now.
$LicenseDir = "$Root/stage/$Rid/licenses"
New-Item -ItemType Directory -Path $LicenseDir -Force | Out-Null
Get-ChildItem "$Installed/share/*/copyright" -ErrorAction SilentlyContinue | ForEach-Object {
    $pkg = Split-Path (Split-Path $_.FullName -Parent) -Leaf
    Copy-Item $_.FullName "$LicenseDir/$pkg.txt"
}

Write-Host "== Staged $Rid (tesseract/leptonica versions from vcpkg $VCPKG_REF) =="
Get-ChildItem $Stage
