# Tesseract.Native

Cross-platform native Tesseract OCR + Leptonica binaries, packaged as NuGet
runtime packages, built via [vcpkg](https://vcpkg.io)'s own `tesseract`/
`leptonica` ports in GitHub Actions.

## Why this exists

[charlesw/tesseract](https://github.com/charlesw/tesseract) is a great .NET
wrapper, but it doesn't ship native binaries for anything but Windows — you're
expected to bring your own `libtesseract`/`libleptonica` for Linux and macOS
and point the wrapper at it via `TesseractEnviornment.CustomSearchPath`.
Nobody publishes a full win/linux/mac set:

- [grinay/osx_arm_builds](https://github.com/grinay/osx_arm_builds) only
  covers `osx-arm64` (`Tesseract.runtime.osx_arm64` on nuget.org).
- [`TesseractOCR`](https://www.nuget.org/packages/TesseractOCR) (the
  Sicos1977 fork) only bundles Windows DLLs; Linux users are pointed at
  Docker.

This repo fills the gap: one GitHub Actions matrix that builds Leptonica +
Tesseract for `win-x64`, `win-arm64`, `linux-x64`, and `osx-arm64` via
vcpkg, and publishes them as NuGet packages that follow the standard
[RID-specific runtime package](https://learn.microsoft.com/nuget/create-packages/supporting-multiple-target-frameworks#architecture-specific-packages)
pattern.

## Packages

| Package | What it is |
|---|---|
| `Tesseract.Native` | Meta-package. Depends on all four runtime packages below; NuGet's RID graph picks the right one for whatever you're building/publishing. Install this one. |
| `Tesseract.Native.runtime.win-x64` | `tesseract*.dll` + `leptonica*.dll` under `runtimes/win-x64/native` |
| `Tesseract.Native.runtime.win-arm64` | same, cross-compiled by vcpkg from the x64 runner host, under `runtimes/win-arm64/native` |
| `Tesseract.Native.runtime.linux-x64` | `libtesseract*.so*` + `libleptonica*.so*` under `runtimes/linux-x64/native` |
| `Tesseract.Native.runtime.osx-arm64` | `libtesseract*.dylib` + `libleptonica*.dylib` under `runtimes/osx-arm64/native`, for Apple Silicon |

### Using it with charlesw/tesseract

```csharp
var nativeDir = Path.Combine(AppContext.BaseDirectory, "runtimes",
    RuntimeInformation.RuntimeIdentifier, "native");
TesseractEnviornment.CustomSearchPath = nativeDir;
```

Point `CustomSearchPath` directly at `native/` — with the vendored fix below,
that's exactly where it looks first; no extra platform-name subfolder
required.

`dotnet publish` (and `dotnet run`/build for a single-RID app) copies the
matching `runtimes/<rid>/native/**` files into the output directory
automatically once `Tesseract.Native` is referenced — no manual copying
required, same mechanism SkiaSharp/OpenCvSharp runtime packages use.

> **Before first release, confirm the exact filename charlesw/tesseract's
> interop layer (`TesseractEnviornment` / InteropDotNet) expects to load.**
> If it wants an unversioned name like `libtesseract.so` rather than a
> versioned one, add a copy/symlink step in `scripts/build-native.sh` /
> `build-native.ps1` to match it. This repo ships whatever name vcpkg's
> port produces, which may need a small alias.

## Vendored patches

`vendor/tesseract` is a submodule pointing at
[jbtule/tesseract#arm64-platform-detection](https://github.com/jbtule/tesseract/tree/arm64-platform-detection),
a fork of `charlesw/tesseract` with two small fixes to the native library
loader. Neither has been upstreamed as a PR yet — they're vendored here so
our packaging can move forward without waiting on review; this section
should be updated (or removed) once/if they land upstream.

**`CustomSearchPath` now checks the given path directly first.**
`LibraryLoader.CheckCustomSearchPath()` used to unconditionally append an
inferred platform-name subfolder (`x86`/`x64`/`arm64`) underneath
`CustomSearchPath` before looking for the library — so a path you set
explicitly, already knowing exactly which folder holds the right binaries,
got a folder name silently appended on top of it anyway. The fix checks
`<CustomSearchPath>/<file>` first and only falls back to the old
`<CustomSearchPath>/<platform>/<file>` layout if that's not found, so it's
non-breaking for anyone relying on the old behavior. This is why this
repo's packages ship a plain `runtimes/<rid>/native/*` with no extra arch
folder nested inside.

**arm64 misdetected as x64** (still relevant for the automatic fallback
locations `LibraryLoader` also checks — executing-assembly dir, app-domain
base dir, bin dir, working directory — which still nest by platform name
and aren't something a caller controls the layout of).
[`SystemManager.GetPlatformName()`](vendor/tesseract/src/Tesseract/Internal/InteropDotNet/SystemManager.cs)
decided "x86" vs "x64" purely from `IntPtr.Size`, so any 64-bit ARM process
(Apple Silicon, arm64 Linux) was reported as `x64`, and arm64/x64 binaries
could never coexist in those fallback folders. On .NET Core/.NET 5+ it now
uses `RuntimeInformation.ProcessArchitecture` instead, so arm64 processes
correctly get an `arm64` subfolder there. Classic .NET Framework
(Windows-only, x86/x64 only) is untouched.

## Backlog: Blazor WASM (`browser-wasm`)

Not started, and out of scope for this repo's current packaging model. Notes
for when it comes up:

- `browser-wasm` has no `dlopen`/`LoadLibrary`-style dynamic loader, so the
  `dlopen`/`dlsym`/`LoadLibrary` interop layer this repo's
  `runtimes/<rid>/native` packages rely on (`LibraryLoader` /
  `ILibraryLoaderLogic` in `vendor/tesseract`) doesn't apply. A wasm build
  would need to be statically linked at `dotnet publish` time
  (`<NativeFileReference>`), which is a fundamentally different packaging
  shape — not a 5th RID for `Tesseract.Native`.
- Real prior art exists for the native-code side:
  [tesseract-wasm](https://github.com/robertknight/tesseract-wasm) /
  [tesseract.js](https://github.com/naptha/tesseract.js) already compile
  Tesseract+Leptonica with Emscripten.
- The payoff worth chasing, if/when this gets picked up: extending
  `vendor/tesseract` with a third `ILibraryLoaderLogic`-equivalent backend
  for the static-link case would let the *same* `TesseractEngine`/`Page`
  C# API used on desktop/server work unmodified in a Blazor WASM app —
  genuinely one API surface, not a JS-interop-shaped facade. That's a
  multi-day effort on its own (Emscripten build + a new interop backend),
  separate from win/linux/mac native packaging here.
- Until then, the pragmatic answer for a `net10.0-browser` app needing OCR
  is what's already in place elsewhere: call `tesseract.js` via JS interop,
  optionally hidden behind a small internal C# facade shaped like
  `TesseractEngine` so callers don't see the JS interop plumbing.

## Backlog: Android (`android-arm64`)

Also not started, also out of scope for the current packaging model —
`linux-arm64` binaries do **not** run on Android even though its kernel is
Linux:

- Android uses Bionic, not glibc — needs a build compiled with the Android
  NDK's clang toolchain targeting `android-arm64`/`android-x64`, not our
  glibc-based linux job.
- `vendor/tesseract`'s `SystemManager.GetOperatingSystem()` only recognizes
  Windows/Unix/MacOSX today and throws `"Unsupported operation system"` for
  anything else — Android needs its own case, plus (likely) its own
  `ILibraryLoaderLogic`, since modern Android restricts `dlopen` to paths
  inside the app's own extracted native-lib directory rather than an
  arbitrary `CustomSearchPath`.
- Same shape of effort as the WASM backlog item above: a real but separate
  track, not a matrix entry.

## Backlog: iOS (`ios-arm64` / `iossimulator-arm64`/`-x64`)

Also not started, also out of scope for the current packaging model, and
arguably the hardest of the three backlog items:

- Same OS-detection gap as Android — `SystemManager.GetOperatingSystem()`
  doesn't recognize iOS and throws.
- Unlike desktop/server, iOS doesn't really support `CustomSearchPath`-style
  runtime `dlopen` of arbitrary files at all for App Store distribution —
  native code has to be statically linked (or embedded as a properly
  code-signed `.xcframework`) at build time, so this needs the same kind of
  static-link interop backend the WASM item above would need, not another
  `ILibraryLoaderLogic` that calls `dlopen`.
- Three RIDs, not one: `ios-arm64` (device) plus `iossimulator-arm64` and
  `iossimulator-x64` (Apple Silicon and Intel Mac simulator hosts), each a
  separate cross-compile.
- Real prior art exists (e.g. gali8/Tesseract-OCR-iOS), so the
  Tesseract/Leptonica build side is solved territory — the work is the
  static-link `.xcframework` packaging plus the interop backend.

## How the build works

Tesseract's own `CMakeLists.txt` has real, still-open gaps in ARM64+MSVC
support as of this writing — see
[tesseract-ocr/tesseract#3466](https://github.com/tesseract-ocr/tesseract/issues/3466),
where even the officially-documented `-G "Visual Studio 17 2022" -A ARM64`
approach misdetects the target as x86 (`HAVE_AVX2: ON` etc. on an ARM64
build) and fails to link NEON symbols. vcpkg's `tesseract`/`leptonica` ports
already carry the accumulated patches for exactly this (ARM64-Windows
support landed there in 2022); we build through vcpkg specifically to
inherit that maintenance rather than re-deriving each fix ourselves.

- **`versions.env`** is the single source of truth: which `vcpkg` ref to
  build tesseract/leptonica from (`VCPKG_REF`), and what NuGet package
  version to cut (`PACKAGE_VERSION`).
- **`scripts/build-native.sh <rid>`** (Linux/macOS) and
  **`scripts/build-native.ps1`** (Windows) each: clone vcpkg at `VCPKG_REF`,
  bootstrap it, and `vcpkg install tesseract leptonica` for a dynamic
  (shared-library) triplet — `x64-linux-dynamic`/`arm64-osx-dynamic` on
  Unix (vcpkg's default Linux/macOS triplets are static; the `-dynamic`
  community triplets exist precisely for cases like ours), plain
  `x64-windows`/`arm64-windows` on Windows (dynamic by default there) — then
  stage the resulting shared libraries under `stage/<rid>/native`. See the
  comments at the top of each script for why we consume vcpkg's ports
  rather than building from tesseract/leptonica's own source tags directly.
- **`.github/workflows/build-native.yml`** runs those scripts across a
  4-way matrix (win-x64, win-arm64, linux-x64, osx-arm64) and uploads each
  platform's staged output as a build artifact. It also runs on every
  PR/push touching the scripts, so build breakage surfaces before a
  release. vcpkg handles the win-arm64 cross-compile from the x64
  `windows-latest` runner internally — no manual toolchain setup needed.
- **`.github/workflows/release.yml`** runs on a `vX.Y.Z` tag push: calls
  `build-native.yml`, downloads all four artifacts, packs the four runtime
  `.nupkg`s plus the `Tesseract.Native` meta `.nupkg` (via
  `nuget/runtime/RuntimePackage.csproj` + `Tesseract.Native.runtime.nuspec`,
  reused for all four RIDs through `-p:NuspecProperties`), and pushes all
  five to nuget.org using the `NUGET_API_KEY` repo secret.

## Cutting a release

1. Bump `VCPKG_REF` / `PACKAGE_VERSION` in `versions.env` as needed and
   commit. (`VCPKG_REF` doesn't have to change every release — only bump it
   when you want a newer tesseract/leptonica; check
   `ports/tesseract/vcpkg.json` at that ref on GitHub to see which version
   you'd get.)
2. `git tag v<PACKAGE_VERSION> && git push origin v<PACKAGE_VERSION>` — the
   tag's version must match `PACKAGE_VERSION` exactly or the release job
   fails fast.
3. Watch the Release workflow; it publishes to nuget.org on success.

## Known gaps / not yet done

- **`NUGET_API_KEY` secret** needs to be added to the repo before the first
  release will actually publish.
- **Package ownership**: `Tesseract.Native` / `Tesseract.Native.runtime.*`
  were unclaimed on nuget.org as of writing — verify that's still true and
  claim them under your account before relying on the id.
- No `osx-x64` (Intel Mac): dropped deliberately — declining relevance plus
  GH's `macos-13` runner pool queuing for 15+ minutes before even starting a
  build. `win-arm64` was added in its place as the more useful target.
- No `linux-arm64` yet (deferred per current scope). Adding one is a matrix
  entry + a triplet in the build script, same shape as the existing
  linux-x64 job.
- No GPG/package signing, no SBOM generation, no automated smoke test that
  actually loads the built library from a sample .NET app — worth adding
  before treating this as production-grade.
- License notices: Leptonica and Tesseract are both permissively licensed
  (BSD-2-Clause-ish / Apache-2.0), and their license files are copied into
  each package, but double-check the codec dependencies' licenses
  (libjpeg-turbo, libpng, libwebp, zlib, libtiff) are compatible with your
  intended distribution before shipping publicly.
