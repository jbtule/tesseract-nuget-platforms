# Tesseract.Native

Cross-platform native Tesseract OCR + Leptonica binaries, packaged as NuGet
runtime packages, built from source in GitHub Actions.

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
Tesseract from source for `win-x64`, `linux-x64`, `osx-x64`, and `osx-arm64`,
and publishes them as NuGet packages that follow the standard
[RID-specific runtime package](https://learn.microsoft.com/nuget/create-packages/supporting-multiple-target-frameworks#architecture-specific-packages)
pattern.

## Packages

| Package | What it is |
|---|---|
| `Tesseract.Native` | Meta-package. Depends on all four runtime packages below; NuGet's RID graph picks the right one for whatever you're building/publishing. Install this one. |
| `Tesseract.Native.runtime.win-x64` | `tesseract*.dll` + `leptonica*.dll` under `runtimes/win-x64/native/x64` |
| `Tesseract.Native.runtime.linux-x64` | `libtesseract*.so*` + `libleptonica*.so*` under `runtimes/linux-x64/native/x64` |
| `Tesseract.Native.runtime.osx-x64` | `libtesseract*.dylib` + `libleptonica*.dylib` under `runtimes/osx-x64/native/x64` |
| `Tesseract.Native.runtime.osx-arm64` | same, for Apple Silicon, under `runtimes/osx-arm64/native/arm64` |

Note the extra `x64`/`arm64` folder nested one level inside `native/` — see
"Vendored patch" below for why.

### Using it with charlesw/tesseract

```csharp
var nativeDir = Path.Combine(AppContext.BaseDirectory, "runtimes",
    RuntimeInformation.RuntimeIdentifier, "native");
TesseractEnviornment.CustomSearchPath = nativeDir;
```

Point `CustomSearchPath` at `native/`, **not** `native/<arch>/`:
`LibraryLoader.InternalLoadLibrary` always appends its own platform-name
subfolder onto `CustomSearchPath` before looking for the library, so the
extra `x64`/`arm64` directory this repo's packages ship (matching the
vendored fix below) is exactly what it expects to find one level down.

`dotnet publish` (and `dotnet run`/build for a single-RID app) copies the
matching `runtimes/<rid>/native/**` files into the output directory
automatically once `Tesseract.Native` is referenced — no manual copying
required, same mechanism SkiaSharp/OpenCvSharp runtime packages use.

> **Before first release, confirm the exact filename charlesw/tesseract's
> interop layer (`TesseractEnviornment` / InteropDotNet) expects to load.**
> If it wants an unversioned name like `libtesseract.so` rather than
> `libtesseract.5.5.0.so`, add a copy/symlink step in
> `scripts/build-native.sh` / `build-native.ps1` to match it. This repo
> ships whatever name CMake's `install()` produces, which may need a small
> alias.

## Vendored patch: arm64 misdetected as x64

`charlesw/tesseract`'s native library loader
([`SystemManager.GetPlatformName()`](vendor/tesseract/src/Tesseract/Internal/InteropDotNet/SystemManager.cs))
decides "x86" vs "x64" purely from `IntPtr.Size`, so any 64-bit ARM process
(Apple Silicon, arm64 Linux) is reported as `x64`. Since
`LibraryLoader.InternalLoadLibrary()` always appends this platform name as a
subfolder under `CustomSearchPath`, arm64 users are forced to mislabel their
arm64 binaries under an `x64` folder — which also means x64 and arm64 native
libraries can never coexist. This repo's own macOS docs and test projects
carry that exact workaround today.

`vendor/tesseract` is a submodule pointing at
[jbtule/tesseract#arm64-platform-detection](https://github.com/jbtule/tesseract/tree/arm64-platform-detection),
a fork with a one-file fix: on .NET Core/.NET 5+,
`RuntimeInformation.ProcessArchitecture` is used instead, so arm64 processes
correctly get an `arm64` subfolder. Classic .NET Framework (Windows-only,
x86/x64 only) is untouched. This has **not** been upstreamed as a PR yet —
it's vendored here so our packaging can move forward without waiting on
review, and this section should be updated (or removed) once/if it lands
upstream.

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

## How the build works

- **`versions.env`** is the single source of truth: which Leptonica/Tesseract
  source tags to build, and what NuGet package version to cut.
- **`scripts/build-native.sh <rid>`** (Linux/macOS) and
  **`scripts/build-native.ps1`** (Windows) each: pull the codec dependencies
  Leptonica needs (zlib, libpng, libjpeg-turbo, tiff, libwebp) as static libs
  via vcpkg, then `git clone` + `cmake --build --install` Leptonica and then
  Tesseract from their pinned source tags, and stage the resulting shared
  libraries under `stage/<rid>/native`.
- **`.github/workflows/build-native.yml`** runs those scripts across a
  4-way OS matrix and uploads each platform's staged output as a build
  artifact. It also runs on every PR/push touching the scripts, so build
  breakage surfaces before a release.
- **`.github/workflows/release.yml`** runs on a `vX.Y.Z` tag push: calls
  `build-native.yml`, downloads all four artifacts, packs the four runtime
  `.nupkg`s plus the `Tesseract.Native` meta `.nupkg` (via
  `nuget/runtime/RuntimePackage.csproj` + `Tesseract.Native.runtime.nuspec`,
  reused for all four RIDs through `-p:NuspecProperties`), and pushes all
  five to nuget.org using the `NUGET_API_KEY` repo secret.

## Cutting a release

1. Bump `LEPTONICA_VERSION` / `TESSERACT_VERSION` / `PACKAGE_VERSION` in
   `versions.env` as needed and commit.
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
- No `linux-arm64` / `win-arm64` yet (deferred per current scope). Adding one
  is a matrix entry + a triplet in the build script.
- No GPG/package signing, no SBOM generation, no automated smoke test that
  actually loads the built library from a sample .NET app — worth adding
  before treating this as production-grade.
- License notices: Leptonica and Tesseract are both permissively licensed
  (BSD-2-Clause-ish / Apache-2.0), and their license files are copied into
  each package, but double-check the codec dependencies' licenses
  (libjpeg-turbo, libpng, libwebp, zlib, libtiff) are compatible with your
  intended distribution before shipping publicly.
