// Serves a published browser-wasm smoke-test app's wwwroot and drives it
// headlessly via Playwright, exiting 0/1 on whether its Program.cs's own
// "RESULT=PASS/FAIL" console line (see Program.cs) actually appeared and
// said PASS -- real OCR succeeded in a real browser, not just that the
// build/publish succeeded.
//
// Usage: node run-smoketest.mjs <path-to-published-wwwroot>
//
// COOP/COEP response headers, not a plain static file server: matches what
// the working WASM backlog plan spikes needed -- harmless for this
// non-threaded build specifically, but keeps this runner correct if a
// future multi-threaded (SharedArrayBuffer-requiring) build ever reuses it.
import { createServer } from 'node:http';
import { readFile, stat } from 'node:fs/promises';
import { join, extname } from 'node:path';
import { chromium } from 'playwright';

const wwwroot = process.argv[2];
if (!wwwroot) {
  console.error('Usage: node run-smoketest.mjs <path-to-published-wwwroot>');
  process.exit(2);
}

const PORT = 8934;
const CONTENT_TYPES = {
  '.html': 'text/html', '.js': 'text/javascript', '.mjs': 'text/javascript',
  '.wasm': 'application/wasm', '.json': 'application/json',
  '.png': 'image/png', '.dat': 'application/octet-stream',
  '.dll': 'application/octet-stream', '.blat': 'application/octet-stream',
  '.br': 'application/octet-stream', '.gz': 'application/octet-stream',
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

let resultLine = null;
const consoleLines = [];
page.on('console', (msg) => {
  const text = msg.text();
  consoleLines.push(text);
  console.log('[console]', text);
  if (text.startsWith('RESULT=')) resultLine = text;
});
page.on('pageerror', (err) => console.log('[pageerror]', err.message));

let errorUiVisible = false;
try {
  await page.goto(`http://localhost:${PORT}/index.html`, { waitUntil: 'load', timeout: 60000 });
  // No fixed sleep-and-hope: poll for the RESULT= line, which Program.cs
  // prints as its very last synchronous action before handing off to the
  // long-running Blazor host -- the real completion signal, not a guess at
  // how long the wasm runtime + OCR happens to take.
  const deadline = Date.now() + 60000;
  while (!resultLine && Date.now() < deadline) {
    await page.waitForTimeout(500);
  }

  // A RESULT=PASS console line alone isn't the real bar: Blazor's own
  // err:Tt wiring (blazor.webassembly.js) shows the "An unhandled error has
  // occurred" #blazor-error-ui banner on *any* native stderr write at all,
  // unconditionally, with no severity gating -- confirmed directly in a real
  // build's shipped JS, not assumed. Leptonica/Tesseract's own routine
  // diagnostic stderr output (this file's own console log already shows real
  // examples: "Error in pixReadMemTiff", "Estimating resolution as N") would
  // otherwise trigger that overlay on top of an app the OCR itself completed
  // successfully -- a real, user-visible regression a console-text-only
  // check would silently miss. Checked here, before the browser closes.
  errorUiVisible = await page.evaluate(() => {
    const el = document.querySelector('#blazor-error-ui');
    return !!el && getComputedStyle(el).display !== 'none';
  });
} finally {
  await browser.close();
  server.close();
}

if (!resultLine) {
  console.error('FAILURE: no RESULT= line appeared within the timeout.');
  process.exit(1);
}

console.log(resultLine);
if (!resultLine.startsWith('RESULT=PASS')) {
  console.error('FAILURE: smoke test reported failure.');
  process.exit(1);
}

if (errorUiVisible) {
  console.error('FAILURE: #blazor-error-ui is visible -- some native stderr write triggered it during a run that otherwise completed successfully.');
  process.exit(1);
}

console.log('SUCCESS');
process.exit(0);
