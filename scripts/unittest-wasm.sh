#!/usr/bin/env bash
# Runs the real Tesseract.Tests suite (plus Tesseract.Tests.SkiaSharp's converter tests)
# under browser-wasm, for real, in a real browser via headless Playwright -- not just that
# the wasm native build linked, and not just one OCR call (scripts/smoketest-wasm.sh's job),
# but the actual several-hundred-test unit suite this repo already runs on every other RID.
#
# Usage: scripts/unittest-wasm.sh
#
# Assumes stage/browser-wasm/native/{tesseract.a,leptonica.a} already exist (built by
# scripts/build-native-wasm.sh) -- same assumption scripts/smoketest-wasm.sh makes.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/versions.env"

WORK="$(mktemp -d)"
FEED="$WORK/feed"
mkdir -p "$FEED"
export NUGET_PACKAGES="$WORK/packages"
REPO_URL="https://github.com/${GITHUB_REPOSITORY:-jbtule/tesseract-nuget-platforms}"

echo "== Building + packing wrapper (vendor/tesseract) =="
# AssemblyName=Tesseract.CrossPlatform -- see scripts/smoketest.sh's own comment for why
# (avoids a case-insensitive-filesystem filename collision with the native alias). Not
# actually a Windows concern for a wasm-only run, but keeps this consistent with the real
# release path instead of quietly diverging: UnitTestWasm.csproj's compiled-in Tesseract.Tests
# source expects this exact assembly identity (see that csproj's own comment).
dotnet build "$ROOT/vendor/tesseract/src/Tesseract/Tesseract.csproj" -c Release \
  -p:GeneratePackageOnBuild=false -p:AssemblyName=Tesseract.CrossPlatform
sed \
  -e "s|[$]version[$]|$PACKAGE_VERSION|g" \
  -e "s|[$]repoUrl[$]|$REPO_URL|g" \
  -e "s|[$]wrapperBuild[$]|$ROOT/vendor/tesseract/src/Tesseract/bin/Release|g" \
  "$ROOT/nuget/wrapper/Tesseract.CrossPlatform.nuspec" > "$WORK/wrapper.nuspec"
dotnet pack "$ROOT/nuget/wrapper/Tesseract.CrossPlatform.csproj" -c Release -o "$FEED" \
  -p:NuspecFile="$WORK/wrapper.nuspec" -p:NuspecBasePath="$ROOT"

echo "== Packing stub Tesseract.Native (satisfies Tesseract.CrossPlatform's normal dependency) =="
sed -e "s|[$]version[$]|$PACKAGE_VERSION|g" \
  "$ROOT/smoketest/stub/Tesseract.Native.nuspec" > "$WORK/stub.nuspec"
dotnet pack "$ROOT/smoketest/stub/Stub.csproj" -c Release -o "$FEED" \
  -p:NuspecFile="$WORK/stub.nuspec" -p:NuspecBasePath="$ROOT/smoketest/stub"

cat > "$ROOT/unittest-wasm/nuget.config" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<configuration>
  <packageSources>
    <clear />
    <add key="local" value="$FEED" />
    <add key="nuget.org" value="https://api.nuget.org/v3/index.json" />
  </packageSources>
</configuration>
EOF

echo "== Staging fixture files (Data/Results/tessdata + versions.env) =="
TESTS_SRC="$ROOT/vendor/tesseract/src/Tesseract.Tests"
DEST="$ROOT/unittest-wasm/wwwroot"
rm -rf "$DEST/Data" "$DEST/Results" "$DEST/tessdata"
cp -R "$TESTS_SRC/Data" "$DEST/Data"
cp -R "$TESTS_SRC/Results" "$DEST/Results"
cp -R "$TESTS_SRC/tessdata" "$DEST/tessdata"
cp "$ROOT/versions.env" "$DEST/versions.env"

# One relative path per line, matching what Program.cs's own FetchToFile loop expects --
# real fixture files it stages into the wasm virtual filesystem before running tests, not a
# static list assumed to stay in sync by hand.
(cd "$DEST" && find Data Results tessdata -type f | sort) > "$DEST/manifest.txt"
echo "Manifest: $(wc -l < "$DEST/manifest.txt" | tr -d ' ') fixture files"

echo "== Publishing unittest-wasm for browser-wasm =="
dotnet publish "$ROOT/unittest-wasm/UnitTestWasm.csproj" -c Release \
  -p:PackageVersion="$PACKAGE_VERSION"

PUBLISH_WWWROOT="$ROOT/unittest-wasm/bin/Release/net10.0/publish/wwwroot"
echo "== Published output ($PUBLISH_WWWROOT) =="
ls -la "$PUBLISH_WWWROOT"

echo "== Running headless (Playwright) =="
cd "$ROOT/unittest-wasm"
npm ci
npx playwright install --with-deps chromium
node run-unittest.mjs "$PUBLISH_WWWROOT"
