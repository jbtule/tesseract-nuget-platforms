#!/usr/bin/env bash
# Packs Tesseract.CrossPlatform + Tesseract.Native.runtime.<rid> (both built
# fresh from what this job just produced under stage/<rid>) plus a
# zero-dependency stub Tesseract.Native into a local feed, then does a real
# `dotnet publish -r <rid> --self-contained false` + run of smoketest/,
# proving the actual packaged output works end to end (real OCR against
# smoketest/test.png) -- not just that the native build succeeded. This is
# what caught three real bugs (missing transitive native dependencies,
# wrong hardcoded DLL names, no zero-config discovery) that a build-only
# check would have shipped straight to nuget.org.
#
# Runs equally on Linux/macOS bash and Windows Git Bash (`shell: bash` in
# the workflow) -- dotnet, sed, curl all behave the same either way, so
# there's one script instead of a bash + PowerShell copy of the same logic.
#
# Usage: scripts/smoketest.sh <rid>
set -euo pipefail

# On Windows (Git Bash), plain bash-computed paths are MSYS-style
# (e.g. "/d/a/tesseract-nuget-platforms") -- fine for bash's own file
# operations, but native tools like dotnet.exe/NuGet can't parse them.
# Confirmed via a real failure: a generated .nuspec embedding one of
# these verbatim caused NuGet to misread "/d/a/..." as rooted on the
# current drive, producing "Could not find a part of the path
# 'C:\d\a\...'". Convert to mixed-mode (drive letter + forward slashes,
# e.g. "D:/a/...") wherever a path gets embedded into a nuspec or
# passed to dotnet -- understood by both bash and native tools, with no
# backslash-escaping concerns either way. No-op on Linux/macOS, where
# cygpath doesn't exist.
to_native_path() {
  if command -v cygpath >/dev/null 2>&1; then
    cygpath -m "$1"
  else
    printf '%s' "$1"
  fi
}

# One explicit, absolute, non-wildcard <file> entry per actual file in $1,
# targeting $2 in the package -- see the NATIVE_FILES_PLACEHOLDER comment
# in the runtime nuspec for why this replaced a glob pattern.
gen_file_entries() {
  local dir="$1" target="$2" f
  for f in "$dir"/*; do
    [ -f "$f" ] || continue
    printf '    <file src="%s" target="%s" />\n' "$f" "$target"
  done
}

RID="${1:?usage: smoketest.sh <rid>}"
ROOT="$(to_native_path "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)")"
# shellcheck disable=SC1091
source "$ROOT/versions.env"

WORK="$(to_native_path "$(mktemp -d)")"
FEED="$WORK/feed"
mkdir -p "$FEED"
REPO_URL="https://github.com/${GITHUB_REPOSITORY:-jbtule/tesseract-nuget-platforms}"

gen_file_entries "$ROOT/stage/$RID/native" "runtimes/$RID/native" > "$WORK/native-files.xml"
gen_file_entries "$ROOT/stage/$RID/licenses" "licenses" > "$WORK/license-files.xml"

sed \
  -e "s|[$]id[$]|Tesseract.Native.runtime.$RID|g" \
  -e "s|[$]rid[$]|$RID|g" \
  -e "s|[$]version[$]|$PACKAGE_VERSION|g" \
  -e "s|[$]vcpkgRef[$]|$VCPKG_REF|g" \
  -e "s|[$]repoUrl[$]|$REPO_URL|g" \
  -e "/NATIVE_FILES_PLACEHOLDER/r $WORK/native-files.xml" \
  -e "/NATIVE_FILES_PLACEHOLDER/d" \
  -e "/LICENSE_FILES_PLACEHOLDER/r $WORK/license-files.xml" \
  -e "/LICENSE_FILES_PLACEHOLDER/d" \
  "$ROOT/nuget/runtime/Tesseract.Native.runtime.nuspec" > "$WORK/runtime.nuspec"
dotnet pack "$ROOT/nuget/runtime/RuntimePackage.csproj" -c Release -o "$FEED" \
  -p:NuspecFile="$WORK/runtime.nuspec" -p:NuspecBasePath="$ROOT"
echo "== Packed runtime nupkg contents (runtimes/) =="
python3 -c "
import zipfile
with zipfile.ZipFile('$FEED/Tesseract.Native.runtime.$RID.$PACKAGE_VERSION.nupkg') as z:
    for n in z.namelist():
        if 'runtimes/' in n:
            print(n)
"

dotnet build "$ROOT/vendor/tesseract/src/Tesseract/Tesseract.csproj" -c Release \
  -p:GeneratePackageOnBuild=false

sed \
  -e "s|[$]version[$]|$PACKAGE_VERSION|g" \
  -e "s|[$]repoUrl[$]|$REPO_URL|g" \
  -e "s|[$]wrapperBuild[$]|$ROOT/vendor/tesseract/src/Tesseract/bin/Release|g" \
  "$ROOT/nuget/wrapper/Tesseract.CrossPlatform.nuspec" > "$WORK/wrapper.nuspec"
dotnet pack "$ROOT/nuget/wrapper/Tesseract.CrossPlatform.csproj" -c Release -o "$FEED" \
  -p:NuspecFile="$WORK/wrapper.nuspec" -p:NuspecBasePath="$ROOT"

# Real Tesseract.Native depends on all four per-RID runtime packages, most
# of which don't exist in a single-RID CI job -- this zero-dependency stub
# satisfies Tesseract.CrossPlatform's normal dependency on it, so the
# smoke test project can reference Tesseract.Native.runtime.<rid> directly
# instead.
sed -e "s|[$]version[$]|$PACKAGE_VERSION|g" \
  "$ROOT/smoketest/stub/Tesseract.Native.nuspec" > "$WORK/stub.nuspec"
dotnet pack "$ROOT/smoketest/stub/Stub.csproj" -c Release -o "$FEED" \
  -p:NuspecFile="$WORK/stub.nuspec" -p:NuspecBasePath="$ROOT/smoketest/stub"

cat > "$ROOT/smoketest/nuget.config" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<configuration>
  <packageSources>
    <clear />
    <add key="local" value="$FEED" />
    <add key="nuget.org" value="https://api.nuget.org/v3/index.json" />
  </packageSources>
</configuration>
EOF

mkdir -p "$ROOT/smoketest/tessdata"
curl -sL -o "$ROOT/smoketest/tessdata/eng.traineddata" \
  "https://github.com/tesseract-ocr/tessdata_fast/raw/main/eng.traineddata"

OUT="$WORK/out"
dotnet publish "$ROOT/smoketest/SmokeTest.csproj" -c Release -o "$OUT" \
  -r "$RID" --self-contained false \
  -p:Rid="$RID" -p:PackageVersion="$PACKAGE_VERSION"
cp -r "$ROOT/smoketest/tessdata" "$OUT/"

echo "== Published output ($OUT) =="
ls -la "$OUT"

cd "$OUT"
dotnet SmokeTest.dll
