// ArkUI page hosting native (.NET-rendered) content.
//
// Compiled by the ArkTS toolchain (scripts/build-arkts-shell.sh -> dist/ets/modules.abc)
// and packaged with -p:OpenHarmonyUIPage=pages/Index -p:OpenHarmonyArktsModulesAbc=...
//
// The XComponent (surface type) is bound to libopenharmonyhost.so: the framework delivers
// its OHNativeWindow* through the native XComponent callbacks, which the host forwards to
// the managed app (Microsoft.OpenHarmony.Hosting.OpenHarmonyBridge.SurfaceChanged) as the
// rendering target for Skia/MAUI. The ContentSlot next to it hosts native ArkUI nodes that
// managed code attaches through OpenHarmonyBridge.NodeContent.
import { NodeContent } from '@ohos.arkui.node';
import abilityAccessCtrl, { Permissions } from '@ohos.abilityAccessCtrl';
import cameraPicker from '@ohos.multimedia.cameraPicker';
import camera from '@ohos.multimedia.camera';
import { batteryInfo, BusinessError, commonEventManager, power } from '@kit.BasicServicesKit';
import { calendarManager } from '@kit.CalendarKit';
import { access, connection } from '@kit.ConnectivityKit';
import { contact } from '@kit.ContactsKit';
import common from '@ohos.app.ability.common';
import display from '@ohos.display';
import print from '@ohos.print';
import Want from '@ohos.app.ability.Want';
import wantConstant from '@ohos.app.ability.wantConstant';
import fileIo from '@ohos.file.fs';
import notificationManager from '@ohos.notificationManager';
import host from 'libopenharmonyhost.so';
import picker from '@ohos.file.picker';
import fs from '@ohos.file.fs';
import util from '@ohos.util';
import web_webview from '@ohos.web.webview';
import window from '@ohos.window';

// Menu bridge: the managed side publishes the current page's menu bars (MenuBarItem/MenuFlyout)
// as a flat table through the host. registerMenuChangedSink fires after every commit - including
// the empty table that hides the menu - and the table is pulled back with menuCount/menuItem.
// The rows are rendered by an ArkUI bindMenu below and a tap goes back to the managed item
// through host.notifyMenuAction(index).
interface HostMenuItem {
  text: string;
  enabled: boolean;
}

// HybridWebView asset bridge: the managed handler registers the extracted app payload
// directory (base), the hybrid root (HybridRoot, e.g. "wwwroot") and the default file
// (DefaultFile, e.g. "index.html"). App-origin requests (https://0.0.0.1/ - the MAUI hybrid
// origin) are answered from <base>/<root>/<path>; the framework bootstrap script
// (_framework/hybridwebview.js, extracted by the managed handler next to the payload) is
// served from <base>/_framework/hybridwebview.js. Everything else is not intercepted.
interface HybridAssetsConfig {
  base: string;
  root: string;
  defaultFile: string;
}

// BlazorWebView asset bridge (milestone 3): the managed handler registers the app payload
// directory (base), the content root (root, normally "wwwroot"), the default file
// (defaultFile, normally "index.html") and the Blazor origin (BlazorWebViewHandler.AppOrigin,
// https://0.0.0.0/). App-origin requests are answered from <base>/<root>/<path> - the same
// <base>/<root>/... convention the hybrid bridge uses for https://0.0.0.1/, except that
// _framework/blazor.webview.js is an ordinary file below the content root (the pack targets
// stage it there), not a special case next to the payload. The page-end bootstrap below
// installs the callback form of window.external.receiveMessage, publishes
// window.__dispatchMessageCallback and calls Blazor.start().
interface BlazorAssetsConfig {
  origin: string;
  base: string;
  root: string;
  defaultFile: string;
}

// JS -> .NET invocation payload the stock hybridwebview.js POSTs to __hwvInvokeDotNet:
// { "MethodName": "...", "ParamValues": ["<json>", ...] }.
interface HybridInvokeRequest {
  MethodName?: string;
  ParamValues?: string[];
}

// Error payload completed into a delayed __hwvInvokeDotNet response; the JavaScript bridge
// checks IsError and throws an Error carrying ErrorMessage.
interface HybridInvokeErrorResult {
  IsError: boolean;
  ErrorMessage: string;
}

// A pending invocation whose intercepted response is held open with setResponseIsReady(false)
// until the managed handler answers (or the fallback timeout fires).
interface HybridPendingInvoke {
  response: WebResourceResponse;
  timer: number;
}

@Entry
@Component
struct Index {
  private content: NodeContent = new NodeContent();

  @State inputText: string = '';
  @State webVisible: boolean = false;
  @State menuItems: HostMenuItem[] = [];
  // HybridWebView asset bridge state (registered by the managed handler; empty -> no
  // interception, so the regular WebView flows are never touched).
  private hybridBase: string = '';
  private hybridRoot: string = '';
  private hybridDefaultFile: string = '';
  private hybridRegistered: boolean = false;
  // MAUI's hybrid origin: HybridWebViewHandler.AppOrigin (https://0.0.0.1/).
  private hybridOrigin: string = 'https://0.0.0.1/';
  // Blazor asset bridge state (registered by the managed handler; empty -> no interception of
  // the Blazor origin, so hybrid pages are never touched). The origin always carries a trailing
  // '/' so the root document and its default file can be recognized textually.
  private blazorBase: string = '';
  private blazorRoot: string = '';
  private blazorDefaultFile: string = '';
  private blazorRegistered: boolean = false;
  // MAUI's Blazor origin: BlazorWebViewHandler.AppOrigin (https://0.0.0.0/).
  private blazorOrigin: string = 'https://0.0.0.0/';
  // One bootstrap per loaded document: reset in onPageBegin, so a navigation/reload runs the
  // sequence again while repeated onPageEnd callbacks for the same document do not.
  private blazorBootstrapped: boolean = false;
  // JS -> .NET invocation state: the intercepted __hwvInvokeDotNet responses held open until
  // the managed handler answers through host.registerHybridInvokeResultSink.
  private hybridInvokeSeq: number = 0;
  private hybridInvokes: Map<number, HybridPendingInvoke> = new Map();
  // Last-resort timeout so a lost invocation rejects the fetch instead of hanging it; the
  // managed handler answers with its own error payload after 10 s.
  private hybridInvokeTimeoutMs: number = 15000;
  // JavaScript bridge: set once the dotnetHost proxy was registered on the attached controller.
  private dotNetHostRegistered: boolean = false;
  // App theme: 'colorMode' is an ArkUI environment property that the framework keeps in
  // AppStorage and refreshes when the device switches between light and dark. The watch
  // forwards every change to the managed side through host.notifyTheme(isDark).
  @StorageProp('colorMode') @Watch('onColorModeChanged') colorMode: ColorMode = ColorMode.LIGHT;
  // Battery/DeviceDisplay (Essentials): the last batteryInfo/power snapshot is pushed through
  // host.notifyBattery on the battery common events, the display snapshot through
  // host.notifyDisplay on display.on('change'). Registered once per page.
  private batteryEventsRegistered: boolean = false;
  private displayChangeRegistered: boolean = false;
  // Bluetooth discovery: address -> last known name, from bluetoothDeviceFind. Cleared when a
  // new discovery starts and served to the managed side through op 4.
  private discoveredBluetooth: Map<string, string> = new Map();
  private bluetoothDeviceRegistered: boolean = false;
  private webController: web_webview.WebviewController = new web_webview.WebviewController();
  private controller: TextInputController = new TextInputController();
  // Flashlight (Camera Kit torch): the camera manager is created on first use and cached. The
  // host asks synchronously and consumes the sink's boolean answer, so the torch call itself
  // must stay synchronous (setTorchMode is).
  private flashlightManager: camera.CameraManager | undefined = undefined;

