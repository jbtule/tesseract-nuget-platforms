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
| `Tesseract.CrossPlatform` | The [charlesw/tesseract](https://github.com/charlesw/tesseract) C# wrapper itself, built from the patched fork in `vendor/tesseract` (see "Vendored patches" below), depending on `Tesseract.Native`. **API-compatible drop-in replacement for the stock `Tesseract` package** — same namespace/types. Install this *instead of* `Tesseract`, not alongside it. |

### Using it

If you install `Tesseract.CrossPlatform` and publish for a concrete
platform, **no `CustomSearchPath` code is needed at all**:

```
dotnet publish -r osx-arm64 --self-contained false
```

`dotnet publish -r <rid>` (framework-dependent or self-contained — the
standard, documented way to consume any RID-specific native package) copies
the matching native binaries flat into the output directory, right next to
your app itself. The patched wrapper's loader (see "Vendored patches") now
checks that flat path automatically, so it just finds them — verified with
an actual `dotnet publish` + run doing real OCR, not assumed.

This does mean you need to target a concrete RID *somewhere* — a bare
`dotnet run`/`dotnet build` with no RID context anywhere (no `-r`, no
`<RuntimeIdentifier>` in the project) won't have any native asset to find,
for any RID-specific native package, ours included; there'd be no way to
know which platform's binary to fetch. That's inherent to how these
packages work, not something specific to us.

If you're using the *stock* `Tesseract` package instead (unpatched — you'd
still hit the arm64-misdetection and flat-vs-nested-path issues described
below, and have to set `CustomSearchPath` yourself pointing at a manually
arranged `<platform>` subfolder), you still only need `Tesseract.Native`
for the binaries themselves.

## Vendored patches

`vendor/tesseract` is a submodule pointing at
[jbtule/tesseract#arm64-platform-detection](https://github.com/jbtule/tesseract/tree/arm64-platform-detection),
a fork of `charlesw/tesseract` with several small fixes to the native
library loader, none upstreamed as a PR yet — they're vendored here so our
packaging can move forward without waiting on review; this section should
be updated (or removed) once/if they land upstream. All were found (and
verified fixed) via an actual end-to-end smoke test — construct a
`TesseractEngine` and run real OCR against a generated image — not by
inspection alone; several were non-obvious enough that inspection missed
them the first time.

**The flat output-directory path is checked, not just the legacy nested
one.** `LibraryLoader.InternalLoadLibrary()` — which backs every automatic
fallback location (executing-assembly dir, app-domain base dir, bin dir,
working directory) plus `CustomSearchPath` — unconditionally forced a
platform-name subfolder (`x86`/`x64`/`arm64`) between the base directory
and the filename. But `dotnet publish -r <rid>` (the standard way to
consume a RID-specific native package) copies native assets *flat* into
the output root, not nested — so nothing ever found them without a caller
manually setting `CustomSearchPath` to a manually-arranged nested folder.
Now the flat `<baseDirectory>/<file>` path is tried first everywhere,
falling back to the legacy nested layout for anyone relying on that. This
is what makes `Tesseract.CrossPlatform` work with zero setup code after a
normal `dotnet publish -r <rid>`.

**Generic (unversioned) native library names.** `Constants.LeptonicaDllName`
/ `TesseractDllName` were hardcoded to `"leptonica-1.82.0"` /
`"tesseract50"` — the literal filenames of charlesw's own bundled Windows
binaries. No search path fixes a flatly wrong filename: any consumer
supplying their own build (via `CustomSearchPath`, or the flat-path
discovery above) would never be found unless their files happened to be
named identically to that one specific old bundled version. Changed to
generic `"leptonica"`/`"tesseract"` — the loader's own `FixUpLibraryName`
already appends the right platform prefix/extension, resolving to
`libleptonica.so`/`libleptonica.dylib`/`leptonica.dll`, names that exist as
unversioned aliases regardless of the exact release in use.

**An additional `runtimes/<rid>/native/` fallback** (`CheckNuGetRuntimesFolder`,
computed lazily on first actual `LoadLibrary` call, not eagerly at
startup), for the less common case of a portable multi-RID build that
might still nest assets that way. Not what makes the common case above
work, but harmless to also check.

**`CustomSearchPath` now checks the given path directly first**, the same
flat-before-nested fix as above, applied specifically to
`CheckCustomSearchPath` too.

**arm64 misdetected as x64.**
[`SystemManager.GetPlatformName()`](vendor/tesseract/src/Tesseract/Internal/InteropDotNet/SystemManager.cs)
decided "x86" vs "x64" purely from `IntPtr.Size`, so any 64-bit ARM process
(Apple Silicon, arm64 Linux) was reported as `x64`, and arm64/x64 binaries
could never coexist in the legacy nested-by-platform-name fallback
locations. On .NET Core/.NET 5+ it now uses
`RuntimeInformation.ProcessArchitecture` instead, so arm64 processes
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
  reused for all four RIDs), builds `vendor/tesseract`'s wrapper assembly
  and packs it as `Tesseract.CrossPlatform` (via
  `nuget/wrapper/Tesseract.CrossPlatform.{csproj,nuspec}`), and pushes all
  six to nuget.org via [Trusted Publishing](https://learn.microsoft.com/nuget/nuget-org/trusted-publishing)
  (OIDC) — no long-lived API key stored in the repo. Each nuspec's `$token$`
  placeholders are filled in with `sed` into a temp file, then packed via
  `-p:NuspecFile=<path>` — not `-p:NuspecProperties="k1=v1;k2=v2"`, which
  looks like the "correct" way to do this but silently only substitutes the
  first token in practice (both MSBuild's `-p:` parsing and NuGet's own
  `NuspecProperties` parsing use `;` as their delimiter, and on the SDK
  version this runs against, the outer one wins).

## One-time setup: Trusted Publishing

Before the first release can actually publish:

1. On nuget.org: account menu → **Trusted Publishing** → add a policy with
   Repository Owner `jbtule`, Repository `tesseract-nuget-platforms`,
   Workflow File `release.yml` (file name only, no path), Environment left
   blank.
2. Add a `NUGET_USER` repo secret holding your nuget.org username (profile
   name, *not* email) — not sensitive enough to strictly require a secret,
   but keeps it out of workflow logs.

No API key to create, store, or rotate — `release.yml` exchanges a
GitHub-issued OIDC token for a nuget.org API key that's valid for one hour
and single-use, requested right before each push.

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

- **Trusted Publishing setup** (above) needs to be done before the first
  release will actually publish.
- **Package ownership**: `Tesseract.Native`, `Tesseract.Native.runtime.*`,
  and `Tesseract.CrossPlatform` were unclaimed on nuget.org as of writing —
  verify that's still true and claim them under your account before
  relying on the ids. (Trusted Publishing policies can only be set up for
  ids you already own or that don't exist yet, so this is somewhat
  self-resolving on first publish, but check before you're relying on it.)
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
