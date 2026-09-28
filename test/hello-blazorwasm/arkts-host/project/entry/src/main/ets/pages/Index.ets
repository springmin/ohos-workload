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
// Diagnostic markers: the page reports BLZ_* console messages (BLZ_BOOT after window load,
// BLZ_RENDERED after the first Blazor render, BLZ_ERROR on failures) and they are forwarded
// to hilog under TAG, so a tester can check `hilog | grep BlazorWebHost` for a machine
// verdict.
import { webview as web_webview } from '@kit.ArkWeb';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { common } from '@kit.AbilityKit';
import type { resourceManager } from '@kit.LocalizationKit';

const DOMAIN = 0x0002;
const TAG = 'BlazorWebHost';
const ORIGIN = 'https://blazor.local/';
const ROOT = 'blazor/';

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

  private resourceManagerOrUndefined(): resourceManager.ResourceManager | undefined {
    if (this.rawFiles === undefined) {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext | undefined;
      this.rawFiles = context?.resourceManager;
    }
    return this.rawFiles;
  }

  private readRawFile(manager: resourceManager.ResourceManager, path: string): Uint8Array | undefined {
    try {
      return manager.getRawFileContentSync(ROOT + path);
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

  // https://blazor.local/<path>[?query][#fragment] -> rawfile blazor/<path>
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
    if (path.length === 0) {
      path = 'index.html';
    }

    const manager: resourceManager.ResourceManager | undefined = this.resourceManagerOrUndefined();
    if (manager === undefined) {
      hilog.error(DOMAIN, TAG, 'no resource manager for %{public}s', path);
      return this.errorResponse(500);
    }
    const acceptBr: boolean = this.acceptsEncoding(request, 'br');
    const acceptGzip: boolean = this.acceptsEncoding(request, 'gzip');

    let served: ServedFile = this.readNegotiated(manager, path, acceptBr, acceptGzip);
    if (served.bytes === undefined) {
      // SPA fallback: a route without a matching rawfile renders the app shell.
      path = 'index.html';
      served = this.readNegotiated(manager, path, acceptBr, acceptGzip);
    }
    if (served.bytes === undefined) {
      return this.errorResponse(404);
    }

    const response: WebResourceResponse = new WebResourceResponse();
    response.setResponseCode(200);
    response.setResponseMimeType(mimeTypeOf(path));
    response.setResponseEncoding('utf-8');
    if (served.coding.length > 0) {
      const headers: Header[] = [{
        headerKey: 'Content-Encoding',
        headerValue: served.coding,
      }, {
        headerKey: 'Cache-Control',
        headerValue: 'no-cache',
      }];
      response.setResponseHeader(headers);
    }
    response.setResponseData(served.bytes.buffer as ArrayBuffer);
    return response;
  }

  build() {
    Column() {
      Web({ src: ORIGIN, controller: this.controller })
        .width('100%')
        .height('100%')
        .javaScriptAccess(true)
        .domStorageAccess(true)
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
            hilog.info(DOMAIN, TAG, 'marker: %{public}s', message);
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