  // Forwards the current device colour mode (1 = dark, 0 = light) to the managed app.
  private reportTheme(): void {
    try {
      const mode: ColorMode | undefined = AppStorage.get<ColorMode>('colorMode');
      host.notifyTheme(mode === ColorMode.DARK ? 1 : 0);
    } catch (themeError) {
      // A host library without the theme export leaves the managed default in place.
    }
  }

  private onColorModeChanged(): void {
    this.reportTheme();
  }

  // Battery (Essentials): batteryInfo is a Basic Services Kit namespace of live constants and
  // power.getPowerMode() reports the device power mode. The raw values travel as one tab
  // separated payload ("soc\tchargeState\tpluggedType\tpresent\tpowerMode"); the managed
  // OpenHarmonyBattery maps them to the MAUI enums. Best effort: a host library without the
  // export leaves the managed defaults in place.
  private reportBattery(): void {
    try {
      const present: number = batteryInfo.isBatteryPresent ? 1 : 0;
      const payload: string = `${batteryInfo.batterySOC}\t${batteryInfo.chargingStatus}\t${batteryInfo.pluggedType}\t${present}\t${power.getPowerMode()}`;
      host.notifyBattery(payload);
    } catch (batteryError) {
      // The managed side keeps its Unknown defaults.
    }
  }

  // Display (Essentials): getDefaultDisplaySync returns the current display; the managed
  // OpenHarmonyDeviceDisplay turns "width\theight\tdensityDPI\trotation\trefreshRate\torientation"
  // into DisplayInfo (width/height px, density = densityDPI / 160).
  private reportDisplay(): void {
    try {
      const info = display.getDefaultDisplaySync();
      const payload: string = `${info.width}\t${info.height}\t${info.densityDPI}\t${info.rotation}\t${info.refreshRate}\t${info.orientation}`;
      host.notifyDisplay(payload);
    } catch (displayError) {
      // The managed side keeps its empty display info.
    }
  }

  // Battery changes arrive as common events (the platform publishes BATTERY_CHANGED on any
  // level/charging change, plus CHARGING/DISCHARGING/POWER_SAVE_MODE_CHANGED). Subscription is
  // best effort: a rejected subscription leaves the startup snapshot as the last value.
  private subscribeBatteryEvents(): void {
    if (this.batteryEventsRegistered) {
      return;
    }
    try {
      const subscriber = commonEventManager.createSubscriberSync({
        events: [
          commonEventManager.Support.COMMON_EVENT_BATTERY_CHANGED,
          commonEventManager.Support.COMMON_EVENT_CHARGING,
          commonEventManager.Support.COMMON_EVENT_DISCHARGING,
          commonEventManager.Support.COMMON_EVENT_POWER_SAVE_MODE_CHANGED,
        ],
      });
      commonEventManager.subscribe(subscriber, (subscribeError: BusinessError, event: commonEventManager.CommonEventData): void => {
        if (!subscribeError) {
          this.reportBattery();
        }
      });
      this.batteryEventsRegistered = true;
    } catch (batteryEventError) {
      console.error(`[maui] battery events unavailable: ${(batteryEventError as Error).message}`);
    }
  }

  // Display changes (rotation, size, refresh rate) arrive through display.on('change'); the
  // callback argument is the display id, the snapshot itself is re-read synchronously.
  private subscribeDisplayChange(): void {
    if (this.displayChangeRegistered) {
      return;
    }
    try {
      display.on('change', (displayId: number): void => {
        this.reportDisplay();
      });
      this.displayChangeRegistered = true;
    } catch (displayEventError) {
      console.error(`[maui] display change events unavailable: ${(displayEventError as Error).message}`);
    }
  }

  // Reads the host's current menu table into @State (empty when the sink is unavailable).
  private pullMenu(): void {
    try {
      const count: number = host.menuCount() as number;
      const items: HostMenuItem[] = [];
      for (let i = 0; i < count; i++) {
        items.push(host.menuItem(i) as HostMenuItem);
      }
      this.menuItems = items;
    } catch (menuError) {
      this.menuItems = [];
    }
  }

  // Maps the table to ArkUI menu elements; the managed enabled flag is carried over so ArkUI
  // greys out disabled rows and does not run their action.
  private buildMenuElements(): MenuElement[] {
    const elements: MenuElement[] = [];
    for (let i = 0; i < this.menuItems.length; i++) {
      const index: number = i;
      const item: HostMenuItem = this.menuItems[i];
      const element: MenuElement = {
        value: item.text,
        enabled: item.enabled,
        action: (): void => {
          host.notifyMenuAction(index);
        }
      };
      elements.push(element);
    }
    return elements;
  }

  // JavaScript bridge: registers the dotnetHost proxy that page scripts call to reach the
  // managed side. registerJavaScriptProxy needs the controller attached to the Web component
  // (BusinessError 17100001 otherwise), so onControllerAttached calls this.
  private registerDotNetHost(): void {
    if (this.dotNetHostRegistered) {
      return;
    }
    try {
      this.webController.registerJavaScriptProxy({
        postMessage: (payload: string): void => {
          host.notifyJsMessage(payload);
        }
      }, 'dotnetHost', ['postMessage']);
      this.dotNetHostRegistered = true;
    } catch (proxyError) {
      console.error(`[maui] dotnetHost proxy registration failed: ${(proxyError as Error).message}`);
    }
  }

  // Registered proxies appear on the next page load, so the documented window.__ohosDotNet
  // alias and the window.external compatibility layer are (re)published after every load
  // (best effort; a page that cannot run the script still keeps the dotnetHost global
  // provided by the proxy registration).
  //
  // window.external is the channel the stock hybridwebview.js and the Blazor boot script
  // speak:
  //   sendMessage(payload)    page -> host; forwarded to the dotnetHost proxy, whose
  //                           postMessage implementation is the existing
  //                           host.notifyJsMessage sink (__RawMessage|... and the
  //                           __InvokeJavaScript* records keep their stock handling).
  //   receiveMessage(payload) host -> page; the managed HybridWebView.SendRawMessage already
  //                           calls window.external.receiveMessage(json) and falls back to
  //                           the HybridWebViewMessageReceived event, so the shim raises that
  //                           same event with { detail: { message } } (the stock
  //                           iOS/MacCatalyst script's shape).
  // Existing members are never replaced, so a page script that installed its own
  // window.external (or its own receiveMessage) keeps it, and pages that use
  // dotnetHost.postMessage directly keep working unchanged.
  private injectPageBridge(): void {
    try {
      this.webController.runJavaScript(
        `(function () {
          var target = window.dotnetHost || window.__ohosDotNet;
          window.__ohosDotNet = target;
          var external = window.external;
          if (!external || (typeof external !== 'object' && typeof external !== 'function')) {
            external = {};
            window.external = external;
          }
          if (typeof external.sendMessage !== 'function') {
            external.sendMessage = function (payload) {
              try {
                var proxy = window.dotnetHost || window.__ohosDotNet;
                if (proxy && typeof proxy.postMessage === 'function') {
                  proxy.postMessage(payload);
                }
              } catch (sendError) {
                // The proxy is unavailable; the page keeps running without the bridge.
              }
            };
          }
          if (typeof external.receiveMessage !== 'function') {
            external.receiveMessage = function (payload) {
              try {
                window.dispatchEvent(new CustomEvent('HybridWebViewMessageReceived', { detail: { message: payload } }));
              } catch (receiveError) {
                // A page without CustomEvent support stays without host delivery.
              }
            };
          }
        })();`,
        () => {
          // The bridge is best-effort; an error leaves the page with dotnetHost only.
        });
    } catch (bridgeError) {
      // A page that rejects the injection script must not take the app down.
    }
  }

