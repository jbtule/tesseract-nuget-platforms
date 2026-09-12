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
            return AnyUnit.Runner.Bootstrap.Runner.Run("browser-wasm", jsonOutputStream: jsonOutputStream);
        }
    }
}
