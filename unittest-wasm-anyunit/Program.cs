// Plain console entry point - no WebAssemblyHostBuilder/Blazor hosting, no headless
// browser, no dev-server HTTP-fetch dance (see UnitTestWasm.csproj's own Program.cs for
// the old, more involved version this replaces). runtests.mjs stages fixture files
// (Data/Results/tessdata) directly into the wasm virtual filesystem via Module.FS before
// calling into this Main, so by the time AnyUnit.Runner.Bootstrap.Runner.Run runs any
// test, AppContext.BaseDirectory-relative file access already finds them.
internal static class Program
{
    private static int Main(string[] args)
    {
        var jsonOutputPath = args.Length > 0 ? args[0] : null;
        return AnyUnit.Runner.Bootstrap.Runner.Run("browser-wasm", jsonOutputPath: jsonOutputPath);
    }
}