  // True when the loaded document is the Blazor root: the origin itself or the origin plus the
  // registered default host file. SPA navigations are same-document and do not re-trigger this.
  private isBlazorRootDocument(pageUrl: string): boolean {
    let url: string = pageUrl;
    const query: number = url.indexOf('?');
    if (query >= 0) {
      url = url.substring(0, query);
    }
    const fragment: number = url.indexOf('#');
    if (fragment >= 0) {
      url = url.substring(0, fragment);
    }
    return url === this.blazorOrigin || url === `${this.blazorOrigin}${this.blazorDefaultFile}`;
  }

  // BlazorWebView bootstrap (milestone 3): on the Blazor root document install the callback
  // form of window.external.receiveMessage, publish window.__dispatchMessageCallback and call
  // Blazor.start() once blazor.webview.js has loaded. This is the sequence the package's
  // blazor.webview.js and the platform handlers use (the bundle only reads window.external
  // inside Blazor.start(), so the registration has to exist before the start call; the
  // autostart="false" host-page script is the stock MAUI template). The framework script is
  // injected when the host page does not load it itself. Hybrid pages keep the compatibility
  // shim injected above unchanged.
  private injectBlazorBootstrap(pageUrl: string): void {
    if (!this.blazorRegistered || this.blazorBootstrapped || !this.isBlazorRootDocument(pageUrl)) {
      return;
    }
    this.blazorBootstrapped = true;
    const scriptUrl: string = `${this.blazorOrigin}_framework/blazor.webview.js`;
    const bootstrap: string = `(function () {
      if (window.__ohosBlazorBootstrapped) { return; }
      window.__ohosBlazorBootstrapped = true;
      window.__receiveMessageCallbacks = window.__receiveMessageCallbacks || [];
      window.__dispatchMessageCallback = function (message) {
        window.__receiveMessageCallbacks.forEach(function (callback) { callback(message); });
      };
      var external = window.external;
      if (!external || (typeof external !== 'object' && typeof external !== 'function')) {
        external = {};
        window.external = external;
      }
      if (typeof external.sendMessage !== 'function') {
        external.sendMessage = function (payload) {
          try {
            var proxy = window.dotnetHost || window.__ohosDotNet;
            if (proxy && typeof proxy.postMessage === 'function') {
              proxy.postMessage(payload);
            }
          } catch (sendError) {
            // The proxy is unavailable; the page keeps running without the bridge.
          }
        };
      }
      external.receiveMessage = function (callback) {
        window.__receiveMessageCallbacks.push(callback);
      };
      window.onpageshow = function (event) {
        if (event.persisted) {
          window.location.reload();
        }
      };
      function startBlazor() {
        try {
          if (typeof Blazor !== 'undefined' && typeof Blazor.start === 'function') {
            Blazor.start();
          }
        } catch (startError) {
          // Blazor has already started or refused to start; the page keeps running.
        }
      }
      if (typeof Blazor !== 'undefined') {
        startBlazor();
        return;
      }
      var existing = document.querySelector('script[src*="blazor.webview.js"]');
      if (existing) {
        existing.addEventListener('load', startBlazor);
        return;
      }
      var script = document.createElement('script');
      script.src = '${scriptUrl}';
      script.setAttribute('autostart', 'false');
      script.addEventListener('load', startBlazor);
      document.body.appendChild(script);
    })();`;
    try {
      this.webController.runJavaScript(bootstrap, () => {
        // Best effort; an error leaves the page with the hybrid bridge only.
      });
    } catch (bootstrapError) {
      this.blazorBootstrapped = false;
      console.error(`[maui] blazor bootstrap injection failed: ${(bootstrapError as Error).message}`);
    }
  }

  // Bluetooth discovery: bluetoothDeviceFind reports an array of device addresses per callback.
  // The listener resolves each name with getRemoteDeviceName, keeps the accumulated table for
  // op 4 and pushes each record to the managed side as "name\taddress". It is registered while
  // discovery runs (the permission was granted by the sink) and removed on stop.
  private ensureBluetoothDeviceListener(): void {
    if (this.bluetoothDeviceRegistered) {
      return;
    }
    try {
      connection.on('bluetoothDeviceFind', (devices: Array<string>): void => {
        this.onBluetoothDevicesFound(devices);
      });
      this.bluetoothDeviceRegistered = true;
    } catch (findError) {
      console.error(`[maui] bluetooth discovery listener failed: ${(findError as Error).message}`);
    }
  }

  private unsubscribeBluetoothDeviceListener(): void {
    if (!this.bluetoothDeviceRegistered) {
      return;
    }
    try {
      connection.off('bluetoothDeviceFind');
    } catch (offError) {
      // Stopping discovery already succeeded; a stale listener is harmless.
    }
    this.bluetoothDeviceRegistered = false;
  }

  private onBluetoothDevicesFound(devices: Array<string>): void {
    for (const deviceId of devices) {
      let name: string = '';
      try {
        name = connection.getRemoteDeviceName(deviceId);
      } catch (nameError) {
        name = '';
      }
      this.discoveredBluetooth.set(deviceId, name);
      try {
        host.notifyBluetoothDeviceFound(`${name}\t${deviceId}`);
      } catch (notifyError) {
        // An older host library drops the push; op 4 still serves the accumulated table.
      }
    }
  }

  // ArkWeb (WebviewController and WebResourceResponse) documents its methods as UI-thread
  // only, but the host delivers its sinks (web, web eval, hybrid invoke result) on the
  // managed app thread: the .NET app runs on its own pthread and the native host calls the
  // registered JS function directly. This helper moves the work back to the page: the
  // setTimeout callback runs on the ArkTS/UI event loop instead of the host-callback stack,
  // and runScopedTask executes it inside this component's UIContext so the Web component's
  // UI instance is the current scope. Both APIs are part of the shipped SDK (getUIContext is
  // a custom-component method, runScopedTask a UIContext method) and type-check here.
  private runOnUiThread(task: () => void): void {
    setTimeout(() => {
      this.getUIContext().runScopedTask(task);
    }, 0);
  }

  // Flashlight: creates the camera manager (Camera Kit) once and caches it. getCameraManager
  // throws when the camera service is unavailable; the sink catches and answers false, and
  // then drops the cached manager so the next request retries from a clean state.
  private ensureFlashlightManager(): camera.CameraManager {
    let manager: camera.CameraManager | undefined = this.flashlightManager;
    if (manager === undefined) {
      manager = camera.getCameraManager(getContext(this));
      this.flashlightManager = manager;
    }
    return manager;
  }

