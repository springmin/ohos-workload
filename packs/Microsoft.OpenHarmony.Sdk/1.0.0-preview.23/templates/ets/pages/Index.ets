// L8-PROBE main page (scratch branch feat/l8-popup-probe): the opener Web.
//
// window.open -> onWindowNew -> ControllerHandler.setWebController -> createSubWindowWithOptions
// -> pages/SubWindow popup. Scenario chosen by the targetUrl query:
//   s1 sync bind + URL target (engine delivers the popup document to the bound controller);
//   s2 sync bind + about:blank written by the opener through the window proxy (official sample);
//   s3 sync bind + the popup page loads targetUrl itself with the bound controller;
//   null setWebController(null) - honest reject, the opener must stay alive;
//   none no setWebController call at all - the documented renderer block control (runs last).
// The controller is created and bound SYNCHRONOUSLY inside onWindowNew (the official CustomDialog
// ordering) and handed to the popup page through the page-module bridge; the window and the page
// are created afterwards. Earlier rounds on this branch: the async bind (popup-created controller
// published after attach) did not deliver content and window.open returned null; the window
// LocalStorage did not reach the popup page at all.
import { webview } from '@kit.ArkWeb';
import { window } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { L8Bridge } from './SubWindow';

const DOMAIN = 0x0002;
const TAG = 'L8PROBE';
const POPUP_ROUTE: string = 'l8probe-popup';
const POPUP_NAME: string = 'l8_probe_popup';
const PROBE_ORIGIN: string = 'https://l8.probe/';

function l8log(message: string): void {
  hilog.info(DOMAIN, TAG, 'marker: %{public}s', message);
}

// The opener document. Timed sequence: s1 at 2.5 s, s2 (about:blank write) at 12 s, s3 at 22 s,
// null reject at 32 s, none (blocking control) at 38 s. A heartbeat prints every 500 ms so a
// blocked renderer is visible as a stopped heartbeat.
const MAIN_HTML: string = `<!DOCTYPE html>
<html><head><meta charset="utf-8"><title>L8-MAIN</title></head>
<body style="font-family:sans-serif">
<div id="hud" style="font-size:28px">L8 MAIN READY</div>
<script>
var beats = 0;
function L(m) { console.log('L8 ' + m); }
function hud(t) { document.getElementById('hud').textContent = 'L8 MAIN ' + t; }
function hb() { beats++; L('HB ' + beats); setTimeout(hb, 500); }
function ping(w, mode) {
  setTimeout(function() {
    try { w.postMessage('PING-' + mode, '*'); L('PING-SENT ' + mode); }
    catch (e) { L('PING-ERR ' + mode + ' ' + e); }
  }, 2000);
}
window.addEventListener('message', function(e) { L('MSG-FROM-POPUP ' + e.data); hud('GOT ' + e.data); });
function openMode(mode) {
  L('OPEN ' + mode);
  var w = window.open('https://l8.probe/popup.html?mode=' + mode, 'l8pop_' + mode);
  if (w) { L('OPEN-RETURN ' + mode + ' closed=' + w.closed); ping(w, mode); }
  else { L('OPEN-RETURN ' + mode + ' null'); }
}
var WRITE_HTML = '<html><head><meta charset="utf-8"><title>L8-WRITE</title></head><body style="font-family:sans-serif">' +
  '<div id="hud" style="font-size:28px">L8 POPUP WRITE</div>' +
  '<script>function L(m){console.log("L8POPW "+m);} L("LOADED name="+window.name); ' +
  'window.addEventListener("message", function(e){ L("MSG "+e.data); document.getElementById("hud").textContent="GOT "+e.data; ' +
  'try{ if(window.opener){window.opener.postMessage("PONGW:"+e.data,"*"); L("PONGW-SENT");} }catch(err){L("ERR "+err);} }); ' +
  'setTimeout(function(){L("AUTOCLOSE");window.close();},6000);<\\/script></body></html>';
function openWrite() {
  L('OPEN s2');
  var w = window.open('about:blank', 'l8pop_s2');
  if (w) {
    L('OPEN-RETURN s2 closed=' + w.closed);
    try { w.document.write(WRITE_HTML); w.document.close(); L('WRITE s2 done'); }
    catch (e) { L('WRITE-ERR s2 ' + e); }
    ping(w, 's2');
  } else { L('OPEN-RETURN s2 null'); }
}
setTimeout(function() { L('STEP s1'); openMode('s1'); }, 2500);
setTimeout(function() { L('STEP s1-repeat'); openMode('s1'); }, 6000);
setTimeout(function() { L('STEP s2'); openWrite(); }, 14000);
setTimeout(function() { L('STEP s3'); openMode('s3'); }, 24000);
setTimeout(function() { L('STEP null'); openMode('null'); }, 34000);
setTimeout(function() { L('STEP none'); openMode('none'); L('CONTROL-OPEN-RETURNED'); }, 40000);
hb();
</script></body></html>`;

