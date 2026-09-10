using Microsoft.AspNetCore.Components.Web;
using Microsoft.AspNetCore.Components.WebAssembly.Hosting;
using SkiaSharp;
using Tesseract;
using SmokeTestWasm;

// CI smoke test: proves the packaged Tesseract.CrossPlatform +
// Tesseract.Native.browser-wasm + Tesseract.CrossPlatform.SkiaSharp actually
// load and run real OCR together in a real browser, with zero
// TesseractEnviornment.CustomSearchPath-equivalent configuration -- exactly
// what a consumer who just does `dotnet add package Tesseract.CrossPlatform`
// + `dotnet add package Tesseract.Native.browser-wasm` gets. See
// SmokeTestWasm.csproj for how the packages under test get here.
//
// Prints a RESULT=PASS/FAIL line scripts/smoketest-wasm.sh's Playwright
// runner greps the browser's console for -- this file has no other way to
// report back to the process that launched the browser.

Console.WriteLine("SmokeTestWasm starting...");

string result;
try
{
    using var http = new HttpClient { BaseAddress = new Uri("http://localhost:8934/") };

    var traineddata = await http.GetByteArrayAsync("tessdata/eng.traineddata");
    Directory.CreateDirectory("/tessdata");
    await File.WriteAllBytesAsync("/tessdata/eng.traineddata", traineddata);

    // Engine constructed before any Pix/SkiaPixConverter/LeptonicaApi use,
    // deliberately: the natural "build the engine once in init, convert
    // pixels later per scan" pattern most real consumers write (also how
    // the desktop CLI itself is structured), and the one order that
    // actually exercises LeptonicaApi.SuppressConsoleOutputUnderWasm's own
    // "whichever class gets touched first" fix -- a real, previously-missed
    // bug, since this file used to construct Pix first, which accidentally
    // never exercised it. Reordering this is the whole reason that bug was
    // findable here at all instead of only in a real consumer's own code.
    using var engine = new TesseractEngine("/tessdata", "eng", EngineMode.Default);

    // The real image-codec gap this whole package exists to cover: the
    // browser-wasm native build has no libjpeg/libpng/libtiff/giflib linked
    // in (see the WASM backlog plan's codec-drop decision), so
    // Pix.LoadFromFile can't read test.png directly here the way
    // ../smoketest/Program.cs does for the other 5 RIDs. Decode with
    // SkiaSharp (whose own SkiaSharp.NativeAssets.WebAssembly native asset
    // *does* work under wasm) and hand the pixels to Pix instead.
    var pngBytes = await http.GetByteArrayAsync("test.png");
    using var bitmap = SKBitmap.Decode(pngBytes);
    using var pix = SkiaPixConverter.ToPix(bitmap);

    using var page = engine.Process(pix);
    var text = page.GetText().Trim();
    Console.WriteLine($"OCR result: \"{text}\"");

    if (!text.Contains("HELLO", StringComparison.OrdinalIgnoreCase))
    {
        result = "FAIL:unexpected-text:" + text;
    }
    else
    {
        result = "PASS:" + engine.Version;
    }
}
catch (Exception ex)
{
    Console.WriteLine("Threw: " + ex);
    result = "FAIL:" + ex.GetType().Name + ":" + ex.Message;
}

Console.WriteLine("RESULT=" + result);

var builder = WebAssemblyHostBuilder.CreateDefault(args);
builder.RootComponents.Add<App>("#app");
builder.RootComponents.Add<HeadOutlet>("head::after");

await builder.Build().RunAsync();
