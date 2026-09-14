using System.IO;

// Plain console entry point - no WebAssemblyHostBuilder/Blazor hosting, no headless
// browser, no dev-server HTTP-fetch dance (see UnitTestWasm.csproj's own Program.cs for
// the old, more involved version this replaces). runtests.mjs stages fixture files
// (Data/Results/tessdata) directly into the wasm virtual filesystem via Module.FS before
// calling into this Main, so by the time AnyUnit.Runner.Bootstrap.Runner.Run runs any
// test, AppContext.BaseDirectory-relative file access already finds them.
//
// Run() takes a Stream for its JSON output, not a path (a platform with no meaningful
// file system still has to be able to call it) - this project's own virtual FS supports
// plain File.Create fine, so this entry point still opens one from the given path.
internal static class Program
{
    private static int Main(string[] args)
    {
        var jsonOutputPath = args.Length > 0 ? args[0] : null;
        using (var jsonOutputStream = jsonOutputPath != null ? File.Create(jsonOutputPath) : null)
        {
            // AnyUnit.Util.PlatformId.Current (AnyUnit 1.1+), not a hardcoded
            // "browser-wasm" - matches AnyUnit's own browser-wasm-runner convention
            // (Runner/Platforms/browser-wasm-runner/WasmRunAlone.cs) and keeps this
            // leg's own Platform label real/dynamic like every native RID's, rather
            // than a one-off literal (see Tesseract.Tests's own Program.cs for why
            // the native side needed this same swap - a merge-collision, not a
            // concern here with only one wasm leg, but a hardcoded label everywhere
            // else would be the odd one out).
            //
            // Named-assembly overload, not the single calling-assembly one: this
            // assembly is "Tesseract.Tests" itself, but Tesseract.Tests.SkiaSharp's own
            // tests now live in a real, separate, ProjectReference'd assembly of that
            // exact name (see SkiaSharpTests/SkiaSharpTests.csproj's own comment for
            // why) - listing both here is what makes AnyUnit discover and run that
            // assembly's tests too, in this one process/one results.json, with each
            // fixture still reporting under its own real assembly identity for
            // AnyUnit.Report's merge to match against every native RID's.
            return AnyUnit.Runner.Bootstrap.Runner.Run(
                AnyUnit.Util.PlatformId.Current,
                new[] { "Tesseract.Tests", "Tesseract.Tests.SkiaSharp" },
                jsonOutputStream: jsonOutputStream);
        }
    }
}
