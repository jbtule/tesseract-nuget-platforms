// Serves a published browser-wasm UnitTestWasm's wwwroot and drives it headlessly via
// Playwright, exiting 0/1 on whether its Program.cs's own "DONE: N passed, M failed,
// K skipped (T events total)" console line (see Program.cs) actually appeared and reported
// zero failures -- the real Tesseract.Tests suite ran under wasm, for real, in a real
// browser, not a theoretical "it should work" claim.
//
// Usage: node run-unittest.mjs <path-to-published-wwwroot>
//
// COOP/COEP response headers, not a plain static file server: matches what the working
// WASM backlog plan spikes needed -- harmless for this non-threaded build specifically, but
// keeps this runner correct if a future multi-threaded (SharedArrayBuffer-requiring) build
// ever reuses it. Port 8936, distinct from smoketest-wasm's 8934: lets both run concurrently
// (e.g. in the same CI job) without a port collision.
import { createServer } from 'node:http';
import { readFile, stat } from 'node:fs/promises';
import { join, extname } from 'node:path';
import { chromium } from 'playwright';

const wwwroot = process.argv[2];
if (!wwwroot) {
  console.error('Usage: node run-unittest.mjs <path-to-published-wwwroot>');
  process.exit(2);
}

const PORT = 8936;
const CONTENT_TYPES = {
  '.html': 'text/html', '.js': 'text/javascript', '.mjs': 'text/javascript',
  '.wasm': 'application/wasm', '.json': 'application/json',
  '.png': 'image/png', '.jpg': 'image/jpeg', '.tif': 'image/tiff',
  '.txt': 'text/plain', '.uzn': 'text/plain', '.traineddata': 'application/octet-stream',
  '.ttf': 'font/ttf', '.env': 'text/plain',
  '.dat': 'application/octet-stream', '.dll': 'application/octet-stream',
  '.blat': 'application/octet-stream', '.br': 'application/octet-stream', '.gz': 'application/octet-stream',
};

const server = createServer(async (req, res) => {
  try {
    let urlPath = decodeURIComponent(new URL(req.url, 'http://localhost').pathname);
    if (urlPath === '/') urlPath = '/index.html';
    const filePath = join(wwwroot, urlPath);
    const st = await stat(filePath);
    if (!st.isFile()) throw new Error('not a file');
    const body = await readFile(filePath);
    res.setHeader('Cross-Origin-Opener-Policy', 'same-origin');
    res.setHeader('Cross-Origin-Embedder-Policy', 'require-corp');
    res.setHeader('Content-Type', CONTENT_TYPES[extname(filePath)] ?? 'application/octet-stream');
    res.writeHead(200);
    res.end(body);
  } catch {
    res.writeHead(404);
    res.end('not found');
  }
});

await new Promise((resolve) => server.listen(PORT, resolve));
console.log(`Serving ${wwwroot} on http://localhost:${PORT}/`);

const browser = await chromium.launch();
const page = await browser.newPage();

let doneLine = null;
page.on('console', (msg) => {
  const text = msg.text();
  console.log('[console]', text);
  if (text.startsWith('DONE:')) doneLine = text;
});
page.on('pageerror', (err) => console.log('[pageerror]', err.message));

try {
  await page.goto(`http://localhost:${PORT}/index.html`, { waitUntil: 'load', timeout: 60000 });
  // No fixed sleep-and-hope: poll for the DONE= line, which Program.cs prints as its very
  // last synchronous action before handing off to the long-running Blazor host -- the real
  // completion signal, not a guess at how long the wasm runtime + the whole test suite
  // happens to take. Generous timeout: this runs several hundred real tests, not one OCR call.
  const deadline = Date.now() + 180000;
  while (!doneLine && Date.now() < deadline) {
    await page.waitForTimeout(500);
  }
} finally {
  await browser.close();
  server.close();
}

if (!doneLine) {
  console.error('FAILURE: no DONE: line appeared within the timeout.');
  process.exit(1);
}

console.log(doneLine);
const failedMatch = doneLine.match(/(\d+) failed/);
const failedCount = failedMatch ? parseInt(failedMatch[1], 10) : NaN;
if (Number.isNaN(failedCount)) {
  console.error('FAILURE: could not parse a failed count out of the DONE: line.');
  process.exit(1);
}
if (failedCount > 0) {
  console.error(`FAILURE: ${failedCount} test(s) failed.`);
  process.exit(1);
}

console.log('SUCCESS');
process.exit(0);