  aboutToAppear(): void {
    // 2 = foreground; the native host forwards it to the managed bridge.
    host.notifyLifecycle(2);
    // App theme: bind the device colour mode into AppStorage (idempotent; the recommended
    // startup point is the first page's aboutToAppear in this shell) and report the initial
    // light/dark state to the managed side. Later changes arrive through onColorModeChanged.
    Environment.envProp<ColorMode>('colorMode', ColorMode.LIGHT);
    this.reportTheme();
    // Battery/DeviceDisplay (Essentials): push the startup snapshots and follow later changes.
    this.reportBattery();
    this.reportDisplay();
    this.subscribeBatteryEvents();
    this.subscribeDisplayChange();
    // Essentials (vibration/permissions/geolocation/pickers/connectivity/launcher) need the
    // matching SDK kits, which are not part of this minimal shell project's compilation set yet
    // (see docs/plans/2026-09-18-ohos-arkts-essentials-bridge-plan.md). The sinks stay
    // registered and report "unavailable" so the managed side behaves deterministically.
    // Essentials: vibration / keystore sinks stay degradable until the SDK declarations are
    // surfaced to this project's compilation. Official reference for the remaining step:
    // applications_app_samples (OpenHarmony-v6.1-Release) uses numeric SDK versions
    // (compileSdkVersion: 23, compatibleSdkVersion: 20, targetSdkVersion: 23) and
    // buildOption.strictMode { caseSensitiveCheck: true, useNormalizedOHMUrl: true } - the
    // strictMode block is now emitted, the numeric-version + matching staged SDK layout is the
    // next candidate. Verified snippet lives in the ArkTS Essentials plan.
    // Safe area: report the system avoid area so the managed layout can inset its content.
    window.getLastWindow(getContext(this)).then((win) => {
      const area = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
      host.notifyAvoidArea(area.topRect.height, area.bottomRect.height,
                           area.leftRect.width, area.rightRect.width);
    }).catch(() => {
      // Window information is optional.
    });

    // WebView: a hidden ArkWeb component that the managed WebView handler drives.
    // Host callback: every controller call runs on the page's UI thread (see runOnUiThread).
    host.registerWebSink((op: string, arg: string) => {
      this.runOnUiThread(() => {
        try {
          if (op === 'show') {
            this.webVisible = true;
          } else if (op === 'hide') {
            this.webVisible = false;
          } else if (op === 'load') {
            this.webVisible = true;
            this.webController.loadUrl(arg);
          } else if (op === 'data') {
            this.webVisible = true;
            this.webController.loadData(arg, 'text/html', 'UTF-8');
          } else if (op === 'back') {
            if (this.webController.accessBackward()) {
              this.webController.backward();
            }
          } else if (op === 'hybrid') {
            // HybridWebView asset root registration from the managed handler.
            this.registerHybridAssets(arg);
          } else if (op === 'blazor') {
            // BlazorWebView asset root registration from the managed handler (milestone 3).
            this.registerBlazorAssets(arg);
          }
        } catch (error) {
          // Web errors never take the app down.
        }
      });
    });

    // JavaScript bridge: the managed side evaluates scripts through ohos_host_web_eval; the
    // runJavaScript result (or its error) travels back to the awaiting request.
    // Host callback: runJavaScript is UI-thread only (see runOnUiThread).
    host.registerWebEvalSink((script: string, requestId: number): void => {
      this.runOnUiThread(() => {
        try {
          this.webController.runJavaScript(script, (err, result) => {
            host.notifyWebEvalResult(requestId, result || '', err ? 1 : 0);
          });
        } catch (evalError) {
          host.notifyWebEvalResult(requestId, '', 1);
        }
      });
    });

    // HybridWebView JS -> .NET invocation results: the managed handler answers a
    // host.notifyHybridInvoke call through ohos_host_hwv_invoke_result, which lands here and
    // completes the delayed __hwvInvokeDotNet response.
    try {
      host.registerHybridInvokeResultSink((requestId: number, payload: string): void => {
        this.completeHybridInvoke(requestId, payload);
      });
    } catch (hybridInvokeSinkError) {
      console.error(`[maui] hybrid invoke result sink registration failed: ${(hybridInvokeSinkError as Error).message}`);
    }

    // File/media pickers: the managed side asks for the system picker; the chosen file's name
    // and bytes travel back as base64 (all kinds use the document picker, so the shell needs no
    // extra UI component).
    host.registerPickerSink(async (requestId: number, kind: number) => {
      if (kind === 3 || kind === 4) {
        try {
          const mediaType = kind === 3 ? cameraPicker.PickerMediaType.PHOTO : cameraPicker.PickerMediaType.VIDEO;
          const picked = await cameraPicker.pick(getContext(this), [mediaType], {
            cameraPosition: camera.CameraPosition.CAMERA_POSITION_BACK,
          });
          const captureUri: string = picked.resultUri;
          const captureName: string = captureUri.substring(captureUri.lastIndexOf('/') + 1);
          const captureFile = fileIo.openSync(captureUri, fileIo.OpenMode.READ_ONLY);
          const captureBuffer = new ArrayBuffer(fileIo.statSync(captureUri).size);
          fileIo.readSync(captureFile.fd, captureBuffer);
          fileIo.closeSync(captureFile);
          const captureBase64 = new util.Base64Helper().encodeToStringSync(new Uint8Array(captureBuffer));
          host.notifyPickerResult(requestId, 0, captureName, captureBase64);
        } catch (captureError) {
          console.error(`camera capture failed: ${captureError.message}`);
          host.notifyPickerResult(requestId, -1, '', '');
        }
        return;
      }
        host.registerNotificationSink((notificationId: number, notificationTitle: string, notificationText: string): void => {
            notificationManager.publish({
                id: notificationId,
                content: {
                    notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
                    normal: { title: notificationTitle, text: notificationText, additionalText: '' }
                }
            }).catch((publishError: Error): void => {
                console.error(`notification publish failed: ${publishError.message}`);
            });
        });
      try {
        const documentPicker = new picker.DocumentViewPicker();
        const uris = await documentPicker.select({ maxSelectNumber: 1 });
        if (!uris || uris.length === 0) {
          host.notifyPickerResult(requestId, -1, '', '');
          return;
        }
        const uri = uris[0];
        const file = fs.openSync(uri, fs.OpenMode.READ_ONLY);
        const stat = fs.statSync(file.fd);
        const buffer = new ArrayBuffer(stat.size);
        fs.readSync(file.fd, buffer);
        fs.closeSync(file);
        const helper = new util.Base64Helper();
        const encoded = helper.encodeToStringSync(new Uint8Array(buffer));
        const name = uri.substring(uri.lastIndexOf('/') + 1);
        host.notifyPickerResult(requestId, 0, name, encoded);
      } catch (error) {
        host.notifyPickerResult(requestId, -1, '', '');
      }
    });

    host.registerVibrationSink((durationMs: number) => {
    });

    // SecureStorage: the managed side asks HUKS to generate/encrypt/decrypt.
    // The keystore kit is not part of this minimal shell project's dependencies/syscap yet, so
    // every request is answered with rc=-1 and the managed side uses its documented file
    // fallback. Enabling the real path means adding the universal keystore kit to the shell
    // project (see docs/plans/2026-09-18-ohos-secure-storage-huks-plan.md).
    host.registerKeystoreSink((requestId: number, op: string, alias: string, data: string) => {
      host.notifyKeystoreResult(requestId, -1, '');
    });

    // TextToSpeech: speak requests arrive from the managed side (ohos_host_tts_speak). The
    // OpenHarmony SDK this shell compiles against has no speech synthesis module: both
    // '@kit.CoreSpeechKit' and '@ohos.ai.tts' fail with "Cannot find module ... or its
    // corresponding type declarations", so - like the keystore sink above - the request is
    // answered with "unavailable" (rc=-1) and the managed side degrades (it never throws).
    // With a Speech Kit SDK: create the engine once (textToSpeech.createEngine), call
    // engine.speak(text, ...) and answer host.notifyTtsResult(requestId, 0) when it finishes.
    host.registerTtsSink((requestId: number, text: string, locale: string): void => {
      host.notifyTtsResult(requestId, -1);
    });

    // Contacts (platform extra): the managed side asks through ohos_host_contacts_query. The
    // sink requires ohos.permission.READ_CONTACTS, queries the Contacts Kit
    // (@kit.ContactsKit -> contact.queryContacts) and answers with "name\tphone" lines, capped
    // at the managed limit. A missing kit or a denied permission answers code -1, which the
    // managed side reports as IsSupported == false instead of guessing.
    host.registerContactsSink(async (requestId: number, namePrefix: string, limit: number): Promise<void> => {
      try {
        const context = getContext(this) as common.UIAbilityContext;
        const permissions: Permissions[] = ['ohos.permission.READ_CONTACTS'];
        const atManager = abilityAccessCtrl.createAtManager();
        const granted = await atManager.requestPermissionsFromUser(context, permissions);
        if (granted.authResults.length === 0 || granted.authResults[0] !== 0) {
          host.notifyContactsResult(requestId, -1, '');
          return;
        }
        const all = await contact.queryContacts(context);
        const rows: string[] = [];
        for (const item of all) {
          const name: string = item.name && item.name.fullName ? item.name.fullName : '';
          if (namePrefix.length > 0 && !name.startsWith(namePrefix)) {
            continue;
          }
          const phone: string = item.phoneNumbers && item.phoneNumbers.length > 0
            ? item.phoneNumbers[0].phoneNumber : '';
          rows.push(`${name}\t${phone}`);
          if (rows.length >= limit) {
            break;
          }
        }
        host.notifyContactsResult(requestId, 0, rows.join('\n'));
      } catch (contactsError) {
        console.error(`[maui] contacts query failed: ${(contactsError as Error).message}`);
        host.notifyContactsResult(requestId, -1, '');
      }
    });

    // Calendar (platform extra): the managed side asks through ohos_host_calendar_list (op 0,
    // arg1 = days) or ohos_host_calendar_add (op 1, arg1 = title, arg2/arg3 = ISO start/end).
    // Both require the runtime calendar permissions and run through the Calendar Kit
    // (@kit.CalendarKit -> calendarManager.getCalendar -> getEvents / addEvent). A missing kit
    // or a denied permission answers code -1 (managed IsSupported == false).
    host.registerCalendarSink(async (requestId: number, op: number, arg1: string, arg2: string, arg3: string): Promise<void> => {
      try {
        const context = getContext(this) as common.UIAbilityContext;
        const permissions: Permissions[] = op === 0
          ? ['ohos.permission.READ_CALENDAR']
          : ['ohos.permission.READ_CALENDAR', 'ohos.permission.WRITE_CALENDAR'];
        const atManager = abilityAccessCtrl.createAtManager();
        const granted = await atManager.requestPermissionsFromUser(context, permissions);
        for (let i = 0; i < granted.authResults.length; i++) {
          if (granted.authResults[i] !== 0) {
            host.notifyCalendarResult(requestId, -1, '');
            return;
          }
        }
        const manager = calendarManager.getCalendarManager(context);
        const calendar = await manager.getCalendar();
        if (op === 0) {
          const days: number = Number.parseInt(arg1, 10) || 0;
          const now: number = Date.now();
          const end: number = now + days * 24 * 60 * 60 * 1000;
          const events = await calendar.getEvents(calendarManager.EventFilter.filterByTime(now, end));
          const rows: string[] = [];
          for (const item of events) {
            const title: string = item.title ? item.title : '';
            rows.push(`${title}\t${new Date(item.startTime).toISOString()}\t${new Date(item.endTime).toISOString()}`);
          }
          host.notifyCalendarResult(requestId, 0, rows.join('\n'));
          return;
        }
        const event: calendarManager.Event = {
          type: calendarManager.EventType.NORMAL,
          title: arg1,
          startTime: Date.parse(arg2),
          endTime: Date.parse(arg3),
        };
        await calendar.addEvent(event);
        host.notifyCalendarResult(requestId, 0, '');
      } catch (calendarError) {
        console.error(`[maui] calendar request failed: ${(calendarError as Error).message}`);
        host.notifyCalendarResult(requestId, -1, '');
      }
    });

    // Bluetooth (platform extra): the managed side asks through ohos_host_bluetooth_query.
    // op 0 reports the adapter state (access.getState), op 1 lists the paired devices
    // (connection.getPairedDevices + getRemoteDeviceName), op 2/3 start/stop classic discovery
    // (connection.startBluetoothDiscovery / stopBluetoothDiscovery) and op 4 answers the devices
    // found since the last start (filled by the bluetoothDeviceFind listener). ACCESS_BLUETOOTH
    // is a user_grant permission, so the shell requests it first; a denial answers code -1
    // (managed IsSupported == false). Devices travel as "name\taddress" lines.
    host.registerBluetoothSink(async (requestId: number, op: number): Promise<void> => {
      try {
        const context = getContext(this) as common.UIAbilityContext;
        const permissions: Permissions[] = ['ohos.permission.ACCESS_BLUETOOTH'];
        const atManager = abilityAccessCtrl.createAtManager();
        const granted = await atManager.requestPermissionsFromUser(context, permissions);
        if (granted.authResults.length === 0 || granted.authResults[0] !== 0) {
          host.notifyBluetoothResult(requestId, -1, '');
          return;
        }
        const state: access.BluetoothState = access.getState();
        if (op === 0) {
          host.notifyBluetoothResult(requestId, 0, `${state}`);
          return;
        }
        if (op === 4) {
          // Discovered devices are accumulated locally; no adapter call is needed.
          const discovered: string[] = [];
          this.discoveredBluetooth.forEach((name: string, address: string): void => {
            discovered.push(`${name}\t${address}`);
          });
          host.notifyBluetoothResult(requestId, 0, discovered.join('\n'));
          return;
        }
        if (op === 2 || op === 3) {
          // Discovery and its stop need a powered adapter; while it is off they would throw
          // 2900003. That is a transient device state, so it answers code -2 (the managed side
          // fails the call but keeps IsSupported) instead of -1 (platform unavailable).
          if (state !== access.BluetoothState.STATE_ON) {
            host.notifyBluetoothResult(requestId, -2, '');
            return;
          }
          if (op === 2) {
            // A fresh scan starts an empty result set; the listener is registered once the
            // permission is in place (the discovery callback needs it too).
            this.discoveredBluetooth.clear();
            this.ensureBluetoothDeviceListener();
            connection.startBluetoothDiscovery();
          } else {
            connection.stopBluetoothDiscovery();
            this.unsubscribeBluetoothDeviceListener();
          }
          host.notifyBluetoothResult(requestId, 0, '');
          return;
        }
        // Paired devices need a powered adapter; while it is off the platform throws
        // 2900003, which is answered as a valid empty list instead of a failure.
        if (state !== access.BluetoothState.STATE_ON) {
          host.notifyBluetoothResult(requestId, 0, '');
          return;
        }
        const devices: Array<string> = connection.getPairedDevices();
        const rows: string[] = [];
        for (const deviceId of devices) {
          let name: string = '';
          try {
            name = connection.getRemoteDeviceName(deviceId);
          } catch (nameError) {
            name = '';
          }
          rows.push(`${name}\t${deviceId}`);
        }
        host.notifyBluetoothResult(requestId, 0, rows.join('\n'));
      } catch (bluetoothError) {
        console.error(`[maui] bluetooth request failed: ${(bluetoothError as Error).message}`);
        host.notifyBluetoothResult(requestId, -1, '');
      }
    });

    // Printing (platform extra): the managed side asks through ohos_host_print_file with an
    // absolute path to a PDF/image it rendered (PrintTextAsync writes <cacheDir>/<job>.pdf).
    // ohos.permission.PRINT is system_grant, so there is no runtime prompt: a packaged app
    // that declares it can print. print.print resolves once the system print UI accepted the
    // job; the final page outcome belongs to the print service, so code 0 means "accepted".
    host.registerPrintSink(async (requestId: number, path: string): Promise<void> => {
      try {
        const context = getContext(this) as common.UIAbilityContext;
        const task: print.PrintTask = await print.print([path], context);
        task.on('fail', (): void => {
          console.error('[maui] print task reported failure');
        });
        task.on('cancel', (): void => {
          console.info('[maui] print task cancelled');
        });
        host.notifyPrintResult(requestId, 0, '');
      } catch (printError) {
        console.error(`[maui] print request failed: ${(printError as Error).message}`);
        host.notifyPrintResult(requestId, -1, (printError as Error).message);
      }
    });

    // Launcher/Browser/Share: managed requests arrive through ohos_host_ability_start. kind 0
    // opens a uri (implicit viewData Want), kind 1 shares plain text (implicit sendData Want),
    // kind 2 is the availability probe (never launches), kind 3 shares a file (implicit
    // sendData Want with uri + MIME type + FLAG_AUTH_READ_URI_PERMISSION). The UIAbilityContext
    // owns the actual startAbility call; a rejected launch is logged, and only the dispatch
    // status (true when the request was handed to the system) is reported back to the managed
    // side.
    // Plain text has no wantConstant key in this SDK (Share Kit/systemShare is not part of it),
    // so the text travels under 'ohos.extra.param.key.content', the key used by the
    // pre-Share-Kit samples for ohos.want.action.sendData.
    // The read flag on kind 3 is wantConstant.Flags.FLAG_AUTH_READ_URI_PERMISSION (0x1), which
    // this SDK declares in @ohos.app.ability.wantConstant; it asks the ability manager to grant
    // the receiver read access to the file:// uri. Whether the target app can actually read the
    // sandbox file depends on that app and is not verifiable from this shell.
    host.registerAbilitySink((kind: number, uri: string, text: string): boolean => {
      try {
        const context = getContext(this) as common.UIAbilityContext;
        if (kind === 2) {
          return context !== undefined && context !== null;
        }
        const want: Want = new Want();
        if (kind === 1) {
          want.action = 'ohos.want.action.sendData';
          want.type = 'text/plain';
          want.parameters = { 'ohos.extra.param.key.content': text };
        } else if (kind === 3) {
          // File share: uri = file:// URI (built by the managed side), text = MIME type.
          want.action = 'ohos.want.action.sendData';
          want.uri = uri;
          want.type = text;
          want.flags = wantConstant.Flags.FLAG_AUTH_READ_URI_PERMISSION;
        } else {
          want.action = 'ohos.want.action.viewData';
          want.uri = uri;
        }
        context.startAbility(want).then((): void => {
          console.info(`[maui] ability start dispatched: kind=${kind}`);
        }).catch((startError: Error): void => {
          console.error(`[maui] ability start failed: kind=${kind} ${startError.message}`);
        });
        return true;
      } catch (startError) {
        console.error(`[maui] ability start threw: ${(startError as Error).message}`);
        return false;
      }
    });

    // Flashlight (Camera Kit torch): the managed side asks through ohos_host_flashlight_set(on)
    // with on 0 = torch off, 1 = torch on, 2 = support probe (isTorchSupported only, no torch
    // call). The callback returns whether the kit accepted the request; setTorchMode is a
    // synchronous call that throws (e.g. 7400102 when the camera service does not allow it), so
    // the boolean is the kit's answer, not a visual confirmation of the LED. A missing kit or
    // camera answers false and the managed side degrades without throwing.
    host.registerFlashlightSink((on: number): boolean => {
      try {
        const manager = this.ensureFlashlightManager();
        if (on === 2) {
          return manager.isTorchSupported();
        }
        if (!manager.isTorchSupported()) {
          return false;
        }
        manager.setTorchMode(on === 1 ? camera.TorchMode.ON : camera.TorchMode.OFF);
        return true;
      } catch (flashlightError) {
        console.error(`[maui] flashlight request failed: ${(flashlightError as Error).message}`);
        this.flashlightManager = undefined;
        return false;
      }
    });

    // The managed Entry asks for the soft keyboard through this sink.
    host.registerTextInputSink((show: number) => {
      if (show === 1) {
        this.controller.caretPosition(0);
        focusControl.requestFocus('ohos_dotnet_input');
      } else {
        focusControl.requestFocus('ohos_dotnet_surface');
      }
    });

    // Menus: pull the initial table, then refresh on every commit from the managed side.
    // A host library without the menu exports degrades to no menu instead of failing the page.
    try {
      host.registerMenuChangedSink((count: number): void => {
        console.info(`[maui] menu table changed: ${count} rows`);
        this.pullMenu();
      });
      this.pullMenu();
    } catch (menuError) {
      this.menuItems = [];
    }
  }

