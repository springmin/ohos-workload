// L8-PROBE popup page (scratch branch feat/l8-popup-probe): the child-window Web.
//
// Loaded by pages/Index.ets with Window.loadContentByName('l8probe-popup') into the window
// created by createSubWindowWithOptions. The main page created the WebviewController
// synchronously inside onWindowNew, bound it with ControllerHandler.setWebController and stashed
// it in the page-module bridge; this page reads that same object back when it builds its Web:
//   s1 src=''        - the engine is expected to deliver the popup document to the bound component;
//   s3 src=targetUrl - the page loads the target itself through the bound controller.
// (s2 about:blank + opener document.write fills the document through the window proxy, so the
// page needs no src either; the written document lives entirely in the opener's flow.)
// onWindowExit (page called window.close()) asks the main page to destroy the child window, so
// the probe also proves the cross-page callback direction.
import { webview } from '@kit.ArkWeb';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN = 0x0002;
const TAG = 'L8PROBE';

function l8popLog(message: string): void {
  hilog.info(DOMAIN, TAG, 'marker: %{public}s', message);
}

// The popup document served through the popup Web's onInterceptRequest for https://l8.probe/.
// It prints its own name/opener, answers opener postMessage with PONG and auto-closes after 7 s.
const POPUP_HTML: string = `<!DOCTYPE html>
<html><head><meta charset="utf-8"><title>L8-POPUP</title></head>
<body style="font-family:sans-serif">
<div id="hud" style="font-size:28px">L8 POPUP</div>
<script>
function L(m) { console.log('L8POP ' + m); }
function hud(t) { document.getElementById('hud').textContent = 'L8 POPUP ' + t; }
L('LOADED name=' + window.name + ' opener=' + (window.opener ? 'yes' : 'no') + ' search=' + location.search);
hud('name=' + window.name + ' ' + location.search);
window.addEventListener('message', function(e) {
  L('MSG ' + e.data);
  hud('GOT ' + e.data);
  try { if (window.opener) { window.opener.postMessage('PONG:' + e.data, '*'); L('PONG-SENT'); } }
  catch (err) { L('PONG-ERR ' + err); }
});
setTimeout(function() { L('AUTOCLOSE'); window.close(); }, 7000);
</script></body></html>`;

// Module-scope bridge shared by pages/Index.ets and this page (same UI instance, same ArkTS VM).
export class L8Bridge {
  private static closeHook: (() => void) | null = null;
  private static stashedController: webview.WebviewController | null = null;
  private static stashedUrl: string = '';
  private static stashedMode: string = '';

  static stash(controller: webview.WebviewController, url: string, mode: string): void {
    L8Bridge.stashedController = controller;
    L8Bridge.stashedUrl = url;
    L8Bridge.stashedMode = mode;
  }

  static stashedControllerOrNull(): webview.WebviewController | null {
    return L8Bridge.stashedController;
  }

  static stashedUrlValue(): string {
    return L8Bridge.stashedUrl;
  }

  static stashedModeValue(): string {
    return L8Bridge.stashedMode;
  }

  static setCloseHook(hook: () => void): void {
    L8Bridge.closeHook = hook;
  }

  static requestClose(): void {
    const hook = L8Bridge.closeHook;
    if (hook !== null) {
      hook();
    } else {
      l8popLog('close hook missing');
    }
  }
}

@Entry({ routeName: 'l8probe-popup' })
@Component
struct L8ProbePopup {
  private ownController: webview.WebviewController = new webview.WebviewController();
  private active: webview.WebviewController = new webview.WebviewController();
  private webSrc: string = '';
  @State hud: string = 'L8 popup';

  aboutToAppear(): void {
    const stashed = L8Bridge.stashedControllerOrNull();
    const mode = L8Bridge.stashedModeValue();
    if (stashed !== null) {
      this.active = stashed;
    } else {
      this.active = this.ownController;
    }
    this.webSrc = mode === 's3' ? L8Bridge.stashedUrlValue() : '';
    l8popLog(`popup uses ${stashed !== null ? 'stashed' : 'own'} controller mode=${mode} src=${this.webSrc}`);
  }

  private servePopup(event: OnInterceptRequestEvent): WebResourceResponse {
    try {
      const url: string = event.request.getRequestUrl();
      l8popLog(`popup intercept ${url}`);
      if (url.startsWith('https://l8.probe/')) {
        const response: WebResourceResponse = new WebResourceResponse();
        response.setResponseCode(200);
        response.setResponseMimeType('text/html');
        response.setResponseEncoding('utf-8');
        response.setResponseData(POPUP_HTML);
        return response;
      }
    } catch (interceptError) {
      l8popLog(`popup intercept failed: ${(interceptError as Error).message}`);
    }
    const notFound: WebResourceResponse = new WebResourceResponse();
    notFound.setResponseCode(404);
    notFound.setResponseMimeType('text/plain');
    notFound.setResponseEncoding('utf-8');
    notFound.setResponseData('not found');
    return notFound;
  }

  build() {
    Column() {
      Text(this.hud).fontSize(18)
      Web({ src: this.webSrc, controller: this.active })
        .multiWindowAccess(false)
        .domStorageAccess(true)
        .onControllerAttached(() => {
          l8popLog(`popup controller attached mode=${L8Bridge.stashedModeValue()}`);
          this.hud = `attached ${L8Bridge.stashedModeValue()}`;
        })
        .onInterceptRequest((event) => {
          return this.servePopup(event);
        })
        .onConsole((event) => {
          try {
            l8popLog(`page: ${event.message.getMessage()}`);
          } catch {
          }
          return false;
        })
        .onPageEnd((event) => {
          const url: string = event ? event.url : '';
          l8popLog(`popup page end ${url}`);
        })
        .onWindowExit(() => {
          l8popLog('popup onWindowExit (window.close)');
          L8Bridge.requestClose();
        })
        .onActivateContent(() => {
          l8popLog('popup onActivateContent (name reuse)');
        })
    }.width('100%').height('100%')
  }
}
