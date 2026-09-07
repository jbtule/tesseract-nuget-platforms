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
#        AOT=1 scripts/smoketest.sh <rid>   -- NativeAOT publish + run instead
#          of the normal framework-dependent one, for local use: proves the
#          interop layer's plain [DllImport] + NativeLibrary.SetDllImportResolver
#          mechanism (see README, "Our fork of charlesw/tesseract") actually
#          works under NativeAOT, which its Reflection.Emit-based predecessor
#          could not (PlatformNotSupportedException). Not wired into CI --
#          requires the platform's native AOT toolchain (e.g. Xcode command
#          line tools on macOS, clang/lld on Linux, VS Build Tools on
#          Windows) to already be installed locally; run for whichever RID
#          matches the machine you're on.
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
# Isolate the restore from the machine's ambient global NuGet cache: without
# this, a rerun against an unchanged PACKAGE_VERSION silently restores
# whatever Tesseract.CrossPlatform/Tesseract.Native.runtime.<rid> that
# version resolved to last time (a prior local run, or the real published
# package) instead of what this run just packed -- NuGet keys its global
# cache on id+version only, not content. Confirmed via a real repro: a
# stale cached 5.5.2.2 silently shadowed a freshly-packed one with actual
# code changes, of all things. Harmless in CI (each job gets a fresh
# runner), but this is what makes reruns on a dev machine actually
# trustworthy.
export NUGET_PACKAGES="$WORK/packages"
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

# AssemblyName=Tesseract.CrossPlatform (not the default "Tesseract", from
# the project file name): a generic native "tesseract.dll" alias (see
# Constants.cs in the vendored fix) and a managed "Tesseract.dll" would
# otherwise collide on a case-insensitive filesystem (Windows) -- confirmed
# via a real NETSDK1152 "multiple publish output files" failure. Namespace
# and types are untouched, only the built file name changes.
dotnet build "$ROOT/vendor/tesseract/src/Tesseract/Tesseract.csproj" -c Release \
  -p:GeneratePackageOnBuild=false -p:AssemblyName=Tesseract.CrossPlatform

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
if [ "${AOT:-0}" = "1" ]; then
  echo "== AOT smoke test: publishing a self-contained NativeAOT binary =="
  dotnet publish "$ROOT/smoketest/SmokeTest.csproj" -c Release -o "$OUT" \
    -r "$RID" --self-contained true \
    -p:Rid="$RID" -p:PackageVersion="$PACKAGE_VERSION" -p:PublishAot=true
else
  dotnet publish "$ROOT/smoketest/SmokeTest.csproj" -c Release -o "$OUT" \
    -r "$RID" --self-contained false \
    -p:Rid="$RID" -p:PackageVersion="$PACKAGE_VERSION"
fi
cp -r "$ROOT/smoketest/tessdata" "$OUT/"

echo "== Published output ($OUT) =="
ls -la "$OUT"

cd "$OUT"
if [ "${AOT:-0}" = "1" ]; then
  case "$RID" in
    win-*) ./SmokeTest.exe ;;
    *) ./SmokeTest ;;
  esac
else
  dotnet SmokeTest.dll
fi
