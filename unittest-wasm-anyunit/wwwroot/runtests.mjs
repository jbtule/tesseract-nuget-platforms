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
import { readFileSync, readdirSync, statSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
// fixtures/ lands as a sibling of wwwroot/ in the build output (a plain <None>
// Link outside "wwwroot\..." isn't part of Blazor's own wwwroot bundling - it
// just copies relative to the output root), not inside wwwroot/ itself, so
// this needs to go up one level from where this script actually runs.
const fixturesRoot = path.join(__dirname, '..', 'fixtures');

const dotnetInstance = await dotnet
    .withApplicationArguments(...process.argv.slice(2))
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
