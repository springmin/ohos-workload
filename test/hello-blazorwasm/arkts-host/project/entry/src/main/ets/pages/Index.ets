// Blazor WebAssembly hosting demo - self-contained variant.
//
// The published site is embedded under resources/rawfile/blazor and served to ArkWeb
// through onInterceptRequest (the pattern the in-product HybridWebView/BlazorWebView asset
// bridge uses), so the app needs no local HTTP server and no network permission.
//
// Request mapping: https://blazor.local/<path> -> rawfile blazor/<path>. Unknown paths fall
// back to index.html so client-side routing keeps working; the framework files come from
// _framework/ with the MIME types Blazor's boot script expects (application/wasm for the
// .wasm payloads). When the request accepts br/gzip and the site ships the sibling
// .br/.gz file (a full publish does), the compressed variant is served with the matching
// Content-Encoding, exactly like a static web server would.
//
// Security: every request path is validated before it reaches the resource manager
// (resolveRawfilePath below: decoded-encoding, '..'/backslash/NUL/absolute rejection, and a
// final check that the normalized path still resolves under resources/rawfile/blazor/;
// violations are a bare 404). The validator judges the boundary spelling
// (resources/rawfile/blazor/<path>) but returns the rawfile-relative API path
// (blazor/<path>), which is what ResourceManager.getRawFileContentSync accepts. Served assets
// carry X-Content-Type-Options: nosniff, Vary: Accept-Encoding and Cache-Control: no-cache,
// and the HTML shell carries a minimal CSP (SEC-SCAN-3 S3-AW1/S3-AW2). The validator is
// extracted and unit-tested by test/rawfile-path.test.mjs.
//
// Diagnostic markers: the page reports BLZ_* console messages (BLZ_BOOT after window load,
// BLZ_RENDERED after the first Blazor render, BLZ_ERROR on failures) and they are forwarded
// to hilog under TAG, so a tester can check `hilog | grep BlazorWebHost` for a machine
// verdict. The MIME contract is observable too (WASM-MIME): the first .wasm response logs
// `wasm mime: ... -> application/wasm`, and Emscripten's streaming fallback warnings
// (`wasm streaming compile failed` / `falling back to ArrayBuffer`) are forwarded as
// `wasm fallback:` lines, so a streaming run shows the MIME line and no fallback line.
import { webview as web_webview } from '@kit.ArkWeb';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import type { resourceManager } from '@kit.LocalizationKit';

const DOMAIN = 0x0002;
const TAG = 'BlazorWebHost';
const ORIGIN = 'https://blazor.local/';
// Per-launch marker token (SEC-SCAN-3 S3-PRB2): the initial page URL carries it and every
// forwarded BLZ_* marker is stamped with it, so the tester-run probe can require a value that
// another process writing BLZ_BOOT into hilog cannot know. The probe's host-pid binding is the
// primary anti-forgery check; this token adds a second, independent one.
const BLZ_NONCE_QUERY = 'blz_nonce';
// Emscripten's wasm streaming fallback (dotnet.native.js): instantiateStreaming fails when the
// response does not carry application/wasm (or streaming is unavailable) and the runtime logs
// these two warnings before re-loading the payload through ArrayBuffer. Forwarding them makes
// the MIME contract a device-verifiable marker pair: `wasm mime:` present and no
// `wasm fallback:` line means the payload streamed with the right content type.
const WASM_FALLBACK_COMPILE = 'wasm streaming compile failed';
const WASM_FALLBACK_ARRAYBUFFER = 'falling back to ArrayBuffer';
// Minimal CSP for the served Blazor WASM shell. script-src keeps 'unsafe-inline' because the
// published index.html registers the BLZ_* window listeners inline and 'wasm-unsafe-eval'
// because the .NET WASM runtime starts from blazor.webassembly*.js (no 'unsafe-eval'). The
// other directives stay at 'self' (plus data: for inline images); object-src/frame-ancestors
// are off, and base-uri keeps the site's <base href="/"> same-origin.
const CONTENT_SECURITY_POLICY = "default-src 'self'; script-src 'self' 'wasm-unsafe-eval' 'unsafe-inline'; " +
  "style-src 'self' 'unsafe-inline'; img-src 'self' data:; font-src 'self'; connect-src 'self'; " +
  "object-src 'none'; frame-ancestors 'none'; base-uri 'self'";

