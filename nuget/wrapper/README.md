# Tesseract.CrossPlatform

A patched build of [charlesw/tesseract](https://github.com/charlesw/tesseract)'s .NET wrapper, working cross-platform with zero setup. Depends on [Tesseract.Native](https://www.nuget.org/packages/Tesseract.Native) (or, for `browser-wasm`, [Tesseract.Native.browser-wasm](https://www.nuget.org/packages/Tesseract.Native.browser-wasm)). Install this instead of `Tesseract`, not alongside it.

Need to decode image files (as opposed to already-decoded pixels) under `browser-wasm`? Install [Tesseract.CrossPlatform.SkiaSharp](https://www.nuget.org/packages/Tesseract.CrossPlatform.SkiaSharp) alongside this package too.

See [the repo](https://github.com/jbtule/tesseract-nuget-platforms) for usage.
