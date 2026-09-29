#!/usr/bin/env node
// Unit test for the rawfile path validator of the ArkWeb host page (SEC-SCAN-3 S3-AW1) and
// its FIX-BLZ-PATH namespace contract: validation on resources/rawfile/blazor/,
// resolution to the rawfile-relative API path blazor/<path>.
//
// The block between the `>>> rawfile-path` and `<<< rawfile-path` sentinels in
// project/entry/src/main/ets/pages/Index.ets is copied verbatim into a temp .ts file and
// imported, so the test always runs the shipped validator instead of a copy that can drift.
// Node's TypeScript type stripping (node >= 23.6) makes the .ts import work without a build.
// Run through test/run-tests.sh (it selects a working node) or `node rawfile-path.test.mjs`.
import { readFileSync, mkdtempSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const INDEX_ETS = join(HERE, '..', 'project', 'entry', 'src', 'main', 'ets', 'pages', 'Index.ets');
// FIX-BLZ-PATH: the validator judges the request against the resources/rawfile/blazor/
// boundary, but must return the rawfile-relative API namespace blazor/<path> that
// getRawFileContentSync accepts.
const API_PREFIX = 'blazor/';

if (!process.features.typescript) {
  console.error(`FAIL: this test needs node with TypeScript type stripping (>= 23.6), got ${process.version}`);
  process.exit(1);
}

const source = readFileSync(INDEX_ETS, 'utf8');
const match = source.match(/\/\/ >>> rawfile-path[^\n]*\n([\s\S]*?)\/\/ <<< rawfile-path\n/);
if (!match) {
  console.error(`FAIL: the rawfile-path block was not found in ${INDEX_ETS}`);
  process.exit(1);
}

const work = mkdtempSync(join(tmpdir(), 'blz-rawfile-'));
const modPath = join(work, 'rawfile-path.ts');
writeFileSync(modPath, `${match[1]}\nexport { hasEscapeSequence, decodePathFully, resolveRawfilePath };\n`);

let resolveRawfilePath;
try {
  ({ resolveRawfilePath } = await import(pathToFileURL(modPath).href));
} catch (error) {
  console.error(`FAIL: could not import the extracted validator: ${error.message}`);
  rmSync(work, { recursive: true, force: true });
  process.exit(1);
}

// Every entry must resolve to undefined (a bare 404 in the host): traversal in raw, percent
// and double-percent forms, backslashes, NUL, absolute paths and undecodable escapes.
const MALICIOUS = [
  ['dot-dot segment', '../secret.txt'],
  ['encoded dot-dot segment', '%2e%2e/secret.txt'],
  ['dot-dot + encoded slash', '..%2fsecret.txt'],
  ['double-encoded dot-dot', '%252e%252e/secret.txt'],
  ['dot-dot inside the route', 'a/../../b'],
  ['absolute path', '/etc/passwd'],
  ['encoded absolute path', '%2Fetc%2Fpasswd'],
  ['backslash traversal', '..\\secret.txt'],
  ['encoded backslash', '%5c..%5csecret.txt'],
  ['NUL byte', '%00index.html'],
  ['fully encoded traversal', '%2e%2e%2f%2e%2e%2fetc%2fpasswd'],
  ['malformed trailing escape', '%2e%'],
];

// Legal requests must keep working unchanged: the site assets, SPA routes, percent-encoded
// names and the normalizing forms the browser may emit. The expected values are the API
// namespace (blazor/...), never the resources/rawfile/ boundary spelling (FIX-BLZ-PATH).
const LEGAL = [
  ['origin root -> app shell', '', API_PREFIX + 'index.html'],
  ['app shell', 'index.html', API_PREFIX + 'index.html'],
  ['framework asset', '_framework/blazor.webassembly.js', API_PREFIX + '_framework/blazor.webassembly.js'],
  ['encoded space', '_content/Lib/file%20name.js', API_PREFIX + '_content/Lib/file name.js'],
  ['SPA route (rawfile lookup may miss)', 'counter', API_PREFIX + 'counter'],
  ['dot segment normalized away', 'a/./b', API_PREFIX + 'a/b'],
  ['empty segment normalized away', 'a//b', API_PREFIX + 'a/b'],
  ['encoded letters', '%41%42.html', API_PREFIX + 'AB.html'],
  ['literal percent after one decode', '100%25.txt', API_PREFIX + '100%.txt'],
];

let failures = 0;
let checks = 0;

function check(ok, label, detail) {
  checks++;
  if (ok) {
    console.log(`PASS  ${label}`);
  } else {
    failures++;
    console.error(`FAIL  ${label}: ${detail}`);
  }
}

for (const [label, input] of MALICIOUS) {
  const got = resolveRawfilePath(input);
  check(got === undefined, `rejects ${label} (${JSON.stringify(input)})`, `got ${JSON.stringify(got)}`);
}

for (const [label, input, want] of LEGAL) {
  const got = resolveRawfilePath(input);
  check(got === want, `resolves ${label} (${JSON.stringify(input)})`, `got ${JSON.stringify(got)}, want ${JSON.stringify(want)}`);
}

// FIX-BLZ-PATH namespace contract: every returned value must be the rawfile-relative API
// path (start with blazor/) and must never carry the resources/rawfile/ boundary spelling
// that getRawFileContentSync rejects.
for (const [label, input] of LEGAL) {
  const got = resolveRawfilePath(input);
  const namespaced = typeof got === 'string' && got.startsWith(API_PREFIX) && !got.includes('resources/rawfile/');
  check(namespaced, `API namespace for ${label} (${JSON.stringify(input)})`,
    `got ${JSON.stringify(got)}, want a string starting with ${JSON.stringify(API_PREFIX)} without "resources/rawfile/"`);
}
// The SPA fallback constant is the same API namespace.
check(String(resolveRawfilePath('')).startsWith(API_PREFIX), 'app shell fallback is in the API namespace',
  `got ${JSON.stringify(resolveRawfilePath(''))}`);

// Source pins: the regression contract that the validator stays wired into serveFile, keeps
// the resources/rawfile/blazor/ boundary judgment, returns the rawfile-relative API namespace
// (FIX-BLZ-PATH) and keeps the SEC-SCAN-3 headers on every served asset (S3-AW1 + S3-AW2).
const PINS = [
  ['validator wired into serveFile', 'resolveRawfilePath(path)'],
  ['rejection answers 404', 'return this.errorResponse(404);'],
  ['shell fallback uses the validated constant', 'resolved = INDEX_FILE;'],
  ['boundary check stays on resources/rawfile/blazor/', 'boundary.indexOf(RAWFILE_PREFIX) !== 0'],
  ['validator returns the API namespace', "return RAWFILE_API_DIR + kept.join('/')"],
  ['API namespace is the rawfile root', "const RAWFILE_API_DIR = 'blazor/'"],
  ['API shell constant', 'const INDEX_FILE = RAWFILE_API_DIR +'],
  ['rawfile read uses the validated path verbatim', 'return manager.getRawFileContentSync(path);'],
  ['nosniff header', "headerKey: 'X-Content-Type-Options'"],
  ['CSP header', "headerKey: 'Content-Security-Policy'"],
  ['CSP minimal baseline', "default-src 'self'"],
  ['Vary header', "headerKey: 'Vary'"],
];
for (const [label, needle] of PINS) {
  check(source.includes(needle), `source pin: ${label}`, `missing ${JSON.stringify(needle)} in ${INDEX_ETS}`);
}

rmSync(work, { recursive: true, force: true });

console.log(`rawfile-path: ${checks} checks, ${failures} failure(s)`);
process.exit(failures === 0 ? 0 : 1);
