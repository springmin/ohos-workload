// Blazor WebAssembly hosting demo - self-contained variant.
//
// The published site is embedded under resources/rawfile/blazor and served to ArkWeb
// through onInterceptRequest (the pattern the in-product HybridWebView/BlazorWebView asset
// bridge uses), so the app needs no local HTTP server and no network permission.
//
// Request mapping: https://blazor.local/<path> -> rawfile blazor/<path>. Unknown paths fall
// back to index.html so client-side routing keeps working; the framework files come from
// _framework/ with the MIME types Blazor's boot script expects (application/wasm for the
// .wasm payloads).
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

  private errorResponse(code: number): WebResourceResponse {
    const response: WebResourceResponse = new WebResourceResponse();
    response.setResponseCode(code);
    response.setResponseMimeType('text/plain');
    response.setResponseEncoding('utf-8');
    response.setResponseData(code === 404 ? 'Not Found' : 'Bad Request');
    return response;
  }

  // https://blazor.local/<path>[?query][#fragment] -> rawfile blazor/<path>
  private serveFile(url: string): WebResourceResponse {
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
    let bytes: Uint8Array;
    try {
      bytes = manager.getRawFileContentSync(ROOT + path);
    } catch {
      // SPA fallback: a route without a matching rawfile renders the app shell.
      try {
        bytes = manager.getRawFileContentSync(ROOT + 'index.html');
        path = 'index.html';
      } catch {
        return this.errorResponse(404);
      }
    }

    const response: WebResourceResponse = new WebResourceResponse();
    response.setResponseCode(200);
    response.setResponseMimeType(mimeTypeOf(path));
    response.setResponseEncoding('utf-8');
    response.setResponseData(bytes.buffer as ArrayBuffer);
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
            return this.serveFile(url);
          } catch (error) {
            hilog.error(DOMAIN, TAG, 'intercept failed: %{public}s', JSON.stringify(error));
            return null;
          }
        })
        .onPageEnd(() => {
          hilog.info(DOMAIN, TAG, 'page loaded: %{public}s', ORIGIN);
        })
    }
    .width('100%')
    .height('100%')
  }
}
