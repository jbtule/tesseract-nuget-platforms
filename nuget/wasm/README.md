# Tesseract.Native.browser-wasm

Static Tesseract OCR + Leptonica libraries for `browser-wasm`, built from upstream source via Emscripten. Install alongside [Tesseract.CrossPlatform](https://www.nuget.org/packages/Tesseract.CrossPlatform) and `dotnet publish -r browser-wasm` — no manual `<NativeFileReference>` authoring needed.

No image codec libraries are linked in. Use [Tesseract.CrossPlatform.SkiaSharp](https://www.nuget.org/packages/Tesseract.CrossPlatform.SkiaSharp) (or any decoder you already have) to feed already-decoded pixels into a `Pix` instead of loading image files directly.

See [the repo](https://github.com/jbtule/tesseract-nuget-platforms) for usage.