// >>> rawfile-path (node-testable block; test/rawfile-path.test.mjs extracts it verbatim)
// Rawfile path validation for the onInterceptRequest server (SEC-SCAN-3 S3-AW1). The request
// path (origin, query and fragment already removed) is percent-decoded in bounded rounds, so
// every encoding variant of '..' ('%2e%2e' and its double-encoded form), a backslash ('%5c'),
// NUL ('%00') and an absolute path is judged on decoded text. '.' and empty segments are
// normalized away, '..' is rejected outright, and the result must still sit under
// resources/rawfile/blazor/ (the prefix check is the final belt-and-braces).
//
// Namespaces (FIX-BLZ-PATH): the check runs on the full boundary spelling
// resources/rawfile/blazor/<path>, but the value handed to the resource manager is the
// rawfile-relative API path blazor/<path> — getRawFileContentSync rejects the
// 'resources/rawfile/' prefix (every read failed on device when the SEC-SCAN-3 refactor
// returned the boundary spelling), while 'blazor/<path>' is what the pre-refactor host used.
const RAWFILE_PREFIX = 'resources/rawfile/blazor/';
const RAWFILE_API_DIR = 'blazor/';
const INDEX_FILE = RAWFILE_API_DIR + 'index.html';

function hasEscapeSequence(text: string): boolean {
  for (let i: number = 0; i + 2 < text.length; i++) {
    if (text.charAt(i) === '%') {
      const a: string = text.charAt(i + 1).toLowerCase();
      const b: string = text.charAt(i + 2).toLowerCase();
      const aHex: boolean = (a >= '0' && a <= '9') || (a >= 'a' && a <= 'f');
      const bHex: boolean = (b >= '0' && b <= '9') || (b >= 'a' && b <= 'f');
      if (aHex && bHex) {
        return true;
      }
    }
  }
  return false;
}

// Decodes while complete %XX escapes remain (at most three rounds: every realistic double
// encoding collapses by then). undefined = malformed escape somewhere along the way (fail
// closed); a trailing bare '%' or '%2' is not an escape and stays literal.
function decodePathFully(path: string): string | undefined {
  let current: string = path;
  for (let round: number = 0; round < 3; round++) {
    if (!hasEscapeSequence(current)) {
      return current;
    }
    let next: string;
    try {
      next = decodeURIComponent(current);
    } catch (error) {
      return undefined;
    }
    if (next === current) {
      return current;
    }
    current = next;
  }
  return hasEscapeSequence(current) ? undefined : current;
}

// Maps a request path to the rawfile-relative API asset path (blazor/<path>), or undefined
// when the request must be rejected. An empty path (the origin root) becomes the app shell.
// The security judgment is made on the boundary spelling
// (resources/rawfile/blazor/<path>); the returned value stays rawfile-relative so it can go
// straight to getRawFileContentSync (FIX-BLZ-PATH).
function resolveRawfilePath(path: string): string | undefined {
  const decoded: string | undefined = decodePathFully(path);
  if (decoded === undefined) {
    return undefined;
  }
  if (decoded.indexOf('\0') >= 0 || decoded.indexOf('\\') >= 0 || decoded.charAt(0) === '/') {
    return undefined;
  }
  const segments: string[] = decoded.split('/');
  const kept: string[] = [];
  for (let i: number = 0; i < segments.length; i++) {
    const segment: string = segments[i];
    if (segment.length === 0 || segment === '.') {
      continue;
    }
    if (segment === '..') {
      return undefined;
    }
    kept.push(segment);
  }
  if (kept.length === 0) {
    return INDEX_FILE;
  }
  const boundary: string = RAWFILE_PREFIX + kept.join('/');
  if (boundary.indexOf(RAWFILE_PREFIX) !== 0 || boundary.indexOf('/../') >= 0) {
    return undefined;
  }
  return RAWFILE_API_DIR + kept.join('/');
}
// <<< rawfile-path

function mimeTypeOf(path: string): string {
  const lower: string = path.toLowerCase();
  if (lower.endsWith('.html')) {
    return 'text/html';
  }
  if (lower.endsWith('.js') || lower.endsWith('.mjs')) {
    return 'text/javascript';
  }
  if (lower.endsWith('.css')) {
    return 'text/css';
  }
  if (lower.endsWith('.json') || lower.endsWith('.webmanifest')) {
    return 'application/json';
  }
  if (lower.endsWith('.wasm')) {
    return 'application/wasm';
  }
  if (lower.endsWith('.dat')) {
    return 'application/octet-stream';
  }
  if (lower.endsWith('.png')) {
    return 'image/png';
  }
  if (lower.endsWith('.svg')) {
    return 'image/svg+xml';
  }
  if (lower.endsWith('.ico')) {
    return 'image/x-icon';
  }
  if (lower.endsWith('.woff')) {
    return 'font/woff';
  }
  if (lower.endsWith('.woff2')) {
    return 'font/woff2';
  }
  if (lower.endsWith('.ttf')) {
    return 'font/ttf';
  }
  if (lower.endsWith('.txt') || lower.endsWith('.map')) {
    return 'text/plain';
  }
  return 'application/octet-stream';
}

