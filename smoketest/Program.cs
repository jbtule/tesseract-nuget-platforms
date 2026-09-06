using Tesseract;

// CI smoke test: proves the packaged Tesseract.CrossPlatform +
// Tesseract.Native.runtime.<rid> actually load and run real OCR together,
// with zero TesseractEnviornment.CustomSearchPath configuration -- exactly
// what a consumer who just does `dotnet add package Tesseract.CrossPlatform`
// gets. See SmokeTest.csproj for how the packages under test get here.

var tessdataDir = Path.Combine(AppContext.BaseDirectory, "tessdata");
try
{
    using var engine = new TesseractEngine(tessdataDir, "eng", EngineMode.Default);
    using var img = Pix.LoadFromFile(Path.Combine(AppContext.BaseDirectory, "test.png"));
    using var page = engine.Process(img);
    var text = page.GetText().Trim();
    Console.WriteLine($"OCR result: \"{text}\"");
    if (!text.Contains("HELLO", StringComparison.OrdinalIgnoreCase))
    {
        Console.WriteLine("FAILURE: expected text containing \"HELLO\"");
        return 1;
    }
    Console.WriteLine("SUCCESS");
    return 0;
}
catch (Exception ex)
{
    Console.WriteLine("FAILURE: " + ex);
    return 1;
}
