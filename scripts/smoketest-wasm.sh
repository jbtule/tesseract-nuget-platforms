#!/usr/bin/env bash
# Packs Tesseract.CrossPlatform + Tesseract.Native.browser-wasm +
# Tesseract.CrossPlatform.SkiaSharp (both built fresh from what this job
# just produced under stage/browser-wasm and vendor/tesseract) plus a
# zero-dependency stub Tesseract.Native into a local feed, publishes
# smoketest-wasm/ for browser-wasm, and drives it headlessly via Playwright
# -- proving the actual packaged output does real OCR in a real browser, not
# just that the native build/publish succeeded. Mirrors scripts/smoketest.sh's
# own rationale for the other 5 RIDs.
#
# Usage: scripts/smoketest-wasm.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/versions.env"

# See smoketest.sh's own comment: keeps a rerun against an unchanged
# PACKAGE_VERSION honest instead of silently restoring a stale cached copy.
WORK="$(mktemp -d)"
FEED="$WORK/feed"
mkdir -p "$FEED"
export NUGET_PACKAGES="$WORK/packages"
REPO_URL="https://github.com/${GITHUB_REPOSITORY:-jbtule/tesseract-nuget-platforms}"

gen_file_entries() {
  local dir="$1" target="$2" f
  for f in "$dir"/*; do
    [ -f "$f" ] || continue
    printf '    <file src="%s" target="%s" />\n' "$f" "$target"
  done
}

echo "== Packing Tesseract.Native.browser-wasm =="
gen_file_entries "$ROOT/stage/browser-wasm/native" "build/native" > "$WORK/native-files.xml"
gen_file_entries "$ROOT/stage/browser-wasm/licenses" "licenses" > "$WORK/license-files.xml"
sed \
  -e "s|[$]version[$]|$PACKAGE_VERSION|g" \
  -e "s|[$]repoUrl[$]|$REPO_URL|g" \
  -e "/NATIVE_FILES_PLACEHOLDER/r $WORK/native-files.xml" \
  -e "/NATIVE_FILES_PLACEHOLDER/d" \
  -e "/LICENSE_FILES_PLACEHOLDER/r $WORK/license-files.xml" \
  -e "/LICENSE_FILES_PLACEHOLDER/d" \
  "$ROOT/nuget/wasm/Tesseract.Native.browser-wasm.nuspec" > "$WORK/browser-wasm.nuspec"
dotnet pack "$ROOT/nuget/wasm/WasmNativePackage.csproj" -c Release -o "$FEED" \
  -p:NuspecFile="$WORK/browser-wasm.nuspec" -p:NuspecBasePath="$ROOT"

echo "== Building + packing wrapper (vendor/tesseract) =="
# AssemblyName=Tesseract.CrossPlatform -- see smoketest.sh's own comment for
# why (avoids a case-insensitive-filesystem filename collision on Windows).
# Not actually a Windows concern for a wasm-only run, but keeps this script
# consistent with the real release path instead of quietly diverging.
dotnet build "$ROOT/vendor/tesseract/src/Tesseract/Tesseract.csproj" -c Release \
  -p:GeneratePackageOnBuild=false -p:AssemblyName=Tesseract.CrossPlatform
sed \
  -e "s|[$]version[$]|$PACKAGE_VERSION|g" \
  -e "s|[$]repoUrl[$]|$REPO_URL|g" \
  -e "s|[$]wrapperBuild[$]|$ROOT/vendor/tesseract/src/Tesseract/bin/Release|g" \
  "$ROOT/nuget/wrapper/Tesseract.CrossPlatform.nuspec" > "$WORK/wrapper.nuspec"
dotnet pack "$ROOT/nuget/wrapper/Tesseract.CrossPlatform.csproj" -c Release -o "$FEED" \
  -p:NuspecFile="$WORK/wrapper.nuspec" -p:NuspecBasePath="$ROOT"

echo "== Packing Tesseract.CrossPlatform.SkiaSharp =="
# Explicit `build` then `pack --no-build`, not a plain `dotnet pack`: a real
# CI failure (NU5026, output dll not found on disk for net10.0 specifically),
# reproduced locally too -- `dotnet pack` run right after this script's own
# separate build of the ProjectReference'd Tesseract.csproj (the "Building +
# packing wrapper" step above) incorrectly treats this project as already up
# to date and skips building it. See pack.yml's matching step for the fuller
# writeup.
dotnet build "$ROOT/vendor/tesseract/src/Tesseract.CrossPlatform.SkiaSharp/Tesseract.CrossPlatform.SkiaSharp.csproj" \
  -c Release -p:Version="$PACKAGE_VERSION"
dotnet pack "$ROOT/vendor/tesseract/src/Tesseract.CrossPlatform.SkiaSharp/Tesseract.CrossPlatform.SkiaSharp.csproj" \
  -c Release -o "$FEED" -p:Version="$PACKAGE_VERSION" --no-build

echo "== Packing stub Tesseract.Native (satisfies Tesseract.CrossPlatform's normal dependency) =="
sed -e "s|[$]version[$]|$PACKAGE_VERSION|g" \
  "$ROOT/smoketest/stub/Tesseract.Native.nuspec" > "$WORK/stub.nuspec"
dotnet pack "$ROOT/smoketest/stub/Stub.csproj" -c Release -o "$FEED" \
  -p:NuspecFile="$WORK/stub.nuspec" -p:NuspecBasePath="$ROOT/smoketest/stub"

cat > "$ROOT/smoketest-wasm/nuget.config" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<configuration>
  <packageSources>
    <clear />
    <add key="local" value="$FEED" />
    <add key="nuget.org" value="https://api.nuget.org/v3/index.json" />
  </packageSources>
</configuration>
EOF

echo "== Staging wwwroot fixtures =="
cp "$ROOT/smoketest/test.png" "$ROOT/smoketest-wasm/wwwroot/test.png"
mkdir -p "$ROOT/smoketest-wasm/wwwroot/tessdata"
curl -sL -o "$ROOT/smoketest-wasm/wwwroot/tessdata/eng.traineddata" \
  "https://github.com/tesseract-ocr/tessdata_fast/raw/main/eng.traineddata"

echo "== Publishing smoketest-wasm for browser-wasm =="
dotnet publish "$ROOT/smoketest-wasm/SmokeTestWasm.csproj" -c Release \
  -p:PackageVersion="$PACKAGE_VERSION"

PUBLISH_WWWROOT="$ROOT/smoketest-wasm/bin/Release/net10.0/publish/wwwroot"
echo "== Published output ($PUBLISH_WWWROOT) =="
ls -la "$PUBLISH_WWWROOT"

echo "== Running headless (Playwright) =="
cd "$ROOT/smoketest-wasm"
npm ci
npx playwright install --with-deps chromium
node run-smoketest.mjs "$PUBLISH_WWWROOT"