// One served asset: the bytes to return plus the content coding already applied to them
// ('br', 'gz' or '' for the file as-is).
class ServedFile {
  bytes: Uint8Array | undefined = undefined;
  coding: string = '';

  constructor(bytes: Uint8Array | undefined, coding: string) {
    this.bytes = bytes;
    this.coding = coding;
  }
}

@Entry
@Component
struct Index {
  private controller: web_webview.WebviewController = new web_webview.WebviewController();
  private rawFiles: resourceManager.ResourceManager | undefined = undefined;
  private sessionNonce: string = '';
  // One-shot guard for the served-MIME evidence line (WASM-MIME); the first .wasm response logs
  // what the host declared, so the device run has a positive application/wasm marker.
  private wasmMimeLogged: boolean = false;

  // The token is created once per host page instance: a reload of the same page keeps it, a
  // fresh instance (relaunch) gets a new one. The probe binds the markers it reads in one
  // launch window to the token that launch announced.
  private nonceOrCreate(): string {
    if (this.sessionNonce.length === 0) {
      this.sessionNonce = util.generateRandomUUID(true);
    }
    return this.sessionNonce;
  }

  private resourceManagerOrUndefined(): resourceManager.ResourceManager | undefined {
    if (this.rawFiles === undefined) {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext | undefined;
      this.rawFiles = context?.resourceManager;
    }
    return this.rawFiles;
  }

  // path is the rawfile-relative API path (blazor/<...>), produced only by
  // resolveRawfilePath; getRawFileContentSync does not accept a resources/rawfile/ prefix
  // (FIX-BLZ-PATH).
  private readRawFile(manager: resourceManager.ResourceManager, path: string): Uint8Array | undefined {
    try {
      return manager.getRawFileContentSync(path);
    } catch {
      return undefined;
    }
  }

  // True when the request's Accept-Encoding carries the token (br / gzip).
  private acceptsEncoding(request: WebResourceRequest, coding: string): boolean {
    try {
      const headers: Header[] = request.getRequestHeader();
      for (let i = 0; i < headers.length; i++) {
        if (headers[i].headerKey.toLowerCase() === 'accept-encoding') {
          const parts: string[] = headers[i].headerValue.toLowerCase().split(',');
          for (let j = 0; j < parts.length; j++) {
            if (parts[j].split(';')[0].trim() === coding) {
              return true;
            }
          }
        }
      }
    } catch {
      // No header view means no compressed variant; the plain file is served.
    }
    return false;
  }

  private errorResponse(code: number): WebResourceResponse {
    const response: WebResourceResponse = new WebResourceResponse();
    response.setResponseCode(code);
    response.setResponseMimeType('text/plain');
    response.setResponseEncoding('utf-8');
    response.setResponseData(code === 404 ? 'Not Found' : 'Bad Request');
    return response;
  }

  // Reads <path>, preferring the .br/.gz sibling when the request accepts it.
  private readNegotiated(manager: resourceManager.ResourceManager, path: string,
                         acceptBr: boolean, acceptGzip: boolean): ServedFile {
    if (acceptBr) {
      const brBytes: Uint8Array | undefined = this.readRawFile(manager, path + '.br');
      if (brBytes !== undefined) {
        return new ServedFile(brBytes, 'br');
      }
    }
    if (acceptGzip) {
      const gzBytes: Uint8Array | undefined = this.readRawFile(manager, path + '.gz');
      if (gzBytes !== undefined) {
        return new ServedFile(gzBytes, 'gz');
      }
    }
    return new ServedFile(this.readRawFile(manager, path), '');
  }

  // Security headers for every served asset (SEC-SCAN-3 S3-AW2): nosniff keeps the declared
  // MIME type authoritative, Vary keeps caches from mixing the br/gzip and identity variants
  // of one URL, and the HTML shell additionally carries the minimal CSP above.
  private successHeaders(path: string, coding: string): Header[] {
    const headers: Header[] = [{
      headerKey: 'X-Content-Type-Options',
      headerValue: 'nosniff',
    }, {
      headerKey: 'Cache-Control',
      headerValue: 'no-cache',
    }, {
      headerKey: 'Vary',
      headerValue: 'Accept-Encoding',
    }];
    if (coding.length > 0) {
      headers.push({
        headerKey: 'Content-Encoding',
        headerValue: coding,
      });
    }
    if (path.toLowerCase().endsWith('.html')) {
      headers.push({
        headerKey: 'Content-Security-Policy',
        headerValue: CONTENT_SECURITY_POLICY,
      });
    }
    return headers;
  }

