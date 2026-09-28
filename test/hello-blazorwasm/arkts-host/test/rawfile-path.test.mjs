#!/usr/bin/env node
// Unit test for the rawfile path validator of the ArkWeb host page (SEC-SCAN-3 S3-AW1).
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
const PREFIX = 'resources/rawfile/blazor/';

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
// names and the normalizing forms the browser may emit.
const LEGAL = [
  ['origin root -> app shell', '', PREFIX + 'index.html'],
  ['app shell', 'index.html', PREFIX + 'index.html'],
  ['framework asset', '_framework/blazor.webassembly.js', PREFIX + '_framework/blazor.webassembly.js'],
  ['encoded space', '_content/Lib/file%20name.js', PREFIX + '_content/Lib/file name.js'],
  ['SPA route (rawfile lookup may miss)', 'counter', PREFIX + 'counter'],
  ['dot segment normalized away', 'a/./b', PREFIX + 'a/b'],
  ['empty segment normalized away', 'a//b', PREFIX + 'a/b'],
  ['encoded letters', '%41%42.html', PREFIX + 'AB.html'],
  ['literal percent after one decode', '100%25.txt', PREFIX + '100%.txt'],
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

// Source pins: the regression contract that the validator stays wired into serveFile and the
// SEC-SCAN-3 headers stay on every served asset (S3-AW1 + S3-AW2).
const PINS = [
  ['validator wired into serveFile', 'resolveRawfilePath(path)'],
  ['rejection answers 404', 'return this.errorResponse(404);'],
  ['shell fallback uses the validated constant', 'resolved = INDEX_FILE;'],
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