  // Accessibility: host.setNodeContent hands this.content to the native host, which creates
  // the CUSTOM node and calls OH_ArkUI_NodeContent_AddNode on it. The ContentSlot that hosts
  // the NodeContent only exists once build() has mounted the page, so attaching it in
  // aboutToAppear ran before the container was there and left the node unattached (host
  // status 3). onPageShow runs after the page (and its ContentSlot) is mounted; the host
  // caches the created node, so a repeated page show cannot attach it twice.
  onPageShow(): void {
    host.setNodeContent(this.content);
  }

  // Accessibility self-check: the tiny overlay button in build() reports what the native host
  // answered for the provider, so a tester can read the state off the device and paste it into
  // a report with one tap. host.accessibilityStatus() is a plain int (see the host's
  // AccessibilityStatus export):
  //   0 = not attached, 1 = attached (expected), 2 = frame node refused,
  //   3 = custom node not created, 4 = custom node attached but provider refused.
  // The optional host.accessibilityNodeCount() export appends the published node count when
  // the host library has it; a host without either export degrades to "unavailable" instead of
  // failing the page.
  private accessibilityStatusText(status: number): string {
    if (status === 0) {
      return '0 (not attached)';
    }
    if (status === 1) {
      return '1 (attached - expected)';
    }
    if (status === 2) {
      return '2 (frame node refused)';
    }
    if (status === 3) {
      return '3 (custom node not created)';
    }
    if (status === 4) {
      return '4 (custom node attached but provider refused)';
    }
    return `${status} (unknown status)`;
  }