  // https://blazor.local/<path>[?query][#fragment] -> rawfile blazor/<path>. A path the
  // validator rejects (.., backslash, NUL, absolute, undecodable) is answered with a bare 404,
  // so the response never reveals which rule it hit.
  private serveFile(request: WebResourceRequest, url: string): WebResourceResponse {
    let path: string = url.startsWith(ORIGIN) ? url.substring(ORIGIN.length) : '';
    const query: number = path.indexOf('?');
    const fragment: number = path.indexOf('#');
    let cut: number = -1;
    if (query >= 0) {
      cut = query;
    }
    if (fragment >= 0 && (cut < 0 || fragment < cut)) {
      cut = fragment;
    }
    if (cut >= 0) {
      path = path.substring(0, cut);
    }

    let resolved: string | undefined = resolveRawfilePath(path);
    if (resolved === undefined) {
      return this.errorResponse(404);
    }

    const manager: resourceManager.ResourceManager | undefined = this.resourceManagerOrUndefined();
    if (manager === undefined) {
      hilog.error(DOMAIN, TAG, 'no resource manager for %{public}s', path);
      return this.errorResponse(500);
    }
    const acceptBr: boolean = this.acceptsEncoding(request, 'br');
    const acceptGzip: boolean = this.acceptsEncoding(request, 'gzip');

    let served: ServedFile = this.readNegotiated(manager, resolved, acceptBr, acceptGzip);
    if (served.bytes === undefined) {
      // SPA fallback: a route without a matching rawfile renders the app shell.
      resolved = INDEX_FILE;
      served = this.readNegotiated(manager, resolved, acceptBr, acceptGzip);
    }
    if (served.bytes === undefined) {
      return this.errorResponse(404);
    }

    const mime: string = mimeTypeOf(resolved);
    if (mime === 'application/wasm' && !this.wasmMimeLogged) {
      // WASM-MIME device evidence: one line per page serve proving the host declared
      // application/wasm for the payload (paired with the absence of `wasm fallback:` lines).
      this.wasmMimeLogged = true;
      hilog.info(DOMAIN, TAG, 'wasm mime: %{public}s -> %{public}s', resolved, mime);
    }
    const response: WebResourceResponse = new WebResourceResponse();
    response.setResponseCode(200);
    response.setResponseMimeType(mime);
    response.setResponseEncoding('utf-8');
    response.setResponseHeader(this.successHeaders(resolved, served.coding));
    response.setResponseData(served.bytes.buffer as ArrayBuffer);
    return response;
  }

  build() {
    Column() {
      Web({ src: ORIGIN + '?' + BLZ_NONCE_QUERY + '=' + this.nonceOrCreate(), controller: this.controller })
        .width('100%')
        .height('100%')
        .javaScriptAccess(true)
        .domStorageAccess(true)
        .onPageBegin(() => {
          // Announced before the page scripts run, so the tester-run probe can bind the
          // markers it reads later in the same dump to this launch's token.
          hilog.info(DOMAIN, TAG, 'session nonce: %{public}s', this.nonceOrCreate());
        })
        .onInterceptRequest((event) => {
          try {
            const url: string = event.request.getRequestUrl();
            if (!url.startsWith(ORIGIN)) {
              return null;
            }
            return this.serveFile(event.request, url);
          } catch (error) {
            hilog.error(DOMAIN, TAG, 'intercept failed: %{public}s', JSON.stringify(error));
            return null;
          }
        })
        .onConsole((event) => {
          // The site logs BLZ_* diagnostics; forward them to hilog as a machine-readable
          // pass/fail signal (`hilog | grep BlazorWebHost`). Returning false keeps the
          // browser console output as well.
          const message: string = event.message.getMessage();
          if (message.startsWith('BLZ_')) {
            // The marker keeps its BLZ_* prefix and gains the session token; the probe
            // requires both the prefix and the token it read from the announcement.
            hilog.info(DOMAIN, TAG, 'marker: %{public}s [blz:%{public}s]', message, this.sessionNonce);
          } else if (message.indexOf(WASM_FALLBACK_COMPILE) >= 0
            || message.indexOf(WASM_FALLBACK_ARRAYBUFFER) >= 0) {
            // WASM-MIME negative signal: the Emscripten streaming compile failed and the
            // runtime fell back to ArrayBuffer; the MIME contract is broken (or streaming is
            // unavailable). A healthy run carries no line here.
            hilog.warn(DOMAIN, TAG, 'wasm fallback: %{public}s [blz:%{public}s]', message, this.sessionNonce);
          }
          return false;
        })
        .onPageEnd(() => {
          hilog.info(DOMAIN, TAG, 'page loaded: %{public}s', ORIGIN);
        })
    }
    .width('100%')
    .height('100%')
  }
}