@Entry
@Component
struct Index {
  private controller: webview.WebviewController = new webview.WebviewController();
  private mainWindow: window.Window | null = null;
  private popupWindow: window.Window | null = null;
  @State webOverlaysMounted: boolean = false;
  @State hud: string = 'L8 main';
  @State popupOpen: boolean = false;

  private logInfo(message: string): void {
    l8log(message);
  }

  aboutToAppear(): void {
    this.mountProbe();
    L8Bridge.setCloseHook((): void => {
      this.closePopup('popup-request');
    });
  }

  private mountProbe(): void {
    if (!this.webOverlaysMounted) {
      this.webOverlaysMounted = true;
      this.logInfo('[maui] web overlays mounted on first use');
    }
  }

  private hostContext(): common.UIAbilityContext {
    return this.getUIContext().getHostContext() as common.UIAbilityContext;
  }

  private async resolveMainWindow(): Promise<window.Window> {
    if (this.mainWindow !== null) {
      return this.mainWindow;
    }
    const main = await window.getLastWindow(this.hostContext());
    this.mainWindow = main;
    return main;
  }

  private modeOf(url: string): string {
    if (url.startsWith('about:blank')) {
      // s2: the opener opens about:blank and writes the document through the window proxy.
      return 's2';
    }
    const key: string = 'mode=';
    const at: number = url.indexOf(key);
    if (at < 0) {
      return 'unknown';
    }
    let mode: string = url.substring(at + key.length);
    const amp: number = mode.indexOf('&');
    if (amp >= 0) {
      mode = mode.substring(0, amp);
    }
    return mode;
  }

  private onWindowNew(event: OnWindowNewEvent): void {
    const targetUrl: string = event.targetUrl;
    const mode: string = this.modeOf(targetUrl);
    this.logInfo(`onWindowNew url=${targetUrl} mode=${mode} alert=${event.isAlert} user=${event.isUserTrigger}`);
    this.hud = `onWindowNew ${mode}`;
    if (mode === 'none') {
      this.logInfo('control: no setWebController call (expect renderer block)');
      return;
    }
    if (mode === 'null') {
      try {
        event.handler.setWebController(null as ESObject as webview.WebviewController);
        this.logInfo('reject: setWebController(null) done');
      } catch (rejectError) {
        this.logInfo(`reject: setWebController(null) failed: ${(rejectError as Error).message}`);
      }
      return;
    }
    if (mode === 's1' || mode === 's2' || mode === 's3') {
      // Synchronous bind: the controller is created and handed to the handler before any await,
      // exactly like the official same-page CustomDialog sample; the popup page reads the same
      // object from the module bridge when it builds its Web component.
      const popController = new webview.WebviewController();
      L8Bridge.stash(popController, targetUrl, mode);
      try {
        event.handler.setWebController(popController);
        this.logInfo(`sync setWebController(${mode}) done`);
      } catch (bindError) {
        this.logInfo(`sync setWebController(${mode}) failed: ${(bindError as Error).message}`);
      }
      this.openPopup(mode).catch((openError: Error): void => {
        this.logInfo(`popup open failed: ${openError.message}`);
      });
      return;
    }
    this.logInfo(`unknown mode ${mode}: rejecting with null`);
    try {
      event.handler.setWebController(null as ESObject as webview.WebviewController);
    } catch (rejectError) {
      this.logInfo(`unknown reject failed: ${(rejectError as Error).message}`);
    }
  }

