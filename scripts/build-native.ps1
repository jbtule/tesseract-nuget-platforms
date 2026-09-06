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

# Get-ChildItem on a non-matching wildcard returns nothing without erroring,
# so check explicitly rather than silently shipping an empty/partial package
# (this bit us for real once already, back when this script used raw CMake).
function Copy-RequiredDlls([string]$Pattern, [string]$Label) {
    $files = Get-ChildItem "$Installed/bin/$Pattern" -ErrorAction SilentlyContinue
    if (-not $files) {
        Write-Error "No $Label DLLs matched '$Pattern' under $Installed/bin -- vcpkg install must have failed silently."
        exit 1
    }
    Copy-Item $files.FullName $Stage
}
Copy-RequiredDlls "tesseract*.dll" "tesseract"
Copy-RequiredDlls "leptonica*.dll" "leptonica"

Copy-Item "$Installed/share/tesseract/copyright" "$Root/stage/$Rid/tesseract-LICENSE.txt" -ErrorAction SilentlyContinue
Copy-Item "$Installed/share/leptonica/copyright" "$Root/stage/$Rid/leptonica-LICENSE.txt" -ErrorAction SilentlyContinue

Write-Host "== Staged $Rid (tesseract/leptonica versions from vcpkg $VCPKG_REF) =="
Get-ChildItem $Stage

# NOTE: confirm the exact DllImport base name charlesw/tesseract's interop
# layer expects (e.g. "libtesseract" vs "tesseract5") before first release
# and rename/copy the DLL here to match if needed.
