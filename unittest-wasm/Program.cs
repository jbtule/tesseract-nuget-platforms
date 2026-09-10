using System.Linq;
using System.Reflection;
using Microsoft.AspNetCore.Components.Web;
using Microsoft.AspNetCore.Components.WebAssembly.Hosting;
using NUnit.Framework.Api;
using NUnit.Framework.Interfaces;
using NUnit.Framework.Internal;
using NUnit.Framework.Internal.Execution;
using UnitTestWasm;

// Real, per-test wasm execution of Tesseract.Tests (see UnitTestWasm.csproj's own comment
// for why this bypasses NUnit's normal Run()/EventPump path). Prints a final
// "DONE: N passed, M failed, K skipped (T events total)" line scripts/unittest-wasm.sh's
// Playwright runner (run-unittest.mjs) greps the browser's console for -- this file has no
// other way to report back to the process that launched the browser.

Console.WriteLine("UnitTestWasm starting...");

using (var http = new HttpClient { BaseAddress = new Uri("http://localhost:8936/") })
{
    Directory.CreateDirectory("/testroot");
    await FetchToFile(http, "versions.env", "/versions.env");

    var manifest = (await http.GetStringAsync("manifest.txt"))
        .Split('\n', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);
    Console.WriteLine($"Staging {manifest.Length} fixture files from manifest...");
    foreach (var relativePath in manifest)
    {
        await FetchToFile(http, relativePath, "/testroot/" + relativePath, quiet: true);
    }

    Console.WriteLine($"Staged {manifest.Length} fixture files. Running tests...");
    Directory.SetCurrentDirectory("/testroot");

    var builder = new DefaultTestAssemblyBuilder();
    var assembly = Assembly.GetExecutingAssembly();
    ITest suite = builder.Build(assembly, new Dictionary<string, object>());
    Console.WriteLine($"Discovered suite: {suite.Name} ({suite.TestCaseCount} test cases)");

    var listener = new LiveListener();

    // WorkItemBuilder/WorkItem.RunOnCurrentThread() are NUnit's own real recursive test-suite
    // orchestration (OneTimeSetUp/[SetUpFixture]/child dispatch/OneTimeTearDown all handled
    // correctly, exactly like a normal run) -- just invoked directly on the calling thread
    // instead of going through IWorkItemDispatcher's real background-Thread-based worker pool,
    // which is what actually breaks under wasm (confirmed: TestListener/EventPump paths all
    // hit ThreadStateException with zero tests ever starting). This is the real fix, not a
    // hand-rolled reflection-based test invoker: it reuses NUnit's own execution engine.
    try
    {
        Console.WriteLine("Building work item...");
        WorkItem topLevelWorkItem = WorkItemBuilder.CreateWorkItem(suite, TestFilter.Empty, true);
        var context = new TestExecutionContext();
        var typedSuite = (Test)suite;
        context.CurrentTest = typedSuite;

        // Listener's setter and WorkItem.RunOnCurrentThread() are both internal, not part of
        // the public API surface -- confirmed via reflection dump, not guessed -- so both have
        // to be invoked that way instead of ordinary property/method syntax.
        var contextType = typeof(TestExecutionContext);
        contextType.GetProperty("Listener", BindingFlags.NonPublic | BindingFlags.Instance)!
            .SetValue(context, listener);
        // CompositeWorkItem.RunChildren() dispatches each child via Context.Dispatcher -- null
        // by default, which is what NREs without this. MainThreadWorkItemDispatcher (unlike
        // SimpleWorkItemDispatcher) has no background-thread field at all, confirmed via
        // reflection dump -- built specifically to run everything on the calling thread.
        // (Dispatcher's own setter turned out to be public, unlike Listener's -- confirmed via
        // a local, non-wasm repro after the reflection-based GetProperty call kept silently
        // returning null, which briefly looked like a trimming issue but wasn't.)
        context.Dispatcher = new MainThreadWorkItemDispatcher();

        topLevelWorkItem.InitializeContext(context);

        var runOnCurrentThread = typeof(WorkItem).GetMethod("RunOnCurrentThread",
            BindingFlags.NonPublic | BindingFlags.Instance)!;
        runOnCurrentThread.Invoke(topLevelWorkItem, null);
    }
    catch (TargetInvocationException tie)
    {
        Console.WriteLine("Threw (invoke): " + tie.InnerException);
    }
    catch (Exception ex)
    {
        Console.WriteLine("Threw (direct): " + ex);
    }

    Console.WriteLine($"DONE: {listener.Pass} passed, {listener.Fail} failed, {listener.Skip} skipped ({listener.EventCount} events total)");
}

var appBuilder = WebAssemblyHostBuilder.CreateDefault(args);
appBuilder.RootComponents.Add<App>("#app");
appBuilder.RootComponents.Add<HeadOutlet>("head::after");
await appBuilder.Build().RunAsync();

static async Task FetchToFile(HttpClient http, string relativeUrl, string destPath, bool quiet = false)
{
    Directory.CreateDirectory(Path.GetDirectoryName(destPath)!);
    var bytes = await http.GetByteArrayAsync(relativeUrl);
    await File.WriteAllBytesAsync(destPath, bytes);
    if (!quiet)
        Console.WriteLine($"Staged {destPath} ({bytes.Length} bytes)");
}

class LiveListener : ITestListener
{
    public int EventCount { get; private set; }
    public int Pass { get; private set; }
    public int Fail { get; private set; }
    public int Skip { get; private set; }

    public void TestStarted(ITest test)
    {
        EventCount++;
    }

    public void TestFinished(ITestResult result)
    {
        EventCount++;
        if (result.Test.IsSuite) return; // only report leaf tests

        switch (result.ResultState.Status)
        {
            case TestStatus.Passed:
                Pass++;
                Console.WriteLine($"PASS  {result.FullName}");
                break;
            case TestStatus.Skipped:
                Skip++;
                Console.WriteLine($"SKIP  {result.FullName} -- {result.Message}");
                break;
            default:
                Fail++;
                Console.WriteLine($"FAIL  {result.FullName} [{result.ResultState}]");
                if (!string.IsNullOrEmpty(result.Message))
                    Console.WriteLine($"      {result.Message}");
                break;
        }
    }

    public void TestOutput(TestOutput output)
    {
        EventCount++;
    }

    public void SendMessage(TestMessage message)
    {
        EventCount++;
    }
}