  private showAccessibilitySelfCheck(): void {
    let statusText: string = 'unavailable (the host does not export accessibilityStatus)';
    try {
      statusText = this.accessibilityStatusText(host.accessibilityStatus() as number);
    } catch (statusError) {
      statusText = 'unavailable (the host does not export accessibilityStatus)';
    }
    let message: string = `accessibilityStatus: ${statusText}`;
    try {
      // Optional export: only newer host libraries publish it, so it is read behind a
      // runtime typeof check and simply omitted when the library has no such export.
      if (typeof host.accessibilityNodeCount === 'function') {
        message += `\naccessibilityNodeCount: ${host.accessibilityNodeCount() as number}`;
      }
    } catch (nodeCountError) {
      message += '\naccessibilityNodeCount: unavailable';
    }
    this.getUIContext().showAlertDialog({
      title: 'Accessibility self-check',
      message: message,
      confirm: {
        value: 'OK',
        action: (): void => {
          // Only dismisses the report.
        }
      }
    });
  }

  // HybridWebView: the managed handler registers the payload directory and the hybrid layout
  // through the existing web command channel (op "hybrid"); a successful registration loads
  // the MAUI hybrid origin, whose requests onInterceptRequest answers from the payload.
  private registerHybridAssets(arg: string): void {
    try {
      const config = JSON.parse(arg) as HybridAssetsConfig;
      this.hybridBase = config.base;
      this.hybridRoot = config.root;
      this.hybridDefaultFile = config.defaultFile;
      this.hybridRegistered = this.hybridBase.length > 0 && this.hybridRoot.length > 0
        && this.hybridDefaultFile.length > 0;
      if (this.hybridRegistered) {
        this.webVisible = true;
        this.webController.loadUrl(this.hybridOrigin);
      }
    } catch (hybridError) {
      console.error(`[maui] hybrid assets registration failed: ${(hybridError as Error).message}`);
      this.hybridRegistered = false;
    }
  }