  private async openPopup(mode: string): Promise<void> {
    try {
      // A previous child may still exist when an earlier scenario failed; one window name can
      // only be created once, so destroy it first.
      if (this.popupWindow !== null) {
        const previous = this.popupWindow;
        this.popupWindow = null;
        try {
          await previous.destroyWindow();
          this.logInfo('previous child destroyed');
        } catch (previousError) {
          this.logInfo(`previous child destroy failed: ${(previousError as Error).message}`);
        }
      }
      const main = await this.resolveMainWindow();
      const options: window.SubWindowOptions = {
        title: 'L8 POPUP',
        decorEnabled: false,
        windowRect: { left: 420, top: 260, width: 900, height: 700 },
      };
      const child = await main.createSubWindowWithOptions(POPUP_NAME, options);
      const childId: number = child.getWindowProperties().id;
      this.popupWindow = child;
      this.popupOpen = true;
      this.logInfo(`subwindow created id=${childId} mode=${mode}`);
      child.on('windowEvent', (evt: window.WindowEventType): void => {
        this.logInfo(`subwindow event ${evt} id=${childId}`);
        if (evt === window.WindowEventType.WINDOW_DESTROYED) {
          this.popupOpen = false;
          this.popupWindow = null;
        }
      });
      try {
        await child.loadContentByName(POPUP_ROUTE);
        this.logInfo('popup page loaded');
      } catch (namedRouteError) {
        this.logInfo(`named route failed, setUIContent fallback: ${(namedRouteError as Error).message}`);
        await child.setUIContent('pages/SubWindow');
      }
      await child.showWindow();
      this.logInfo(`subwindow shown id=${childId}`);
    } catch (openError) {
      this.logInfo(`open popup error: ${(openError as Error).message}`);
    }
  }

  private closePopup(source: string): void {
    const child = this.popupWindow;
    if (child === null) {
      this.logInfo(`close ${source}: no child`);
      return;
    }
    this.logInfo(`close ${source}: destroying`);
    child.destroyWindow().then((): void => {
      this.logInfo('child destroyed');
    }).catch((destroyError: Error): void => {
      this.logInfo(`child destroy failed: ${destroyError.message}`);
    });
  }

  @Builder
  probeWeb(): void {
    Web({ src: '', controller: this.controller })
      .domStorageAccess(true)
      .javaScriptAccess(true)
      .multiWindowAccess(true)
      .allowWindowOpenMethod(true)
      .onControllerAttached(() => {
        try {
          this.controller.loadData(MAIN_HTML, 'text/html', 'UTF-8', PROBE_ORIGIN);
          this.logInfo('main page loadData');
        } catch (loadError) {
          this.logInfo(`main loadData failed: ${(loadError as Error).message}`);
        }
      })
      .onConsole((event) => {
        try {
          this.logInfo(`page: ${event.message.getMessage()}`);
        } catch {
        }
        return false;
      })
      .onWindowNew((event) => {
        this.onWindowNew(event);
      })
  }

  build() {
    Stack() {
      if (this.webOverlaysMounted) {
        this.probeWeb()
      }
      Column() {
        Text(this.hud).fontSize(20).fontColor('#FF303030')
        if (this.popupOpen) {
          Text('popup open').fontSize(16).fontColor('#FFB03030')
        }
      }.alignItems(HorizontalAlign.Start).position({ x: 12, y: 12 })
    }
    .width('100%').height('100%')
  }
}
