// Boots the WebAssembly build under node/bun and forwards its exit code - same trick
// QrLinkPdf.Tests.Wasm's own runtests.mjs uses (dotnet.js detects a non-browser JS host
// and loads the runtime itself, no browser/dev-server/Playwright needed - replaces
// UnitTestWasm.csproj's own HTTP-fetch-from-a-dev-server staging, which only existed
// because that project runs under a real headless browser).
//
// Fixture files (Data/Results/tessdata/versions.env) were copied into fixtures/ next to
// this file at build time (see the .csproj's own <None> items) - staged from there
// directly into the wasm virtual filesystem via Module.FS, mirroring the real repo
// layout (Data/, Results/, tessdata/, versions.env all siblings at the same root) so
// TesseractTestBase/TestEnvironment's own AppContext.BaseDirectory-relative path
// resolution finds them exactly as it would on desktop. Plain POSIX File.Exists/
// File.OpenRead calls never go through fetch() at all under node/bun (confirmed
// empirically - see AnyUnit's own Runner/Platforms/browser-wasm-runner-host/Readme.md),
// so this has to happen through Module.FS directly, before runMain().
import { dotnet } from './_framework/dotnet.js';
import { readFileSync, readdirSync, statSync, writeFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
// fixtures/ lands as a sibling of wwwroot/ in the build output (a plain <None>
// Link outside "wwwroot\..." isn't part of Blazor's own wwwroot bundling - it
// just copies relative to the output root), not inside wwwroot/ itself, so
// this needs to go up one level from where this script actually runs.
const fixturesRoot = path.join(__dirname, '..', 'fixtures');

// This script's own first argument is the HOST path to write results.json to,
// not the app's own argument - Program.cs always gets a fixed in-VFS path
// (resultsVfsPath below) instead, so this script can read it back out of
// Module.FS (an in-memory filesystem - File.Create inside it never touches
// the real disk on its own, confirmed the hard way: passing the host path
// straight through to withApplicationArguments builds a results.json that
// looks fine in the run's own console output, then simply isn't there
// afterward) and copy it out for real once the run is done.
const hostResultsPath = process.argv[2];
const resultsVfsPath = '/results.json';

const dotnetInstance = await dotnet
    .withApplicationArguments(...(hostResultsPath ? [resultsVfsPath] : []))
    .create();

function mkdirp(fs, vfsDir) {
    const parts = vfsDir.split('/').filter(Boolean);
    let current = '';
    for (const part of parts) {
        current += '/' + part;
        try {
            fs.mkdir(current);
        } catch {
            // already exists
        }
    }
}

function stageDirectory(fs, realDir, vfsDir) {
    mkdirp(fs, vfsDir);
    for (const entry of readdirSync(realDir)) {
        const realPath = path.join(realDir, entry);
        const vfsPath = vfsDir + '/' + entry;
        if (statSync(realPath).isDirectory()) {
            stageDirectory(fs, realPath, vfsPath);
        } else {
            fs.writeFile(vfsPath, readFileSync(realPath));
        }
    }
}

const fs = dotnetInstance.Module.FS;
for (const name of ['Data', 'Results', 'tessdata']) {
    stageDirectory(fs, path.join(fixturesRoot, name), '/' + name);
}
fs.writeFile('/versions.env', readFileSync(path.join(fixturesRoot, 'versions.env')));

process.exitCode = await dotnetInstance.runMain();

// Copy the in-VFS results.json back out to the real filesystem, now that the
// run actually wrote it - see the comment above on why this can't just be
// the app's own File.Create target path. Read unconditionally when a host
// path was requested: a missing file here (Program.cs failing before ever
// opening the stream) should surface as a clear ENOENT, not a silently
// missing artifact three steps later.
if (hostResultsPath) {
    writeFileSync(hostResultsPath, fs.readFile(resultsVfsPath));
}