  // BlazorWebView: the managed handler registers the payload directory and the Blazor layout
  // through the "blazor" web command. The registration mirrors the hybrid bridge (the shell is
  // the loader until the managed WebViewManager navigates in a later milestone): interception
  // is armed for the origin and the root document is loaded so the page-end bootstrap runs.
  private registerBlazorAssets(arg: string): void {
    try {
      const config = JSON.parse(arg) as BlazorAssetsConfig;
      this.blazorBase = config.base;
      this.blazorRoot = config.root;
      this.blazorDefaultFile = config.defaultFile;
      this.blazorOrigin = config.origin.length > 0 ? config.origin : 'https://0.0.0.0/';
      if (!this.blazorOrigin.endsWith('/')) {
        this.blazorOrigin = `${this.blazorOrigin}/`;
      }
      this.blazorRegistered = this.blazorBase.length > 0 && this.blazorRoot.length > 0
        && this.blazorDefaultFile.length > 0;
      if (this.blazorRegistered) {
        this.webVisible = true;
        this.webController.loadUrl(this.blazorOrigin);
      }
    } catch (blazorError) {
      console.error(`[maui] blazor assets registration failed: ${(blazorError as Error).message}`);
      this.blazorRegistered = false;
    }
  }

  // Resolves an app-origin URL to an absolute file below the payload directory. Unknown and
  // malformed paths (including traversal attempts) resolve to '' and are answered with 404.
  private hybridFilePath(url: string): string {
    let path: string = url;
    const scheme: number = path.indexOf('://');
    if (scheme >= 0) {
      const slash: number = path.indexOf('/', scheme + 3);
      path = slash >= 0 ? path.substring(slash) : '/';
    }
    const query: number = path.indexOf('?');
    if (query >= 0) {
      path = path.substring(0, query);
    }
    const fragment: number = path.indexOf('#');
    if (fragment >= 0) {
      path = path.substring(0, fragment);
    }
    try {
      path = decodeURIComponent(path);
    } catch (decodeError) {
      return '';
    }
    while (path.startsWith('/')) {
      path = path.substring(1);
    }
    if (path.indexOf('..') >= 0 || path.indexOf('\\') >= 0) {
      return '';
    }
    if (path.length === 0) {
      path = this.hybridDefaultFile;
    }
    if (path === '_framework/hybridwebview.js') {
      return `${this.hybridBase}/${path}`;
    }
    return `${this.hybridBase}/${this.hybridRoot}/${path}`;
  }

  // Resolves a Blazor app-origin URL (https://0.0.0.0/...) to an absolute file below
  // <base>/<root>. Unknown and malformed paths (including traversal attempts) resolve to '' and
  // are answered with 404. Every path - _framework/blazor.webview.js included - is looked up
  // under the content root, which is exactly where the pack targets stage it.
  private blazorFilePath(url: string): string {
    let path: string = url;
    const scheme: number = path.indexOf('://');
    if (scheme >= 0) {
      const slash: number = path.indexOf('/', scheme + 3);
      path = slash >= 0 ? path.substring(slash) : '/';
    }
    const query: number = path.indexOf('?');
    if (query >= 0) {
      path = path.substring(0, query);
    }
    const fragment: number = path.indexOf('#');
    if (fragment >= 0) {
      path = path.substring(0, fragment);
    }
    try {
      path = decodeURIComponent(path);
    } catch (decodeError) {
      return '';
    }
    while (path.startsWith('/')) {
      path = path.substring(1);
    }
    if (path.indexOf('..') >= 0 || path.indexOf('\\') >= 0) {
      return '';
    }
    if (path.length === 0) {
      path = this.blazorDefaultFile;
    }
    return `${this.blazorBase}/${this.blazorRoot}/${path}`;
  }

  private hybridMimeType(path: string): string {
    const lower: string = path.toLowerCase();
    if (lower.endsWith('.html') || lower.endsWith('.htm')) {
      return 'text/html';
    }
    if (lower.endsWith('.js') || lower.endsWith('.mjs')) {
      return 'text/javascript';
    }
    if (lower.endsWith('.css')) {
      return 'text/css';
    }
    if (lower.endsWith('.json')) {
      return 'application/json';
    }
    if (lower.endsWith('.wasm')) {
      return 'application/wasm';
    }
    if (lower.endsWith('.svg')) {
      return 'image/svg+xml';
    }
    if (lower.endsWith('.png')) {
      return 'image/png';
    }
    if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) {
      return 'image/jpeg';
    }
    if (lower.endsWith('.gif')) {
      return 'image/gif';
    }
    if (lower.endsWith('.webp')) {
      return 'image/webp';
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

  private hybridErrorResponse(code: number): WebResourceResponse {
    const response: WebResourceResponse = new WebResourceResponse();
    response.setResponseCode(code);
    response.setResponseMimeType('text/plain');
    response.setResponseEncoding('utf-8');
    if (code !== 204) {
      response.setResponseData(code === 404 ? 'Not Found' : 'Bad Request');
    }
    return response;
  }

  // ArkWeb needs the intercepted response synchronously, and payload assets are small, so the
  // file is read inline through @ohos.file.fs (open/read/close). '' (an unknown or unsafe path)
  // is answered with 404, so both bridges share the read path.
  private servePayloadFile(filePath: string): WebResourceResponse {
    if (filePath.length === 0) {
      return this.hybridErrorResponse(404);
    }
    let fd: number = -1;
    try {
      const stat = fileIo.statSync(filePath);
      if (!stat.isFile()) {
        return this.hybridErrorResponse(404);
      }
      const file = fileIo.openSync(filePath, fileIo.OpenMode.READ_ONLY);
      fd = file.fd;
      const buffer = new ArrayBuffer(stat.size);
      fileIo.readSync(fd, buffer);
      const response: WebResourceResponse = new WebResourceResponse();
      response.setResponseCode(200);
      response.setResponseMimeType(this.hybridMimeType(filePath));
      response.setResponseEncoding('utf-8');
      response.setResponseData(buffer);
      return response;
    } catch (ioError) {
      return this.hybridErrorResponse(404);
    } finally {
      if (fd >= 0) {
        try {
          fileIo.closeSync(fd);
        } catch (closeError) {
          // The handle is released with the response in the worst case.
        }
      }
    }
  }

  // HybridWebView assets live under <base>/<root> (plus the framework script next to the base).
  private serveHybridFile(url: string): WebResourceResponse {
    return this.servePayloadFile(this.hybridFilePath(url));
  }

  // BlazorWebView assets live under <base>/<root> only.
  private serveBlazorFile(url: string): WebResourceResponse {
    return this.servePayloadFile(this.blazorFilePath(url));
  }

  // JS -> .NET channel of the served hybridwebview.js: the script POSTs its payload in the
  // X-Maui-Request-Body header (the same transport Android uses). The body is handed to the
  // existing JS message sink, so __RawMessage / __InvokeJavaScript* records reach the managed
  // HybridWebView handler. The matching __hwvInvokeDotNet endpoint is hybridInvokeResponse.
  private hybridMessageResponse(event: OnInterceptRequestEvent): WebResourceResponse {
    let body: string = '';
    let token: string = '';
    const headers = event.request.getRequestHeader();
    for (let i = 0; i < headers.length; i++) {
      const name: string = headers[i].headerKey.toLowerCase();
      if (name === 'x-maui-request-body') {
        body = headers[i].headerValue;
      } else if (name === 'x-maui-invoke-token') {
        token = headers[i].headerValue;
      }
    }
    if (token !== 'HybridWebView' || body.length === 0) {
      return this.hybridErrorResponse(400);
    }
    host.notifyJsMessage(body);
    return this.hybridErrorResponse(204);
  }

  // Error payload for a delayed invocation response. It completes the response with HTTP 200
  // so fetch resolves and the stock invokeDotNet code reads IsError and rejects.
  private hybridInvokeErrorPayload(message: string): string {
    const payload: HybridInvokeErrorResult = { IsError: true, ErrorMessage: message };
    return JSON.stringify(payload);
  }

  // Completes a held-open __hwvInvokeDotNet response once (later duplicates are ignored) and
  // clears its timeout. The data is always written on the next tick, after onInterceptRequest
  // returned the not-ready response: the documented order is setResponseIsReady(false) ->
  // setResponseData -> setResponseIsReady(true). A synchronous answer (managed method that
  // completes inline) therefore cannot write into the response mid-interception. This runs
  // both from the managed handler (host callback, managed thread) and from the local timeout
  // (UI thread), so the response writes are dispatched through runOnUiThread.
  private completeHybridInvoke(requestId: number, payload: string): void {
    const pending: HybridPendingInvoke | undefined = this.hybridInvokes.get(requestId);
    if (pending === undefined) {
      return;
    }
    this.hybridInvokes.delete(requestId);
    clearTimeout(pending.timer);
    this.runOnUiThread(() => {
      try {
        pending.response.setResponseData(payload);
        pending.response.setResponseCode(200);
        pending.response.setReasonMessage('OK');
        pending.response.setResponseIsReady(true);
      } catch (completeError) {
        console.error(`[maui] hybrid invoke response failed: ${(completeError as Error).message}`);
      }
    });
  }

  // JS -> .NET invocation endpoint: hybridwebview.js POSTs
  // { MethodName, ParamValues } to <origin>/__hwvInvokeDotNet. The intercepted response is
  // returned not-ready (setResponseIsReady(false)), the invocation is handed to the managed
  // handler through host.notifyHybridInvoke, and completeHybridInvoke answers it. Every
  // failure path (bad request, missing host export, managed error, timeout) completes the
  // response with an error payload, so the page's promise rejects instead of hanging.
  private hybridInvokeResponse(event: OnInterceptRequestEvent): WebResourceResponse {
    let body: string = '';
    let token: string = '';
    const headers = event.request.getRequestHeader();
    for (let i = 0; i < headers.length; i++) {
      const name: string = headers[i].headerKey.toLowerCase();
      if (name === 'x-maui-request-body') {
        body = headers[i].headerValue;
      } else if (name === 'x-maui-invoke-token') {
        token = headers[i].headerValue;
      }
    }
    if (token !== 'HybridWebView' || body.length === 0) {
      return this.hybridErrorResponse(400);
    }
    let method: string = '';
    let argsJson: string = '[]';
    try {
      const data = JSON.parse(body) as HybridInvokeRequest;
      if (data.MethodName !== undefined) {
        method = data.MethodName;
      }
      if (data.ParamValues !== undefined) {
        argsJson = JSON.stringify(data.ParamValues);
      }
    } catch (parseError) {
      return this.hybridErrorResponse(400);
    }
    if (method.length === 0) {
      return this.hybridErrorResponse(400);
    }
    const response: WebResourceResponse = new WebResourceResponse();
    response.setResponseCode(200);
    response.setResponseMimeType('application/json');
    response.setResponseEncoding('utf-8');
    response.setResponseIsReady(false);
    const requestId: number = ++this.hybridInvokeSeq;
    const timer: number = setTimeout(() => {
      this.completeHybridInvoke(requestId,
        this.hybridInvokeErrorPayload('the .NET invocation timed out'));
    }, this.hybridInvokeTimeoutMs);
    this.hybridInvokes.set(requestId, { response: response, timer: timer });
    try {
      const rc: number = host.notifyHybridInvoke(requestId, method, argsJson) as number;
      if (rc !== 0) {
        this.completeHybridInvoke(requestId,
          this.hybridInvokeErrorPayload('the .NET host is not listening for hybrid invocations'));
      }
    } catch (invokeError) {
      this.completeHybridInvoke(requestId,
        this.hybridInvokeErrorPayload('the .NET host does not expose the hybrid invocation bridge'));
    }
    return response;
  }

  build() {
    Stack() {
      // ArkWeb: hidden until the managed WebView asks for it.
      Web({ src: '', controller: this.webController })
        .visibility(this.webVisible ? Visibility.Visible : Visibility.None)
        // The controller is attached here; registering the dotnetHost proxy any earlier fails
        // with BusinessError 17100001 (controller not associated with a Web component).
        .onControllerAttached(() => {
          this.registerDotNetHost();
        })
        .onInterceptRequest((event) => {
          try {
            const url: string = event.request.getRequestUrl();
            // Blazor origin (https://0.0.0.0/): every app asset, _framework/blazor.webview.js
            // included, is served from <base>/<root>. The hybrid __hwv* endpoints do not exist
            // here: blazor.webview.js talks through window.external (the dotnetHost proxy).
            if (this.blazorRegistered && url.startsWith(this.blazorOrigin)) {
              return this.serveBlazorFile(url);
            }
            // Only the MAUI hybrid origin is intercepted, and only after the managed handler
            // registered the payload root; everything else is left to the Web engine.
            if (!this.hybridRegistered || !url.startsWith(this.hybridOrigin)) {
              return null;
            }
            if (url.startsWith(this.hybridOrigin + '__hwvInvokeDotNet')) {
              return this.hybridInvokeResponse(event);
            }
            if (url.startsWith(this.hybridOrigin + '__hwvSendMessage')) {
              return this.hybridMessageResponse(event);
            }
            return this.serveHybridFile(url);
          } catch (interceptError) {
            return null;
          }
        })
        .onPageBegin((event) => {
          // A new main-frame document gets its own Blazor bootstrap.
          this.blazorBootstrapped = false;
          host.notifyWebEvent('started', event ? event.url : '');
        })
        .onPageEnd((event) => {
          const pageUrl: string = event ? event.url : '';
          host.notifyWebEvent('finished', pageUrl);
          this.injectPageBridge();
          this.injectBlazorBootstrap(pageUrl);
        })

      // Text entry bridge: the managed Entry reads what is typed here.
      TextInput({ text: this.inputText, placeholder: 'type here', controller: this.controller })
        .id('ohos_dotnet_input')
        .height(56)
        .position({ x: 0, y: 0 })
        .onChange((value: string) => {
          this.inputText = value;
          host.notifyTextInput(value);
        })
        .onSubmit(() => {
          // The managed Entry/SearchBar raises Completed/SearchButtonPressed.
          host.notifyTextSubmitted(this.inputText);
        })

      XComponent({
        id: 'ohos_dotnet_surface',
        type: XComponentType.SURFACE,
        libraryname: 'openharmonyhost',
      })
        .onLoad(() => {
          // Binds the native XComponent so libopenharmonyhost receives surface callbacks.
          host.registerXComponent();
        })
        .width('100%')
        .height('100%')

      ContentSlot(this.content)

      // Menu handle: only present while the managed page publishes menu bars. The ArkUI menu is
      // bound to the flat element array; choosing a row calls host.notifyMenuAction(index).
      if (this.menuItems.length > 0) {
        Button('Menu')
          .align(Alignment.TopEnd)
          .margin({ top: 8, right: 8 })
          .height(40)
          .fontSize(18)
          .bindMenu(this.buildMenuElements())
      }

      // Accessibility self-check: a tiny overlay in the opposite corner. The Stack overlays
      // it, so it never takes layout space from the managed surface (the XComponent and the
      // ContentSlot keep their full size); tapping it shows the provider state.
      Button('A11Y')
        .align(Alignment.BottomStart)
        .margin({ bottom: 4, left: 4 })
        .width(44)
        .height(24)
        .fontSize(10)
        .opacity(0.55)
        .onClick(() => {
          this.showAccessibilitySelfCheck();
        })
    }
    .width('100%')
    .height('100%')
  }
}
