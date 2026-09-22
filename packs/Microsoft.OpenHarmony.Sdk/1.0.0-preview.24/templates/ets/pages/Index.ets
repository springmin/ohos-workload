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
import type common from '@ohos.app.ability.common';
import display from '@ohos.display';
import Want from '@ohos.app.ability.Want';
import wantConstant from '@ohos.app.ability.wantConstant';
import fileIo from '@ohos.file.fs';
import host from 'libopenharmonyhost.so';
import picker from '@ohos.file.picker';
import pasteboard from '@ohos.pasteboard';
import fs from '@ohos.file.fs';
import util from '@ohos.util';
import web_webview from '@ohos.web.webview';
import window from '@ohos.window';
// Device-compat (lazy SDK modules): the optional feature modules are deliberately NOT
// imported statically. A device whose framework lacks one of them would otherwise fail this
// page at load time (JsError), taking the whole bridge down. They are pulled in on first use
// with a guarded dynamic import() and a cached failure (see lazyUnavailable /
// noteLazyFailure below); the affected feature then keeps answering its existing
// "unavailable" result. The type-only imports below are erased by the ArkTS compiler
// (verified: they add no module record to modules.abc), so they only contribute the
// compile-time types used in annotations:
//   camera            - Camera Kit (flashlight, picker camera position)
//   calendarManager   - Calendar Kit
//   access            - Connectivity Kit (Bluetooth adapter state)
//   connection        - Network Kit (Connectivity change observer)
//   print             - Print Kit
//   commonEventManager, BusinessError - Basic Services Kit (battery events)
import type camera from '@ohos.multimedia.camera';
import type { calendarManager } from '@kit.CalendarKit';
import type { access } from '@kit.ConnectivityKit';
import type { connection } from '@kit.NetworkKit';
import type commonEventManager from '@ohos.commonEventManager';
import type print from '@ohos.print';
import type { BusinessError } from '@kit.BasicServicesKit';
// Geocoding (Essentials): the module itself is imported lazily (device-compat, see
// runGeocode); this type-only import is erased by the compiler and only names the request
// shapes used in annotations.
import type geoLocationManager from '@ohos.geoLocationManager';

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
  // Per-registration document id (B2/B3): the managed handler generates it, the shell stamps it
  // into the documents it serves (window.__ohHybridId, page end) and echoes it in every message
  // envelope, so the managed side can match a message to the page that registration loaded.
  id: string;
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
  // Per-registration document id (B1/B3), the Blazor counterpart of HybridAssetsConfig.id:
  // stamped into Blazor documents as window.__ohBlazorId and echoed in every message envelope.
  id: string;
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

// B6 navigation allow-list bridge: a main-frame load the shell did not originate is cancelled
// in onLoadIntercept and handed to the managed WebView handler for a Navigating decision. The
// shell keeps the URL it cancelled under an unguessable id; the managed handler approves the
// id back and only that stored URL may reload.
interface PendingNavigation {
  url: string;
  expires: number;
}

// One-shot marker that lets exactly one load pass onLoadIntercept without a managed round
// trip: the reload of an approved navigation, or a load the app requested through the
// managed WebView (WebCommand "load").
interface ApprovedNavigation {
  url: string;
  expires: number;
}

// Geocoding bridge (Essentials): the managed side sends (requestId, op, arg) through
// ohos_host_geocode_request. op 0 (address -> location) carries a JSON object of one address
// (GeoCodeRequest fields); op 1 (location -> address) carries "lat,lon". The shell answers
// host.geocodeResult(requestId, rc, json) with a JSON GeoAddress array on success and rc -1
// when the module, the permission or the service is unavailable.
interface GeocodeAddressQuery {
  description?: string;
  locale?: string;
  country?: string;
  maxItems?: number;
  minLatitude?: number;
  minLongitude?: number;
  maxLatitude?: number;
  maxLongitude?: number;
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
  // Per-registration document id (HybridAssetsConfig.id): stamped into matching documents and
  // echoed in the message envelope; '' means the page was not served for a registration.
  private hybridDocId: string = '';
  // MAUI's hybrid origin: HybridWebViewHandler.AppOrigin (https://0.0.0.1/).
  private hybridOrigin: string = 'https://0.0.0.1/';
  // Blazor asset bridge state (registered by the managed handler; empty -> no interception of
  // the Blazor origin, so hybrid pages are never touched). The origin always carries a trailing
  // '/' so the root document and its default file can be recognized textually.
  private blazorBase: string = '';
  private blazorRoot: string = '';
  private blazorDefaultFile: string = '';
  private blazorRegistered: boolean = false;
  // Per-registration document id (BlazorAssetsConfig.id), see hybridDocId.
  private blazorDocId: string = '';
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
  // Clipboard (Essentials): reading the pasteboard needs ohos.permission.READ_PASTEBOARD
  // (user_grant); the grant is cached and only an explicit GetTextAsync (op 1) may prompt. A
  // denied prompt is cached too, and the pasteboard 'update' observer (registered once, freed
  // in aboutToDisappear) never prompts.
  private clipboardReadGranted: boolean = false;
  private clipboardReadDenied: boolean = false;
  private clipboardObserverRegistered: boolean = false;
  private clipboardObserver: (() => void) | null = null;
  // Connectivity (Essentials): the NetworkKit connection observer registers once per page
  // (lazily imported; see subscribeNetworkChanges).
  private networkObserverRegistered: boolean = false;
  // Window chrome (Window handler): the managed title/rect setters push through the
  // registerWindowTitleSink/registerWindowRectSink handlers. The ArkUI window is resolved on
  // demand; setWindowTitle needs the SessionManager syscap (API 15+) and degrades by logging.
  // Shell search/flyout (Shell handler): the managed SearchHandler state and the flyout
  // section text pushed through registerShellSearchChangedSink/registerShellFlyoutChangedSink.
  // The search field below reports interactions back through host.notifyShellSearch (op 0
  // query changed, 1 submit, 2 cancel); the header/footer land in the panel labels.
  @State shellSearchQuery: string = '';
  @State shellSearchPlaceholder: string = '';
  @State shellSearchVisible: boolean = false;
  @State shellSearchEnabled: boolean = true;
  @State flyoutHeader: string = '';
  @State flyoutFooter: string = '';
  // Geocoding (Essentials): the reverse lookup reads the device location, which needs
  // ohos.permission.APPROXIMATELY_LOCATION (user_grant); the grant is cached once won.
  private locationGranted: boolean = false;
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
  // Device-compat (lazy SDK modules): each lazily imported module is imported once; its
  // failure is cached here so the feature keeps answering its existing "unavailable" result
  // without re-importing or re-logging on every request.
  private lazyFailures: Map<string, string> = new Map();
  // Camera Kit is preloaded asynchronously (dynamic import) because the flashlight sink is
  // synchronous: the API surface the sink needs is cached as soon as the module resolves,
  // and the sink answers false while the module is not there yet (or is unavailable).
  private cameraGetManager: ((context: common.Context) => camera.CameraManager) | undefined = undefined;
  private cameraTorchOn: camera.TorchMode | undefined = undefined;
  private cameraTorchOff: camera.TorchMode | undefined = undefined;
  private cameraBackPosition: camera.CameraPosition | undefined = undefined;
  // Host-export guard (device-compat): a libopenharmonyhost.so built by a different SDK can
  // lack an export. Every guarded call is logged once per API per page, not once per
  // event/frame, so a repetitive UI path cannot flood the log.
  private hostUnavailable: Set<string> = new Set();
  // B6 navigation allow-list state: a cancelled external navigation waits for the managed
  // Navigating decision under its unguessable id; navApproved/navProgrammatic are the one-shot
  // markers that let the shell's own reloads pass. All entries are time-bounded and dropped
  // when they expire.
  private navPending: Map<string, PendingNavigation> = new Map();
  private navApproved: ApprovedNavigation | null = null;
  private navProgrammatic: ApprovedNavigation | null = null;
  private navPendingLimit: number = 8;
  private navPendingTtlMs: number = 5000;
  private navMaxUrlLength: number = 8192;

  // Device-compat (lazy SDK modules): true when the named module failed its guarded dynamic
  // import on this device; the feature then takes its existing unavailable path.
  private lazyUnavailable(name: string): boolean {
    return this.lazyFailures.has(name);
  }

  // Device-compat (lazy SDK modules): records a dynamic-import failure once and logs the
  // reason once, so every later use answers "unavailable" without retrying or logging.
  private noteLazyFailure(name: string, error: Error | undefined): void {
    if (this.lazyFailures.has(name)) {
      return;
    }
    const detail: string = error !== undefined ? error.message : 'not available';
    this.lazyFailures.set(name, detail);
    console.error(`[maui] ${name} unavailable on this device: ${detail}`);
  }

  // Host-export guard (device-compat): logs a missing/failed host export once per page.
  private reportHostUnavailable(api: string, error: Error | undefined): void {
    if (this.hostUnavailable.has(api)) {
      return;
    }
    this.hostUnavailable.add(api);
    const detail: string = error !== undefined ? ` (${error.message})` : '';
    console.error(`[maui] host export unavailable: ${api}${detail}`);
  }

  // Host-export guard (device-compat): runs a host call behind an explicit existence check
  // and a try/catch so a mismatched .so cannot throw TypeError out of a page callback;
  // returns false when the call was not delivered. The native bridge core (XComponent
  // registration, registerJavaScriptProxy and the Web controller calls) is intentionally
  // not routed through this guard.
  private hostCall(api: string, available: boolean, call: () => void): boolean {
    if (!available) {
      this.reportHostUnavailable(api, undefined);
      return false;
    }
    try {
      call();
      return true;
    } catch (hostError) {
      this.reportHostUnavailable(api, hostError as Error);
      return false;
    }
  }

  // Forwards the current device colour mode (1 = dark, 0 = light) to the managed app.
  private reportTheme(): void {
    try {
      const mode: ColorMode | undefined = AppStorage.get<ColorMode>('colorMode');
      this.hostCall('notifyTheme', typeof host.notifyTheme === 'function', (): void => {
        host.notifyTheme(mode === ColorMode.DARK ? 1 : 0);
      });
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
  // export leaves the managed defaults in place. Device-compat: the Basic Services Kit is
  // imported lazily; a missing kit is cached and leaves the managed Unknown defaults.
  private async reportBattery(): Promise<void> {
    if (this.lazyUnavailable('basicServices')) {
      return;
    }
    try {
      const basicServices = await import('@kit.BasicServicesKit');
      try {
        const present: number = basicServices.batteryInfo.isBatteryPresent ? 1 : 0;
        const payload: string = `${basicServices.batteryInfo.batterySOC}\t${basicServices.batteryInfo.chargingStatus}\t${basicServices.batteryInfo.pluggedType}\t${present}\t${basicServices.power.getPowerMode()}`;
        this.hostCall('notifyBattery', typeof host.notifyBattery === 'function', (): void => {
          host.notifyBattery(payload);
        });
      } catch (batteryError) {
        // The managed side keeps its Unknown defaults.
      }
    } catch (kitError) {
      this.noteLazyFailure('basicServices', kitError as Error);
    }
  }

  // Display (Essentials): getDefaultDisplaySync returns the current display; the managed
  // OpenHarmonyDeviceDisplay turns "width\theight\tdensityDPI\trotation\trefreshRate\torientation"
  // into DisplayInfo (width/height px, density = densityDPI / 160).
  private reportDisplay(): void {
    try {
      const info = display.getDefaultDisplaySync();
      const payload: string = `${info.width}\t${info.height}\t${info.densityDPI}\t${info.rotation}\t${info.refreshRate}\t${info.orientation}`;
      this.hostCall('notifyDisplay', typeof host.notifyDisplay === 'function', (): void => {
        host.notifyDisplay(payload);
      });
    } catch (displayError) {
      // The managed side keeps its empty display info.
    }
  }

  // Battery changes arrive as common events (the platform publishes BATTERY_CHANGED on any
  // level/charging change, plus CHARGING/DISCHARGING/POWER_SAVE_MODE_CHANGED). Subscription is
  // best effort: a rejected subscription leaves the startup snapshot as the last value. The
  // kit is imported lazily (device-compat), so a missing Basic Services Kit only costs the
  // event-driven updates, not the page.
  private async subscribeBatteryEvents(): Promise<void> {
    if (this.batteryEventsRegistered || this.lazyUnavailable('basicServices')) {
      return;
    }
    try {
      const basicServices = await import('@kit.BasicServicesKit');
      try {
        const subscriber = basicServices.commonEventManager.createSubscriberSync({
          events: [
            basicServices.commonEventManager.Support.COMMON_EVENT_BATTERY_CHANGED,
            basicServices.commonEventManager.Support.COMMON_EVENT_CHARGING,
            basicServices.commonEventManager.Support.COMMON_EVENT_DISCHARGING,
            basicServices.commonEventManager.Support.COMMON_EVENT_POWER_SAVE_MODE_CHANGED,
          ],
        });
        basicServices.commonEventManager.subscribe(subscriber, (subscribeError: BusinessError, event: commonEventManager.CommonEventData): void => {
          if (!subscribeError) {
            this.reportBattery();
          }
        });
        this.batteryEventsRegistered = true;
      } catch (batteryEventError) {
        console.error(`[maui] battery events unavailable: ${(batteryEventError as Error).message}`);
      }
    } catch (kitError) {
      this.noteLazyFailure('basicServices', kitError as Error);
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

  // Connectivity (Essentials): the NetworkKit connection observer pushes a no-argument
  // host.notifyNetworkAccess(); the host re-reads the level through the same NDK path as
  // ohos_host_network_access and hands it to the managed OpenHarmonyConnectivity implementation.
  // Device-compat: NetworkKit is imported lazily; a missing kit is cached and only costs the
  // change events (the managed NetworkAccess property still reads the NDK path directly).
  private async subscribeNetworkChanges(): Promise<void> {
    if (this.networkObserverRegistered || this.lazyUnavailable('networkKit')) {
      return;
    }
    try {
      const kit = await import('@kit.NetworkKit');
      try {
        const netConnection = kit.connection.createNetConnection();
        netConnection.on('netAvailable', (_handle: connection.NetHandle): void => {
          this.reportNetworkAccess();
        });
        netConnection.on('netLost', (_handle: connection.NetHandle): void => {
          this.reportNetworkAccess();
        });
        netConnection.on('netCapabilitiesChange', (_info: connection.NetCapabilityInfo): void => {
          this.reportNetworkAccess();
        });
        netConnection.on('netUnavailable', (): void => {
          this.reportNetworkAccess();
        });
        this.networkObserverRegistered = true;
      } catch (networkObserverError) {
        this.noteLazyFailure('networkKit', networkObserverError as Error);
      }
    } catch (networkImportError) {
      this.noteLazyFailure('networkKit', networkImportError as Error);
    }
  }

  // Forward one observed network change; the host reads the current level itself.
  private reportNetworkAccess(): void {
    this.hostCall('notifyNetworkAccess', typeof host.notifyNetworkAccess === 'function', (): void => {
      host.notifyNetworkAccess();
    });
  }

  // Clipboard (Essentials): reading the pasteboard needs ohos.permission.READ_PASTEBOARD
  // (user_grant). Only an explicit get (op 1, GetTextAsync) may raise the system prompt: the
  // HasText path (op 0) and the pasteboard 'update' observer use the cached grant plus a
  // non-prompting getSelfPermissionStatus query, and a denied prompt is cached so no background
  // path can re-ask. The permission must be declared by the app (the pack's
  // OpenHarmonyExtraPermissions switch appends it to requestPermissions).
  private async ensureClipboardReadPermission(prompt: boolean): Promise<boolean> {
    if (this.clipboardReadGranted || this.clipboardPermissionGranted()) {
      this.clipboardReadGranted = true;
      this.clipboardReadDenied = false;
      return true;
    }
    if (!prompt || this.clipboardReadDenied) {
      return false;
    }
    try {
      const context = getContext(this) as common.UIAbilityContext;
      const permissions: Permissions[] = ['ohos.permission.READ_PASTEBOARD'];
      const atManager = abilityAccessCtrl.createAtManager();
      const granted = await atManager.requestPermissionsFromUser(context, permissions);
      this.clipboardReadGranted = granted.authResults.length > 0 && granted.authResults[0] === 0;
      this.clipboardReadDenied = !this.clipboardReadGranted;
      return this.clipboardReadGranted;
    } catch (clipboardPermissionError) {
      this.clipboardReadDenied = true;
      console.error(`[maui] clipboard permission request failed: ${(clipboardPermissionError as Error).message}`);
      return false;
    }
  }

  // Clipboard (Essentials): non-prompting READ_PASTEBOARD query. getSelfPermissionStatus only
  // reports the current state (API 20+), so a grant made in settings is seen without a prompt;
  // any failure (including an older device without the query) leaves the cached grant in charge.
  private clipboardPermissionGranted(): boolean {
    try {
      const atManager = abilityAccessCtrl.createAtManager();
      return atManager.getSelfPermissionStatus('ohos.permission.READ_PASTEBOARD') ===
        abilityAccessCtrl.PermissionStatus.GRANTED;
    } catch (clipboardStatusError) {
      return false;
    }
  }

  // Reads the primary text of the pasteboard ('' when there is no data or no plain text).
  private readClipboardText(systemPasteboard: pasteboard.SystemPasteboard): string {
    if (!systemPasteboard.hasDataSync()) {
      return '';
    }
    const data = systemPasteboard.getDataSync();
    if (data.getPrimaryMimeType() !== pasteboard.MIMETYPE_TEXT_PLAIN) {
      return '';
    }
    return data.getPrimaryText();
  }

  // Keep screen on (DeviceDisplay): the managed setter asks through
  // ohos_host_keep_screen_on(on) (0 = release, 1 = keep on). The last window is resolved on
  // demand through the same getLastWindow path the avoid-area report uses and the
  // asynchronous setWindowKeepScreenOn result is only logged; a rejected call leaves the
  // managed cached value as it was, since the host call only reports the queueing.
  private applyKeepScreenOn(on: number): void {
    window.getLastWindow(getContext(this)).then((win) => {
      return win.setWindowKeepScreenOn(on === 1);
    }).catch((keepScreenOnError: Error): void => {
      console.error(`[maui] keep screen on failed: ${keepScreenOnError.message}`);
    });
  }

  // Window chrome: the managed title setter pushes through ohos_host_set_window_title. The
  // main window is resolved on demand (the same getLastWindow path the avoid-area report and
  // keep-screen-on use). setWindowTitle is a SessionManager API (15+), so a device without the
  // syscap rejects the promise; that is logged and leaves the shell title in place.
  private applyWindowTitle(title: string): void {
    window.getLastWindow(getContext(this)).then((win) => {
      return win.setWindowTitle(title);
    }).catch((windowTitleError: Error): void => {
      console.error(`[maui] set window title failed: ${windowTitleError.message}`);
    });
  }

  // Window chrome: the managed rect setter pushes through ohos_host_set_window_rect; the
  // position and size are applied with moveWindowTo + resize (API 11+), both asynchronous.
  private applyWindowRect(x: number, y: number, w: number, h: number): void {
    window.getLastWindow(getContext(this)).then((win) => {
      return win.moveWindowTo(x, y).then(() => {
        return win.resize(w, h);
      });
    }).catch((windowRectError: Error): void => {
      console.error(`[maui] set window rect failed: ${windowRectError.message}`);
    });
  }

  // Screenshot path containment: canonicalize the requested output path and accept it only
  // when the canonical form stays under the app's temp or cache dir. '..' segments are rejected
  // outright, and every existing component below the matched root is lstat'ed, so a symlinked
  // parent (or a pre-existing symlinked target) cannot redirect the PNG outside the app dirs.
  // Returns the canonical path, or null when the request must be rejected.
  private canonicalScreenshotPath(outPath: string): string | null {
    // The host caps the path at 4 KiB too; reject instead of writing anything surprising.
    if (outPath.length === 0 || outPath.length > 4096 || !outPath.startsWith('/')) {
      return null;
    }
    const normalized: string[] = [];
    const segments: string[] = outPath.split('/');
    for (let i = 0; i < segments.length; i++) {
      const segment: string = segments[i];
      if (segment.length === 0 || segment === '.') {
        continue;
      }
      if (segment === '..') {
        return null;
      }
      normalized.push(segment);
    }
    if (normalized.length === 0) {
      return null;
    }
    const canonical: string = '/' + normalized.join('/');
    const context = getContext(this) as common.UIAbilityContext;
    const roots: string[] = [context.tempDir, context.cacheDir];
    let root: string = '';
    for (let i = 0; i < roots.length; i++) {
      let candidate: string = roots[i];
      if (!candidate.endsWith('/')) {
        candidate = candidate + '/';
      }
      if (canonical.startsWith(candidate)) {
        root = candidate;
        break;
      }
    }
    if (root.length === 0) {
      return null;
    }
    // A missing final component is fine (the capture creates it); a missing parent is not, and a
    // symlink anywhere on the way to the target (or the target itself when it already exists)
    // rejects the request.
    const relative: string[] = canonical.substring(root.length).split('/');
    let current: string = root;
    for (let i = 0; i < relative.length; i++) {
      current = current + relative[i];
      const isLast: boolean = i === relative.length - 1;
      try {
        if (fileIo.lstatSync(current).isSymbolicLink()) {
          return null;
        }
      } catch (pathError) {
        if (!isLast) {
          return null;
        }
      }
      if (!isLast) {
        current = current + '/';
      }
    }
    return canonical;
  }

  // Screenshot: the managed side passes an app-owned output path through
  // ohos_host_screenshot; the shell snapshots the main window and writes it as a PNG. The
  // output path must resolve under the app temp/cache dirs (see canonicalScreenshotPath). The
  // image packer is imported lazily (device-compat), and the packer, the file descriptor and
  // the pixel map are released on every path. Returns 0 when the PNG was written, -1 otherwise.
  private async captureScreenshot(outPath: string): Promise<number> {
    let safePath: string | null = null;
    try {
      safePath = this.canonicalScreenshotPath(outPath);
    } catch (pathError) {
      console.error(`[maui] screenshot path check failed: ${(pathError as Error).message}`);
      return -1;
    }
    if (safePath === null) {
      console.error('[maui] screenshot rejected: output path is not under the app temp/cache dir');
      return -1;
    }
    if (this.lazyUnavailable('imagePacker')) {
      return -1;
    }
    try {
      const image = await import('@ohos.multimedia.image');
      try {
        const win = await window.getLastWindow(getContext(this));
        const pixelMap = await win.snapshot();
        const packer = image.default.createImagePacker();
        const file = fileIo.openSync(safePath, fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE
          | fileIo.OpenMode.TRUNC);
        try {
          await packer.packToFile(pixelMap, file.fd, { format: 'image/png', quality: 100 });
          return 0;
        } finally {
          fileIo.closeSync(file);
          await packer.release();
          await pixelMap.release();
        }
      } catch (screenshotError) {
        console.error(`[maui] screenshot failed: ${(screenshotError as Error).message}`);
        return -1;
      }
    } catch (imageImportError) {
      this.noteLazyFailure('imagePacker', imageImportError as Error);
      return -1;
    }
  }

  // Geocoding (Essentials): op 0 (address -> location) parses a JSON object with at least a
  // description and calls getAddressesFromLocationName; op 1 (location -> address) parses
  // "lat,lon", asks for the location permission (the device location is user_grant) and calls
  // getAddressesFromLocation. The module is imported lazily; any failure answers rc -1 with an
  // empty JSON so the managed caller degrades without throwing.
  private async runGeocode(requestId: number, op: number, arg: string): Promise<void> {
    let rc: number = -1;
    let json: string = '';
    if (this.lazyUnavailable('geoLocationManager')) {
      this.answerGeocode(requestId, rc, json);
      return;
    }
    try {
      const geo = await import('@ohos.geoLocationManager');
      if (op === 0) {
        const query = JSON.parse(arg) as GeocodeAddressQuery;
        if (query.description !== undefined && query.description.length > 0) {
          const request: geoLocationManager.GeoCodeRequest = { description: query.description };
          if (query.locale !== undefined) { request.locale = query.locale; }
          if (query.country !== undefined) { request.country = query.country; }
          if (query.maxItems !== undefined) { request.maxItems = query.maxItems; }
          if (query.minLatitude !== undefined) { request.minLatitude = query.minLatitude; }
          if (query.minLongitude !== undefined) { request.minLongitude = query.minLongitude; }
          if (query.maxLatitude !== undefined) { request.maxLatitude = query.maxLatitude; }
          if (query.maxLongitude !== undefined) { request.maxLongitude = query.maxLongitude; }
          const addresses = await geo.default.getAddressesFromLocationName(request);
          json = JSON.stringify(addresses);
          rc = 0;
        }
      } else if (op === 1) {
        const parts: string[] = arg.split(',');
        const latitude: number = parts.length > 0 ? Number.parseFloat(parts[0]) : Number.NaN;
        const longitude: number = parts.length > 1 ? Number.parseFloat(parts[1]) : Number.NaN;
        if (Number.isFinite(latitude) && Number.isFinite(longitude) && await this.ensureLocationPermission()) {
          const request: geoLocationManager.ReverseGeoCodeRequest = {
            latitude: latitude,
            longitude: longitude
          };
          const addresses = await geo.default.getAddressesFromLocation(request);
          json = JSON.stringify(addresses);
          rc = 0;
        }
      }
    } catch (geocodeError) {
      console.error(`[maui] geocode op ${op} failed: ${(geocodeError as Error).message}`);
    }
    this.answerGeocode(requestId, rc, json);
  }

  // Geocoding (Essentials): completes the pending managed request through host.geocodeResult.
  private answerGeocode(requestId: number, rc: number, json: string): void {
    this.hostCall('geocodeResult', typeof host.geocodeResult === 'function', (): void => {
      host.geocodeResult(requestId, rc, json);
    });
  }

  // Geocoding (Essentials): the reverse lookup needs ohos.permission.APPROXIMATELY_LOCATION
  // (user_grant), requested on demand and cached once won. A rejected request (for example the
  // permission is not declared by the app) leaves the feature answering rc -1.
  private async ensureLocationPermission(): Promise<boolean> {
    if (this.locationGranted) {
      return true;
    }
    try {
      const context = getContext(this) as common.UIAbilityContext;
      const permissions: Permissions[] = ['ohos.permission.APPROXIMATELY_LOCATION'];
      const atManager = abilityAccessCtrl.createAtManager();
      const granted = await atManager.requestPermissionsFromUser(context, permissions);
      this.locationGranted = granted.authResults.length > 0 && granted.authResults[0] === 0;
    } catch (locationPermissionError) {
      console.error(`[maui] location permission request failed: ${(locationPermissionError as Error).message}`);
    }
    return this.locationGranted;
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
      this.reportHostUnavailable('menuCount', menuError as Error);
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
          this.hostCall('notifyMenuAction', typeof host.notifyMenuAction === 'function', (): void => {
            host.notifyMenuAction(index);
          });
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
          // ArkWeb registers the proxy into every frame, but the managed side trusts the
          // __OHORIGIN envelope built below. Drop the call when the calling frame url is a
          // known non-empty url that is not the main document's; empty/unknown values fail
          // open and the returned url's exact device semantics still need validation.
          let callerUrl: string = '';
          try {
            if (typeof this.webController.getLastJavascriptProxyCallingFrameUrl === 'function') {
              callerUrl = this.webController.getLastJavascriptProxyCallingFrameUrl();
            }
          } catch (callingError) {
            callerUrl = '';
          }
          if (typeof callerUrl === 'string' && callerUrl.length > 0) {
            let mainUrl: string = '';
            try {
              mainUrl = this.webController.getUrl();
            } catch (urlError) {
              mainUrl = '';
            }
            if (callerUrl !== mainUrl) {
              return;
            }
          }
          this.hostCall('notifyJsMessage', typeof host.notifyJsMessage === 'function', (): void => {
            host.notifyJsMessage(this.originEnvelope(payload));
          });
        }
      }, 'dotnetHost', ['postMessage']);
      this.dotNetHostRegistered = true;
    } catch (proxyError) {
      console.error(`[maui] dotnetHost proxy registration failed: ${(proxyError as Error).message}`);
    }
  }

  // Document-origin envelope (B1/B2/B3): the shell prefixes every payload it delivers to the
  // managed side with "__OHORIGIN|<document url>|<document id>\n". The page cannot write the
  // header (only this proxy prepends it), so a handler can trust it: the url says whether the
  // message comes from the handler's own page origin and the id says whether the document is
  // one the shell served and stamped for that registration (window.__ohHybridId /
  // window.__ohBlazorId, see injectPageBridge). A document the shell did not stamp carries an
  // empty id, which every handler treats as a mismatch. getUrl() is synchronous but may throw
  // before a controller is attached; an unknown url is reported empty and fails the match too.
  private originEnvelope(payload: string): string {
    let url: string = '';
    try {
      url = this.webController.getUrl();
    } catch (urlError) {
      url = '';
    }
    let documentId: string = '';
    if (this.hybridRegistered && this.hybridDocId.length > 0 && url.startsWith(this.hybridOrigin)) {
      documentId = this.hybridDocId;
    } else if (this.blazorRegistered && this.blazorDocId.length > 0 && url.startsWith(this.blazorOrigin)) {
      documentId = this.blazorDocId;
    }
    return `__OHORIGIN|${url}|${documentId}\n${payload}`;
  }

  // B6: true for the URLs that belong to the app's own content - the hybrid/Blazor app
  // origins, local files, inline/in-page documents and relative references - which keep
  // loading exactly as before (no managed round trip).
  private isAppNavigation(url: string): boolean {
    if (url.length === 0 || url.charAt(0) === '/' || url.charAt(0) === '#' || url.charAt(0) === '?') {
      return true;
    }
    if (url.startsWith('about:') || url.startsWith('data:') || url.startsWith('blob:') ||
        url.startsWith('javascript:') || url.startsWith('file:')) {
      return true;
    }
    if (this.hybridRegistered && url.startsWith(this.hybridOrigin)) {
      return true;
    }
    if (this.blazorRegistered && url.startsWith(this.blazorOrigin)) {
      return true;
    }
    return false;
  }

  // B6: consumes a one-shot marker for a load the shell itself requested (WebCommand "load")
  // or one the managed handler approved. The marker lets exactly that reload pass
  // onLoadIntercept without another managed round trip (loop guard); expired markers are stale.
  private consumeApprovedNavigation(url: string): boolean {
    const now: number = Date.now();
    const programmatic: ApprovedNavigation | null = this.navProgrammatic;
    if (programmatic !== null && programmatic.expires >= now && programmatic.url === url) {
      this.navProgrammatic = null;
      return true;
    }
    const approved: ApprovedNavigation | null = this.navApproved;
    if (approved !== null && approved.expires >= now && approved.url === url) {
      this.navApproved = null;
      return true;
    }
    return false;
  }

  // B6: retires a marker once the approved/app-requested load actually started, so a later
  // page-initiated navigation to the same URL is asked about again.
  private retireNavigationMarker(url: string): void {
    const programmatic: ApprovedNavigation | null = this.navProgrammatic;
    if (programmatic !== null && programmatic.url === url) {
      this.navProgrammatic = null;
    }
    const approved: ApprovedNavigation | null = this.navApproved;
    if (approved !== null && approved.url === url) {
      this.navApproved = null;
    }
  }

  // B6: asks the managed handler for a Navigating decision on a cancelled main-frame load.
  // The URL stays with the shell (the managed side only sees it to decide); the id is
  // unguessable and short-lived, the pending table is bounded, and the oldest entry is
  // dropped when it is full.
  private askManagedAboutNavigation(url: string): void {
    const now: number = Date.now();
    this.navPending.forEach((pending: PendingNavigation, id: string): void => {
      if (pending.expires < now) {
        this.navPending.delete(id);
      }
    });
    while (this.navPending.size >= this.navPendingLimit) {
      const oldest: string | undefined = this.navPending.keys().next().value;
      if (oldest === undefined) {
        break;
      }
      this.navPending.delete(oldest);
    }
    let id: string = '';
    try {
      id = util.generateRandomUUID(true);
    } catch (uuidError) {
      id = `${now.toString(16)}-${Math.random().toString(16).substring(2)}`;
    }
    this.navPending.set(id, { url: url, expires: now + this.navPendingTtlMs });
    const delivered: boolean = this.hostCall('notifyJsMessage', typeof host.notifyJsMessage === 'function', (): void => {
      host.notifyJsMessage(`__OHNAV|${url}|${id}`);
    });
    if (!delivered) {
      // No host channel: nothing can approve the load, so it stays cancelled.
      this.navPending.delete(id);
    }
  }

  // B6: the managed handler answers an intercepted navigation (WebCommand op "nav"); the
  // argument is "<id>\n<url>". The URL must be the exact one the shell cancelled for that id,
  // and the approval is one-shot: only the reload that follows may pass.
  private approveNavigation(arg: string): void {
    const separator: number = arg.indexOf('\n');
    const id: string = separator >= 0 ? arg.substring(0, separator) : arg;
    const url: string = separator >= 0 ? arg.substring(separator + 1) : '';
    const pending: PendingNavigation | undefined = this.navPending.get(id);
    if (pending === undefined) {
      return;
    }
    this.navPending.delete(id);
    if (pending.expires < Date.now() || pending.url !== url) {
      return;
    }
    this.navApproved = { url: pending.url, expires: Date.now() + this.navPendingTtlMs };
    try {
      this.webController.loadUrl(pending.url);
    } catch (approvalError) {
      // The reload failed (e.g., the controller detached); the navigation stays cancelled.
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
  //
  // Per-document marker (B3): the shell stamps the registration id into documents it served for
  // the matching origin only. A managed handler refuses host -> page deliveries when the loaded
  // document no longer carries its id (reload before the stamp, or a navigation by another
  // page), so scripts never land in a foreign document.
  private injectPageBridge(pageUrl: string): void {
    let markers: string = '';
    if (this.hybridRegistered && this.hybridDocId.length > 0 && pageUrl.startsWith(this.hybridOrigin)) {
      markers += `window.__ohHybridId = ${JSON.stringify(this.hybridDocId)};`;
    }
    if (this.blazorRegistered && this.blazorDocId.length > 0 && pageUrl.startsWith(this.blazorOrigin)) {
      markers += `window.__ohBlazorId = ${JSON.stringify(this.blazorDocId)};`;
    }
    try {
      this.webController.runJavaScript(
        `(function () {
          ${markers}
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

  // Device-compat (lazy SDK modules): @ohos.multimedia.camera is imported dynamically (the
  // device may lack it), so the API surface the synchronous flashlight sink needs is
  // preloaded once and cached here. A failed import is cached too and the feature degrades.
  private async preloadCamera(): Promise<void> {
    if (this.cameraGetManager !== undefined || this.lazyUnavailable('camera')) {
      return;
    }
    try {
      const cams = await import('@ohos.multimedia.camera');
      this.cameraGetManager = (context: common.Context): camera.CameraManager => cams.default.getCameraManager(context);
      this.cameraTorchOn = cams.default.TorchMode.ON;
      this.cameraTorchOff = cams.default.TorchMode.OFF;
      this.cameraBackPosition = cams.default.CameraPosition.CAMERA_POSITION_BACK;
    } catch (cameraLoadError) {
      this.noteLazyFailure('camera', cameraLoadError as Error);
    }
  }

  // Flashlight: creates the camera manager (Camera Kit) once and caches it. The preloaded
  // factory is undefined until the lazy import resolves (or when the device has no camera
  // module), and the sink then answers false. getCameraManager throws when the camera service
  // is unavailable; the sink catches and answers false, and drops the cached manager so the
  // next request retries from a clean state.
  private ensureFlashlightManager(): camera.CameraManager | undefined {
    let manager: camera.CameraManager | undefined = this.flashlightManager;
    if (manager === undefined && this.cameraGetManager !== undefined) {
      manager = this.cameraGetManager(getContext(this));
      this.flashlightManager = manager;
    }
    return manager;
  }

  // B4 (reversible record encoding): the platform extras join kit-provided names and fields
  // into tab/newline delimited records. A contact name, a calendar title or a device name may
  // itself contain '\t', '\n', '\r' or '\' (a contact name can be anything), which would forge
  // or split records at the managed parser; every field is escaped before the join:
  //   '\' -> '\\'   tab -> '\t'   LF -> '\n'   CR -> '\r'
  // The managed parsers split on the raw separators first and then decode each field with the
  // exact reverse mapping (one left-to-right pass over the field). The encoder is injective
  // (only '\', 't', 'n', 'r' after a backslash are meaningful), so decoding restores the
  // original string byte-for-byte.
  private escapeRecordField(value: string): string {
    let escaped: string = '';
    for (let i = 0; i < value.length; i++) {
      const ch: string = value.charAt(i);
      if (ch === '\\') {
        escaped += '\\\\';
      } else if (ch === '\t') {
        escaped += '\\t';
      } else if (ch === '\n') {
        escaped += '\\n';
      } else if (ch === '\r') {
        escaped += '\\r';
      } else {
        escaped += ch;
      }
    }
    return escaped;
  }

  aboutToAppear(): void {
    // 2 = foreground; the native host forwards it to the managed bridge.
    this.hostCall('notifyLifecycle', typeof host.notifyLifecycle === 'function', (): void => {
      host.notifyLifecycle(2);
    });
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
    this.subscribeNetworkChanges();
    // Device-compat (lazy SDK modules): the camera module is needed by the synchronous
    // flashlight sink and by the picker's camera position, so it is preloaded once here.
    this.preloadCamera();
    // Keep screen on (DeviceDisplay): the managed setter pushes 0/1 through
    // ohos_host_keep_screen_on. Best effort: an older host library without the export leaves
    // the managed cached value unchanged instead of failing the page.
    this.hostCall('registerKeepScreenOnSink', typeof host.registerKeepScreenOnSink === 'function', (): void => {
      host.registerKeepScreenOnSink((on: number): void => {
        this.applyKeepScreenOn(on);
      });
    });
    // Window chrome (Window handler): the managed title/rect setters arrive here and are
    // applied to the main window. Both are one-way: the .so's 0/-1 only reports the queueing.
    this.hostCall('registerWindowTitleSink', typeof host.registerWindowTitleSink === 'function', (): void => {
      host.registerWindowTitleSink((title: string): void => {
        this.applyWindowTitle(title);
      });
    });
    this.hostCall('registerWindowRectSink', typeof host.registerWindowRectSink === 'function', (): void => {
      host.registerWindowRectSink((x: number, y: number, w: number, h: number): void => {
        this.applyWindowRect(x, y, w, h);
      });
    });
    // Screenshot (Window handler): a one-way request carrying an app-owned output path.
    this.hostCall('registerScreenshotSink', typeof host.registerScreenshotSink === 'function', (): void => {
      host.registerScreenshotSink(async (outPath: string): Promise<void> => {
        await this.captureScreenshot(outPath);
      });
    });
    // Shell search/flyout (Shell handler): the managed SearchHandler state and the flyout
    // section text. A registration after the managed publish can miss the first push, so the
    // hosts' stored getters seed the labels; the search field reports user interactions back
    // through host.notifyShellSearch (0 query, 1 submit, 2 cancel).
    this.hostCall('registerShellSearchChangedSink', typeof host.registerShellSearchChangedSink === 'function', (): void => {
      host.registerShellSearchChangedSink((query: string, placeholder: string, visible: number, enabled: number): void => {
        this.shellSearchQuery = query;
        this.shellSearchPlaceholder = placeholder;
        this.shellSearchVisible = visible !== 0;
        this.shellSearchEnabled = enabled !== 0;
      });
    });
    this.hostCall('registerShellFlyoutChangedSink', typeof host.registerShellFlyoutChangedSink === 'function', (): void => {
      host.registerShellFlyoutChangedSink((op: number, text: string): void => {
        if (op === 0) {
          this.flyoutHeader = text;
        } else if (op === 1) {
          this.flyoutFooter = text;
        }
      });
    });
    this.hostCall('shellSearchQuery', typeof host.shellSearchQuery === 'function', (): void => {
      this.shellSearchQuery = host.shellSearchQuery() as string;
      this.shellSearchPlaceholder = host.shellSearchPlaceholder() as string;
      this.shellSearchVisible = (host.shellSearchVisible() as number) !== 0;
      this.shellSearchEnabled = (host.shellSearchEnabled() as number) !== 0;
    });
    this.hostCall('shellFlyoutHeader', typeof host.shellFlyoutHeader === 'function', (): void => {
      this.flyoutHeader = host.shellFlyoutHeader() as string;
      this.flyoutFooter = host.shellFlyoutFooter() as string;
    });
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
      this.hostCall('notifyAvoidArea', typeof host.notifyAvoidArea === 'function', (): void => {
        host.notifyAvoidArea(area.topRect.height, area.bottomRect.height,
                             area.leftRect.width, area.rightRect.width);
      });
    }).catch(() => {
      // Window information is optional.
    });

    // WebView: a hidden ArkWeb component that the managed WebView handler drives.
    // Host callback: every controller call runs on the page's UI thread (see runOnUiThread).
    this.hostCall('registerWebSink', typeof host.registerWebSink === 'function', (): void => {
      host.registerWebSink((op: string, arg: string) => {
        this.runOnUiThread(() => {
          try {
            if (op === 'show') {
              this.webVisible = true;
            } else if (op === 'hide') {
              this.webVisible = false;
            } else if (op === 'load') {
              this.webVisible = true;
              // B6: the app asked for this URL; let this one load through without a round trip.
              this.navProgrammatic = { url: arg, expires: Date.now() + this.navPendingTtlMs };
              this.webController.loadUrl(arg);
            } else if (op === 'nav') {
              // B6: the managed handler's answer to an intercepted navigation.
              this.approveNavigation(arg);
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
    });

    // JavaScript bridge: the managed side evaluates scripts through ohos_host_web_eval; the
    // runJavaScript result (or its error) travels back to the awaiting request.
    // Host callback: runJavaScript is UI-thread only (see runOnUiThread).
    this.hostCall('registerWebEvalSink', typeof host.registerWebEvalSink === 'function', (): void => {
      host.registerWebEvalSink((script: string, requestId: number): void => {
        this.runOnUiThread(() => {
          try {
            this.webController.runJavaScript(script, (err, result) => {
              this.hostCall('notifyWebEvalResult', typeof host.notifyWebEvalResult === 'function', (): void => {
                host.notifyWebEvalResult(requestId, result || '', err ? 1 : 0);
              });
            });
          } catch (evalError) {
            this.hostCall('notifyWebEvalResult', typeof host.notifyWebEvalResult === 'function', (): void => {
              host.notifyWebEvalResult(requestId, '', 1);
            });
          }
        });
      });
    });

    // HybridWebView JS -> .NET invocation results: the managed handler answers a
    // host.notifyHybridInvoke call through ohos_host_hwv_invoke_result, which lands here and
    // completes the delayed __hwvInvokeDotNet response.
    this.hostCall('registerHybridInvokeResultSink', typeof host.registerHybridInvokeResultSink === 'function', (): void => {
      host.registerHybridInvokeResultSink((requestId: number, payload: string): void => {
        this.completeHybridInvoke(requestId, payload);
      });
    });

    // File/media pickers: the managed side asks for the system picker; the chosen file's name
    // and bytes travel back as base64 through host.notifyPickerResult.
    //
    // Request kind (managed OpenHarmonyPickerClient.PackKind):
    //   bits 0-2  mode: 0 documents, 1 photos, 2 videos, 3 capture photo, 4 capture video
    //   bit 3     multi-select; the legacy kinds 0-4 (bit 3 clear) stay single-select
    //   bits 4+   requested maxSelectNumber for a multi request (0 = the picker maximum, 500)
    // Result framing: one rc=0 per file; a multi pick is followed by rc=1 (end marker) so the
    // managed accumulator can complete, and a cancel/unavailable pick answers rc=-1.
    //
    // Modes 1/2 use the photoAccessHelper PhotoViewPicker (media-only gallery UI; the
    // @ohos.file.picker PhotoViewPicker is deprecated in its favour) and modes 3/4 are the
    // separate camera-capture path (cameraPicker). Device-compat: photoAccessHelper, camera
    // and cameraPicker are imported lazily; when camera/cameraPicker is missing the capture
    // branch answers -1 (the managed side reports IsSupported == false), and when
    // photoAccessHelper is missing photo/video picking falls back to the document picker.
    this.hostCall('registerPickerSink', typeof host.registerPickerSink === 'function', (): void => {
      host.registerPickerSink(async (requestId: number, kind: number) => {
        const mode: number = kind & 7;
        const multi: boolean = (kind & 8) !== 0;
        const rawCount: number = kind >> 4;
        const count: number = multi ? (rawCount === 0 ? 500 : Math.min(rawCount, 500)) : 1;
        if (mode === 3 || mode === 4) {
          if (this.lazyUnavailable('camera') || this.lazyUnavailable('cameraPicker')) {
            this.hostCall('notifyPickerResult', typeof host.notifyPickerResult === 'function', (): void => {
              host.notifyPickerResult(requestId, -1, '', '');
            });
            return;
          }
          // The camera position normally comes from the startup preload; a request that
          // arrives before the preload resolved imports the module here instead, so the
          // camera branch never loses a pick to the lazy-loading race.
          let cameraPosition: camera.CameraPosition | undefined = this.cameraBackPosition;
          if (cameraPosition === undefined) {
            try {
              const cams = await import('@ohos.multimedia.camera');
              cameraPosition = cams.default.CameraPosition.CAMERA_POSITION_BACK;
              this.cameraBackPosition = cameraPosition;
            } catch (cameraPickImportError) {
              this.noteLazyFailure('camera', cameraPickImportError as Error);
            }
          }
          if (cameraPosition === undefined) {
            this.hostCall('notifyPickerResult', typeof host.notifyPickerResult === 'function', (): void => {
              host.notifyPickerResult(requestId, -1, '', '');
            });
            return;
          }
          const backPosition: camera.CameraPosition = cameraPosition;
          try {
            const pickers = await import('@ohos.multimedia.cameraPicker');
            try {
              const mediaType = mode === 3 ? pickers.default.PickerMediaType.PHOTO : pickers.default.PickerMediaType.VIDEO;
              const picked = await pickers.default.pick(getContext(this), [mediaType], {
                cameraPosition: backPosition,
              });
              const captureUri: string = picked.resultUri;
              const captureName: string = captureUri.substring(captureUri.lastIndexOf('/') + 1);
              const captureFile = fileIo.openSync(captureUri, fileIo.OpenMode.READ_ONLY);
              const captureBuffer = new ArrayBuffer(fileIo.statSync(captureUri).size);
              fileIo.readSync(captureFile.fd, captureBuffer);
              fileIo.closeSync(captureFile);
              const captureBase64 = new util.Base64Helper().encodeToStringSync(new Uint8Array(captureBuffer));
              this.hostCall('notifyPickerResult', typeof host.notifyPickerResult === 'function', (): void => {
                host.notifyPickerResult(requestId, 0, captureName, captureBase64);
              });
            } catch (captureError) {
              console.error(`camera capture failed: ${(captureError as Error).message}`);
              this.hostCall('notifyPickerResult', typeof host.notifyPickerResult === 'function', (): void => {
                host.notifyPickerResult(requestId, -1, '', '');
              });
            }
          } catch (pickerImportError) {
            this.noteLazyFailure('cameraPicker', pickerImportError as Error);
            this.hostCall('notifyPickerResult', typeof host.notifyPickerResult === 'function', (): void => {
              host.notifyPickerResult(requestId, -1, '', '');
            });
          }
          return;
        }
        if (mode === 1 || mode === 2) {
          // Media (photos/videos) goes through the photoAccessHelper PhotoViewPicker first;
          // null means the module is missing on this device (cached), so the request falls
          // back to the document picker below - the pre-photoAccessHelper behaviour.
          const mediaUris: string[] | null = await this.selectMediaUris(mode, count);
          if (mediaUris !== null) {
            if (mediaUris.length === 0) {
              this.answerPickerCancel(requestId);
            } else {
              this.answerPickerFiles(requestId, multi, mediaUris);
            }
            return;
          }
        }
        // Documents (and the media fallback) stay on the static @ohos.file.picker /
        // @ohos.file.fs imports, with the caller's maxSelectNumber (1 for single-select).
        await this.selectDocumentUris(requestId, multi, count);
      });
    });

    // Runtime permissions (Essentials IPermissions.RequestAsync): the managed side asks for one
    // permission through ohos_host_request_permission; the prompt runs through
    // abilityAccessCtrl (a core module, imported statically) and the answer travels back as
    // host.permissionResult(id, granted) so the managed request completes (deny on timeout).
    this.hostCall('registerPermissionSink', typeof host.registerPermissionSink === 'function', (): void => {
      host.registerPermissionSink(async (permission: string, requestId: number): Promise<void> => {
        let granted: boolean = false;
        try {
          const context = getContext(this) as common.UIAbilityContext;
          const permissions: Permissions[] = [permission as Permissions];
          const atManager = abilityAccessCtrl.createAtManager();
          const result = await atManager.requestPermissionsFromUser(context, permissions);
          granted = result.authResults.length > 0 && result.authResults[0] === 0;
        } catch (permissionError) {
          console.error(`[maui] permission request failed: ${(permissionError as Error).message}`);
        }
        this.hostCall('permissionResult', typeof host.permissionResult === 'function', (): void => {
          host.permissionResult(requestId, granted ? 1 : 0);
        });
      });
    });

    // Clipboard (Essentials IClipboard): the managed side sends (requestId, op, text) through
    // ohos_host_clipboard_request (op 0 has / 1 get / 2 set); the shell runs the pasteboard
    // call and answers with host.clipboardResult(id, rc, text). Only an explicit get (op 1,
    // GetTextAsync) may raise the READ_PASTEBOARD prompt (op === 1 below); the has path never
    // prompts, writing (op 2) needs no permission, and the 'update' observer below only pushes
    // host.notifyClipboardChanged, so HasText/ClipboardContentChanged work without prompts.
    this.hostCall('registerClipboardSink', typeof host.registerClipboardSink === 'function', (): void => {
      host.registerClipboardSink(async (requestId: number, op: number, text: string): Promise<void> => {
        let rc: number = -1;
        let value: string = '';
        try {
          const systemPasteboard = pasteboard.getSystemPasteboard();
          if (op === 0 || op === 1) {
            if (await this.ensureClipboardReadPermission(op === 1)) {
              rc = 0;
              const clipboardText: string = this.readClipboardText(systemPasteboard);
              value = op === 0 ? (clipboardText.length > 0 ? '1' : '0') : clipboardText;
            }
          } else if (op === 2) {
            systemPasteboard.setDataSync(pasteboard.createPlainTextData(text));
            rc = 0;
          }
        } catch (clipboardError) {
          console.error(`[maui] clipboard op ${op} failed: ${(clipboardError as Error).message}`);
        }
        this.hostCall('clipboardResult', typeof host.clipboardResult === 'function', (): void => {
          host.clipboardResult(requestId, rc, value);
        });
      });
    });
    if (!this.clipboardObserverRegistered) {
      try {
        // The observer is stored so aboutToDisappear can unregister exactly this callback; it
        // only reports the change and never prompts (the denial is cached in the sink above).
        const clipboardObserver = (): void => {
          this.hostCall('notifyClipboardChanged', typeof host.notifyClipboardChanged === 'function', (): void => {
            host.notifyClipboardChanged();
          });
        };
        pasteboard.getSystemPasteboard().on('update', clipboardObserver);
        this.clipboardObserver = clipboardObserver;
        this.clipboardObserverRegistered = true;
      } catch (clipboardObserverError) {
        console.error(`[maui] clipboard observer unavailable: ${(clipboardObserverError as Error).message}`);
      }
    }

    // Geocoding (Essentials): the managed geolocation service asks through
    // ohos_host_geocode_request (op 0 address -> location, op 1 location -> address); the shell
    // runs the lazily imported @ohos.geoLocationManager (permission-aware for the reverse
    // lookup) and answers host.geocodeResult(requestId, rc, json).
    this.hostCall('registerGeocodeSink', typeof host.registerGeocodeSink === 'function', (): void => {
      host.registerGeocodeSink(async (requestId: number, op: number, arg: string): Promise<void> => {
        await this.runGeocode(requestId, op, arg);
      });
    });

    // Notifications (H5a): this registration is a sibling of the picker sink, not nested inside
    // it - nested, it only ran after a picker request, so notification events were never
    // registered at page startup. Device-compat: the notification manager is imported lazily; a
    // missing module is cached and the publish is skipped.
    this.hostCall('registerNotificationSink', typeof host.registerNotificationSink === 'function', (): void => {
      host.registerNotificationSink(async (notificationId: number, notificationTitle: string, notificationText: string): Promise<void> => {
        if (this.lazyUnavailable('notificationManager')) {
          return;
        }
        try {
          const nm = await import('@ohos.notificationManager');
          try {
            await nm.default.publish({
              id: notificationId,
              content: {
                notificationContentType: nm.default.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
                normal: { title: notificationTitle, text: notificationText, additionalText: '' }
              }
            });
          } catch (publishError) {
            console.error(`notification publish failed: ${(publishError as Error).message}`);
          }
        } catch (notificationImportError) {
          this.noteLazyFailure('notificationManager', notificationImportError as Error);
        }
      });
    });

    this.hostCall('registerVibrationSink', typeof host.registerVibrationSink === 'function', (): void => {
      host.registerVibrationSink((durationMs: number) => {
      });
    });

    // SecureStorage: the managed side asks HUKS to generate/encrypt/decrypt.
    // The keystore kit is not part of this minimal shell project's dependencies/syscap yet, so
    // every request is answered with rc=-1 and the managed side uses its documented file
    // fallback. Enabling the real path means adding the universal keystore kit to the shell
    // project (see docs/plans/2026-09-18-ohos-secure-storage-huks-plan.md).
    this.hostCall('registerKeystoreSink', typeof host.registerKeystoreSink === 'function', (): void => {
      host.registerKeystoreSink((requestId: number, op: string, alias: string, data: string) => {
        this.hostCall('notifyKeystoreResult', typeof host.notifyKeystoreResult === 'function', (): void => {
          host.notifyKeystoreResult(requestId, -1, '');
        });
      });
    });

    // TextToSpeech: speak requests arrive from the managed side (ohos_host_tts_speak). The
    // OpenHarmony SDK this shell compiles against has no speech synthesis module: both
    // '@kit.CoreSpeechKit' and '@ohos.ai.tts' fail with "Cannot find module ... or its
    // corresponding type declarations", so - like the keystore sink above - the request is
    // answered with "unavailable" (rc=-1) and the managed side degrades (it never throws).
    // With a Speech Kit SDK: create the engine once (textToSpeech.createEngine), call
    // engine.speak(text, ...) and answer host.notifyTtsResult(requestId, 0) when it finishes.
    this.hostCall('registerTtsSink', typeof host.registerTtsSink === 'function', (): void => {
      host.registerTtsSink((requestId: number, text: string, locale: string): void => {
        this.hostCall('notifyTtsResult', typeof host.notifyTtsResult === 'function', (): void => {
          host.notifyTtsResult(requestId, -1);
        });
      });
    });

    // Contacts (platform extra): the managed side asks through ohos_host_contacts_query. The
    // sink requires ohos.permission.READ_CONTACTS, queries the Contacts Kit
    // (@kit.ContactsKit -> contact.queryContacts) and answers with "name\tphone" lines, capped
    // at the managed limit. A missing kit or a denied permission answers code -1, which the
    // managed side reports as IsSupported == false instead of guessing. Device-compat: the
    // Contacts Kit is imported lazily; a missing kit is cached and every later request
    // answers -1 without re-importing.
    this.hostCall('registerContactsSink', typeof host.registerContactsSink === 'function', (): void => {
      host.registerContactsSink(async (requestId: number, namePrefix: string, limit: number): Promise<void> => {
        if (this.lazyUnavailable('contactsKit')) {
          this.hostCall('notifyContactsResult', typeof host.notifyContactsResult === 'function', (): void => {
            host.notifyContactsResult(requestId, -1, '');
          });
          return;
        }
        try {
          const kit = await import('@kit.ContactsKit');
          try {
            const context = getContext(this) as common.UIAbilityContext;
            const permissions: Permissions[] = ['ohos.permission.READ_CONTACTS'];
            const atManager = abilityAccessCtrl.createAtManager();
            const granted = await atManager.requestPermissionsFromUser(context, permissions);
            if (granted.authResults.length === 0 || granted.authResults[0] !== 0) {
              this.hostCall('notifyContactsResult', typeof host.notifyContactsResult === 'function', (): void => {
                host.notifyContactsResult(requestId, -1, '');
              });
              return;
            }
            const all = await kit.contact.queryContacts(context);
            const rows: string[] = [];
            for (const item of all) {
              const name: string = item.name && item.name.fullName ? item.name.fullName : '';
              if (namePrefix.length > 0 && !name.startsWith(namePrefix)) {
                continue;
              }
              const phone: string = item.phoneNumbers && item.phoneNumbers.length > 0
                ? item.phoneNumbers[0].phoneNumber : '';
              rows.push(`${this.escapeRecordField(name)}\t${this.escapeRecordField(phone)}`);
              if (rows.length >= limit) {
                break;
              }
            }
            this.hostCall('notifyContactsResult', typeof host.notifyContactsResult === 'function', (): void => {
              host.notifyContactsResult(requestId, 0, rows.join('\n'));
            });
          } catch (contactsError) {
            console.error(`[maui] contacts query failed: ${(contactsError as Error).message}`);
            this.hostCall('notifyContactsResult', typeof host.notifyContactsResult === 'function', (): void => {
              host.notifyContactsResult(requestId, -1, '');
            });
          }
        } catch (contactsImportError) {
          this.noteLazyFailure('contactsKit', contactsImportError as Error);
          this.hostCall('notifyContactsResult', typeof host.notifyContactsResult === 'function', (): void => {
            host.notifyContactsResult(requestId, -1, '');
          });
        }
      });
    });

    // Calendar (platform extra): the managed side asks through ohos_host_calendar_list (op 0,
    // arg1 = days) or ohos_host_calendar_add (op 1, arg1 = title, arg2/arg3 = ISO start/end).
    // Both require the runtime calendar permissions and run through the Calendar Kit
    // (@kit.CalendarKit -> calendarManager.getCalendar -> getEvents / addEvent). A missing kit
    // or a denied permission answers code -1 (managed IsSupported == false). Device-compat:
    // the Calendar Kit is imported lazily; a missing kit is cached and answers -1.
    this.hostCall('registerCalendarSink', typeof host.registerCalendarSink === 'function', (): void => {
      host.registerCalendarSink(async (requestId: number, op: number, arg1: string, arg2: string, arg3: string): Promise<void> => {
        if (this.lazyUnavailable('calendarKit')) {
          this.hostCall('notifyCalendarResult', typeof host.notifyCalendarResult === 'function', (): void => {
            host.notifyCalendarResult(requestId, -1, '');
          });
          return;
        }
        try {
          const kit = await import('@kit.CalendarKit');
          try {
            const context = getContext(this) as common.UIAbilityContext;
            const permissions: Permissions[] = op === 0
              ? ['ohos.permission.READ_CALENDAR']
              : ['ohos.permission.READ_CALENDAR', 'ohos.permission.WRITE_CALENDAR'];
            const atManager = abilityAccessCtrl.createAtManager();
            const granted = await atManager.requestPermissionsFromUser(context, permissions);
            for (let i = 0; i < granted.authResults.length; i++) {
              if (granted.authResults[i] !== 0) {
                this.hostCall('notifyCalendarResult', typeof host.notifyCalendarResult === 'function', (): void => {
                  host.notifyCalendarResult(requestId, -1, '');
                });
                return;
              }
            }
            const manager = kit.calendarManager.getCalendarManager(context);
            const calendar = await manager.getCalendar();
            if (op === 0) {
              const days: number = Number.parseInt(arg1, 10) || 0;
              const now: number = Date.now();
              const end: number = now + days * 24 * 60 * 60 * 1000;
              const events = await calendar.getEvents(kit.calendarManager.EventFilter.filterByTime(now, end));
              const rows: string[] = [];
              for (const item of events) {
                const title: string = item.title ? item.title : '';
                rows.push(`${this.escapeRecordField(title)}\t${this.escapeRecordField(new Date(item.startTime).toISOString())}\t${this.escapeRecordField(new Date(item.endTime).toISOString())}`);
              }
              this.hostCall('notifyCalendarResult', typeof host.notifyCalendarResult === 'function', (): void => {
                host.notifyCalendarResult(requestId, 0, rows.join('\n'));
              });
              return;
            }
            const event: calendarManager.Event = {
              type: kit.calendarManager.EventType.NORMAL,
              title: arg1,
              startTime: Date.parse(arg2),
              endTime: Date.parse(arg3),
            };
            await calendar.addEvent(event);
            this.hostCall('notifyCalendarResult', typeof host.notifyCalendarResult === 'function', (): void => {
              host.notifyCalendarResult(requestId, 0, '');
            });
          } catch (calendarError) {
            console.error(`[maui] calendar request failed: ${(calendarError as Error).message}`);
            this.hostCall('notifyCalendarResult', typeof host.notifyCalendarResult === 'function', (): void => {
              host.notifyCalendarResult(requestId, -1, '');
            });
          }
        } catch (calendarImportError) {
          this.noteLazyFailure('calendarKit', calendarImportError as Error);
          this.hostCall('notifyCalendarResult', typeof host.notifyCalendarResult === 'function', (): void => {
            host.notifyCalendarResult(requestId, -1, '');
          });
        }
      });
    });

    // Bluetooth (platform extra): the managed side asks through ohos_host_bluetooth_query.
    // op 0 reports the adapter state (access.getState), op 1 lists the paired devices
    // (connection.getPairedDevices + getRemoteDeviceName), op 2/3 start/stop classic discovery
    // (connection.startBluetoothDiscovery / stopBluetoothDiscovery) and op 4 answers the devices
    // found since the last start (filled by the bluetoothDeviceFind listener). ACCESS_BLUETOOTH
    // is a user_grant permission, so the shell requests it first; a denial answers code -1
    // (managed IsSupported == false). Devices travel as "name\taddress" lines. Device-compat:
    // the Connectivity Kit is imported lazily; a missing kit is cached and answers -1.
    this.hostCall('registerBluetoothSink', typeof host.registerBluetoothSink === 'function', (): void => {
      host.registerBluetoothSink(async (requestId: number, op: number): Promise<void> => {
        if (this.lazyUnavailable('connectivityKit')) {
          this.hostCall('notifyBluetoothResult', typeof host.notifyBluetoothResult === 'function', (): void => {
            host.notifyBluetoothResult(requestId, -1, '');
          });
          return;
        }
        try {
          const kit = await import('@kit.ConnectivityKit');
          try {
            const context = getContext(this) as common.UIAbilityContext;
            const permissions: Permissions[] = ['ohos.permission.ACCESS_BLUETOOTH'];
            const atManager = abilityAccessCtrl.createAtManager();
            const granted = await atManager.requestPermissionsFromUser(context, permissions);
            if (granted.authResults.length === 0 || granted.authResults[0] !== 0) {
              this.hostCall('notifyBluetoothResult', typeof host.notifyBluetoothResult === 'function', (): void => {
                host.notifyBluetoothResult(requestId, -1, '');
              });
              return;
            }
            const state: access.BluetoothState = kit.access.getState();
            if (op === 0) {
              this.hostCall('notifyBluetoothResult', typeof host.notifyBluetoothResult === 'function', (): void => {
                host.notifyBluetoothResult(requestId, 0, `${state}`);
              });
              return;
            }
            if (op === 4) {
              // Discovered devices are accumulated locally; no adapter call is needed.
              const discovered: string[] = [];
              this.discoveredBluetooth.forEach((name: string, address: string): void => {
                discovered.push(`${this.escapeRecordField(name)}\t${this.escapeRecordField(address)}`);
              });
              this.hostCall('notifyBluetoothResult', typeof host.notifyBluetoothResult === 'function', (): void => {
                host.notifyBluetoothResult(requestId, 0, discovered.join('\n'));
              });
              return;
            }
            if (op === 2 || op === 3) {
              // Discovery and its stop need a powered adapter; while it is off they would throw
              // 2900003. That is a transient device state, so it answers code -2 (the managed side
              // fails the call but keeps IsSupported) instead of -1 (platform unavailable).
              if (state !== kit.access.BluetoothState.STATE_ON) {
                this.hostCall('notifyBluetoothResult', typeof host.notifyBluetoothResult === 'function', (): void => {
                  host.notifyBluetoothResult(requestId, -2, '');
                });
                return;
              }
              if (op === 2) {
                // A fresh scan starts an empty result set; the listener is registered once the
                // permission is in place (the discovery callback needs it too) and resolves each
                // name with getRemoteDeviceName while discovery runs.
                this.discoveredBluetooth.clear();
                if (!this.bluetoothDeviceRegistered) {
                  kit.connection.on('bluetoothDeviceFind', (devices: Array<string>): void => {
                    for (const deviceId of devices) {
                      let name: string = '';
                      try {
                        name = kit.connection.getRemoteDeviceName(deviceId);
                      } catch (nameError) {
                        name = '';
                      }
                      this.discoveredBluetooth.set(deviceId, name);
                      this.hostCall('notifyBluetoothDeviceFound', typeof host.notifyBluetoothDeviceFound === 'function', (): void => {
                        host.notifyBluetoothDeviceFound(`${this.escapeRecordField(name)}\t${this.escapeRecordField(deviceId)}`);
                      });
                    }
                  });
                  this.bluetoothDeviceRegistered = true;
                }
                kit.connection.startBluetoothDiscovery();
              } else {
                kit.connection.stopBluetoothDiscovery();
                if (this.bluetoothDeviceRegistered) {
                  try {
                    kit.connection.off('bluetoothDeviceFind');
                  } catch (offError) {
                    // Stopping discovery already succeeded; a stale listener is harmless.
                  }
                  this.bluetoothDeviceRegistered = false;
                }
              }
              this.hostCall('notifyBluetoothResult', typeof host.notifyBluetoothResult === 'function', (): void => {
                host.notifyBluetoothResult(requestId, 0, '');
              });
              return;
            }
            // Paired devices need a powered adapter; while it is off the platform throws
            // 2900003, which is answered as a valid empty list instead of a failure.
            if (state !== kit.access.BluetoothState.STATE_ON) {
              this.hostCall('notifyBluetoothResult', typeof host.notifyBluetoothResult === 'function', (): void => {
                host.notifyBluetoothResult(requestId, 0, '');
              });
              return;
            }
            const devices: Array<string> = kit.connection.getPairedDevices();
            const rows: string[] = [];
            for (const deviceId of devices) {
              let name: string = '';
              try {
                name = kit.connection.getRemoteDeviceName(deviceId);
              } catch (nameError) {
                name = '';
              }
              rows.push(`${this.escapeRecordField(name)}\t${this.escapeRecordField(deviceId)}`);
            }
            this.hostCall('notifyBluetoothResult', typeof host.notifyBluetoothResult === 'function', (): void => {
              host.notifyBluetoothResult(requestId, 0, rows.join('\n'));
            });
          } catch (bluetoothError) {
            console.error(`[maui] bluetooth request failed: ${(bluetoothError as Error).message}`);
            this.hostCall('notifyBluetoothResult', typeof host.notifyBluetoothResult === 'function', (): void => {
              host.notifyBluetoothResult(requestId, -1, '');
            });
          }
        } catch (bluetoothImportError) {
          this.noteLazyFailure('connectivityKit', bluetoothImportError as Error);
          this.hostCall('notifyBluetoothResult', typeof host.notifyBluetoothResult === 'function', (): void => {
            host.notifyBluetoothResult(requestId, -1, '');
          });
        }
      });
    });

    // Printing (platform extra): the managed side asks through ohos_host_print_file with an
    // absolute path to a PDF/image it rendered (PrintTextAsync writes <cacheDir>/<job>.pdf).
    // ohos.permission.PRINT is system_grant, so there is no runtime prompt: a packaged app
    // that declares it can print. print.print resolves once the system print UI accepted the
    // job; the final page outcome belongs to the print service, so code 0 means "accepted".
    // Device-compat: the print module is imported lazily; a missing module is cached and
    // answers -1.
    this.hostCall('registerPrintSink', typeof host.registerPrintSink === 'function', (): void => {
      host.registerPrintSink(async (requestId: number, path: string): Promise<void> => {
        if (this.lazyUnavailable('print')) {
          this.hostCall('notifyPrintResult', typeof host.notifyPrintResult === 'function', (): void => {
            host.notifyPrintResult(requestId, -1, '');
          });
          return;
        }
        try {
          const printer = await import('@ohos.print');
          try {
            const context = getContext(this) as common.UIAbilityContext;
            const task: print.PrintTask = await printer.default.print([path], context);
            task.on('fail', (): void => {
              console.error('[maui] print task reported failure');
            });
            task.on('cancel', (): void => {
              console.info('[maui] print task cancelled');
            });
            this.hostCall('notifyPrintResult', typeof host.notifyPrintResult === 'function', (): void => {
              host.notifyPrintResult(requestId, 0, '');
            });
          } catch (printError) {
            console.error(`[maui] print request failed: ${(printError as Error).message}`);
            this.hostCall('notifyPrintResult', typeof host.notifyPrintResult === 'function', (): void => {
              host.notifyPrintResult(requestId, -1, (printError as Error).message);
            });
          }
        } catch (printImportError) {
          this.noteLazyFailure('print', printImportError as Error);
          this.hostCall('notifyPrintResult', typeof host.notifyPrintResult === 'function', (): void => {
            host.notifyPrintResult(requestId, -1, '');
          });
        }
      });
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
    this.hostCall('registerAbilitySink', typeof host.registerAbilitySink === 'function', (): void => {
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
    });

    // Flashlight (Camera Kit torch): the managed side asks through ohos_host_flashlight_set(on)
    // with on 0 = torch off, 1 = torch on, 2 = support probe (isTorchSupported only, no torch
    // call). The callback returns whether the kit accepted the request; setTorchMode is a
    // synchronous call that throws (e.g. 7400102 when the camera service does not allow it), so
    // the boolean is the kit's answer, not a visual confirmation of the LED. A missing kit or
    // camera answers false and the managed side degrades without throwing.
    this.hostCall('registerFlashlightSink', typeof host.registerFlashlightSink === 'function', (): void => {
      host.registerFlashlightSink((on: number): boolean => {
        try {
          const manager = this.ensureFlashlightManager();
          if (manager === undefined) {
            // The camera module has not finished its lazy load yet, or is unavailable.
            return false;
          }
          if (on === 2) {
            return manager.isTorchSupported();
          }
          if (!manager.isTorchSupported()) {
            return false;
          }
          if (this.cameraTorchOn === undefined || this.cameraTorchOff === undefined) {
            return false;
          }
          manager.setTorchMode(on === 1 ? this.cameraTorchOn : this.cameraTorchOff);
          return true;
        } catch (flashlightError) {
          console.error(`[maui] flashlight request failed: ${(flashlightError as Error).message}`);
          this.flashlightManager = undefined;
          return false;
        }
      });
    });

    // The managed Entry asks for the soft keyboard through this sink.
    this.hostCall('registerTextInputSink', typeof host.registerTextInputSink === 'function', (): void => {
      host.registerTextInputSink((show: number) => {
        if (show === 1) {
          this.controller.caretPosition(0);
          focusControl.requestFocus('ohos_dotnet_input');
        } else {
          focusControl.requestFocus('ohos_dotnet_surface');
        }
      });
    });

    // Menus: pull the initial table, then refresh on every commit from the managed side.
    // A host library without the menu exports degrades to no menu instead of failing the page.
    this.hostCall('registerMenuChangedSink', typeof host.registerMenuChangedSink === 'function', (): void => {
      host.registerMenuChangedSink((count: number): void => {
        console.info(`[maui] menu table changed: ${count} rows`);
        this.pullMenu();
      });
    });
    this.pullMenu();
  }

  // Picker result framing (managed OpenHarmonyPickerClient.Complete): a cancel/unavailable
  // answer is rc=-1, each picked file is one rc=0 callback, and a multi pick ends with rc=1.
  // The callbacks are delivered in order, so the managed accumulator completes on the marker.
  private answerPickerCancel(requestId: number): void {
    this.hostCall('notifyPickerResult', typeof host.notifyPickerResult === 'function', (): void => {
      host.notifyPickerResult(requestId, -1, '', '');
    });
  }

  private answerPickerFiles(requestId: number, multi: boolean, uris: string[]): void {
    for (let i = 0; i < uris.length; i++) {
      const uri: string = uris[i];
      let name: string = uri.substring(uri.lastIndexOf('/') + 1);
      let encoded: string = '';
      try {
        const file = fs.openSync(uri, fs.OpenMode.READ_ONLY);
        try {
          const stat = fs.statSync(file.fd);
          const buffer = new ArrayBuffer(stat.size);
          fs.readSync(file.fd, buffer);
          encoded = new util.Base64Helper().encodeToStringSync(new Uint8Array(buffer));
        } finally {
          fs.closeSync(file);
        }
      } catch (readError) {
        // An unreadable file (or one whose base64 exceeds the host's per-result cap) is
        // reported with empty data and dropped by the managed side instead of failing the
        // whole selection.
        console.error(`[maui] picker read failed: ${(readError as Error).message}`);
        encoded = '';
      }
      this.hostCall('notifyPickerResult', typeof host.notifyPickerResult === 'function', (): void => {
        host.notifyPickerResult(requestId, 0, name, encoded);
      });
    }
    if (multi) {
      this.hostCall('notifyPickerResult', typeof host.notifyPickerResult === 'function', (): void => {
        host.notifyPickerResult(requestId, 1, '', '');
      });
    }
  }

  // Documents: the pre-existing DocumentViewPicker path, extended with the caller-provided
  // maxSelectNumber (1 for every single-select request, so those keep their exact behaviour).
  private async selectDocumentUris(requestId: number, multi: boolean, count: number): Promise<void> {
    try {
      const documentPicker = new picker.DocumentViewPicker();
      const uris = await documentPicker.select({ maxSelectNumber: count });
      if (!uris || uris.length === 0) {
        this.answerPickerCancel(requestId);
        return;
      }
      this.answerPickerFiles(requestId, multi, uris);
    } catch (error) {
      console.error(`[maui] document picker failed: ${(error as Error).message}`);
      this.answerPickerCancel(requestId);
    }
  }

  // Photos/videos: photoAccessHelper PhotoViewPicker (media-only gallery UI). Returns null when
  // the module is missing on this device (cached) so the caller falls back to the document
  // picker; an empty array is a user cancel and a pick failure answers like an empty pick.
  private async selectMediaUris(mode: number, count: number): Promise<string[] | null> {
    if (this.lazyUnavailable('photoAccessHelper')) {
      return null;
    }
    try {
      const photoAccess = await import('@ohos.file.photoAccessHelper');
      try {
        const selectOptions = new photoAccess.default.PhotoSelectOptions();
        selectOptions.MIMEType = mode === 1
          ? photoAccess.default.PhotoViewMIMETypes.IMAGE_TYPE
          : photoAccess.default.PhotoViewMIMETypes.VIDEO_TYPE;
        selectOptions.maxSelectNumber = count;
        const photoPicker = new photoAccess.default.PhotoViewPicker();
        const picked = await photoPicker.select(selectOptions);
        const uris: string[] = picked.photoUris;
        return uris ? uris : [];
      } catch (pickError) {
        console.error(`[maui] photo picker failed: ${(pickError as Error).message}`);
        return [];
      }
    } catch (importError) {
      this.noteLazyFailure('photoAccessHelper', importError as Error);
      return null;
    }
  }

  // Late app-context publish: the native host stores the context JSON once, at startApp time,
  // so a shell whose startApp context carried no payload directory would leave the managed
  // bridge without a recoverable signal (it can only re-read the host on surface/lifecycle
  // events). host.setAppContext replaces the stored snapshot and re-emits it through that
  // same surface notification path; called once the surface is ready, this closes the chain.
  // Guarded: a host library without the export (or a failed publish) degrades to no-op.
  private publishAppContext(): void {
    try {
      if (typeof host.setAppContext !== 'function') {
        return;
      }
      const context = getContext(this) as common.UIAbilityContext;
      const payloadDir = `${context.filesDir}/dotnet`;
      const json = JSON.stringify({
        appDir: payloadDir,
        filesDir: context.filesDir,
        cacheDir: context.cacheDir,
        bundleName: context.abilityInfo.bundleName,
        abilityName: context.abilityInfo.name,
        nodeContent: 0,
      });
      const rc: number = host.setAppContext(json) as number;
      if (rc !== 0) {
        console.error(`[maui] app context publish declined: ${rc}`);
      }
    } catch (contextError) {
      console.error(`[maui] app context publish failed: ${(contextError as Error).message}`);
    }
  }

  // Accessibility: host.setNodeContent hands this.content to the native host, which creates
  // the CUSTOM node and calls OH_ArkUI_NodeContent_AddNode on it. The ContentSlot that hosts
  // the NodeContent only exists once build() has mounted the page, so attaching it in
  // aboutToAppear ran before the container was there and left the node unattached (host
  // status 3). onPageShow runs after the page (and its ContentSlot) is mounted; the host
  // caches the created node, so a repeated page show cannot attach it twice.
  onPageShow(): void {
    this.hostCall('setNodeContent', typeof host.setNodeContent === 'function', (): void => {
      host.setNodeContent(this.content);
    });
  }

  // Clipboard (Essentials): the pasteboard 'update' observer is registered on the page's
  // context and would outlive the page, so it is unregistered with the exact stored callback
  // when the page disappears; a later page registers again. No other observer is page-scoped.
  aboutToDisappear(): void {
    if (this.clipboardObserverRegistered && this.clipboardObserver !== null) {
      try {
        pasteboard.getSystemPasteboard().off('update', this.clipboardObserver);
      } catch (clipboardOffError) {
        console.error(`[maui] clipboard observer unregister failed: ${(clipboardOffError as Error).message}`);
      }
      this.clipboardObserverRegistered = false;
      this.clipboardObserver = null;
    }
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

  // Registration-time layout guard (B5): the request-path check inside hybridFilePath /
  // blazorFilePath only protects intercepted requests, so a registered root/defaultFile needs
  // its own check - each layout part must be made of ordinary relative segments (no '', '.',
  // '..', '\' and no leading '/'), so the join `<base>/<root>/<path>` can never leave <base>.
  // The managed handlers mirror this before they register a layout.
  private isSafeLayoutPart(part: string): boolean {
    if (part.length === 0 || part.indexOf('\\') >= 0 || part.startsWith('/')) {
      return false;
    }
    const segments: string[] = part.split('/');
    for (const segment of segments) {
      if (segment.length === 0 || segment === '.' || segment === '..') {
        return false;
      }
    }
    return true;
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
      this.hybridDocId = config.id !== undefined && config.id.length > 0 ? config.id : '';
      const safeLayout: boolean = this.isSafeLayoutPart(this.hybridRoot)
        && this.isSafeLayoutPart(this.hybridDefaultFile);
      if (!safeLayout) {
        console.error('[maui] hybrid assets registration rejected: root/defaultFile are not safe relative paths');
      }
      this.hybridRegistered = safeLayout && this.hybridBase.length > 0 && this.hybridRoot.length > 0
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
      this.blazorDocId = config.id !== undefined && config.id.length > 0 ? config.id : '';
      this.blazorOrigin = config.origin.length > 0 ? config.origin : 'https://0.0.0.0/';
      if (!this.blazorOrigin.endsWith('/')) {
        this.blazorOrigin = `${this.blazorOrigin}/`;
      }
      const safeLayout: boolean = this.isSafeLayoutPart(this.blazorRoot)
        && this.isSafeLayoutPart(this.blazorDefaultFile);
      if (!safeLayout) {
        console.error('[maui] blazor assets registration rejected: root/defaultFile are not safe relative paths');
      }
      this.blazorRegistered = safeLayout && this.blazorBase.length > 0 && this.blazorRoot.length > 0
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

  // Static web asset fingerprint fallback. .NET static web assets are requested under
  // fingerprinted names (stem.<8-32 lowercase hex chars>.ext) while the extracted payload
  // carries the base file; a request whose exact file is missing is retried once with the
  // suffix stripped (name.<hash>.ext -> name.ext). The grammar is deliberately conservative:
  // the hex run must be the last stem segment and a non-empty stem must remain, so ordinary
  // dotted names (app.settings.css) or hidden names (.hidden.css) are never rewritten. The
  // rewrite can only shorten the final file name - the parent directory is taken from the
  // already-validated input, so the traversal rejections in *FilePath stay in force. The input
  // is returned unchanged when the name carries no fingerprint.
  private staticFingerprintBase(filePath: string): string {
    const slash: number = filePath.lastIndexOf('/');
    const nameStart: number = slash + 1;
    const dot: number = filePath.lastIndexOf('.');
    if (dot <= nameStart) {
      return filePath;
    }
    const stem: string = filePath.substring(nameStart, dot);
    const extension: string = filePath.substring(dot);
    const match = /^(.+)\.[0-9a-f]{8,32}$/.exec(stem);
    if (match === null) {
      return filePath;
    }
    return `${filePath.substring(0, nameStart)}${match[1]}${extension}`;
  }

  // Cache policy for a served payload file. A fingerprinted request is pinned by its name, so
  // it is immutable for a year; every other payload file - the framework bootstrap
  // (blazor.webview.js, hybridwebview.js), the host page and the app assets - is revalidated,
  // so a refreshed pack is picked up even when the WebView cache is warm. The status probe ran
  // on this toolchain: WebResourceResponse.setResponseHeader(Header[]) exists in the SDK
  // (component/web.d.ts, API 9+) and the object-literal header map below typechecks; a nominal
  // class is not required (the checker's arkts-no-structural-typing rejection belongs to the
  // explicit RegExpMatchArray annotation on the strip probe, which is inferred instead).
  private payloadCacheHeaders(fingerprinted: boolean): Header[] {
    const headers: Header[] = [{
      headerKey: 'Cache-Control',
      headerValue: fingerprinted ? 'public, max-age=31536000, immutable' : 'no-cache',
    }];
    return headers;
  }

  // Reads one payload file into a 200 response; undefined means "not a readable file" and the
  // caller answers 404 (or retries the base name for a fingerprinted request).
  private readPayloadFile(filePath: string, fingerprinted: boolean): WebResourceResponse | undefined {
    let fd: number = -1;
    try {
      const stat = fileIo.statSync(filePath);
      if (!stat.isFile()) {
        return undefined;
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
      response.setResponseHeader(this.payloadCacheHeaders(fingerprinted));
      return response;
    } catch (ioError) {
      return undefined;
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

  // ArkWeb needs the intercepted response synchronously, and payload assets are small, so the
  // file is read inline through @ohos.file.fs (open/read/close). '' (an unknown or unsafe path)
  // is answered with 404, so both bridges share the read path. The exact request path always
  // wins; only a fingerprinted name whose exact file is missing retries the base name once.
  private servePayloadFile(filePath: string): WebResourceResponse {
    if (filePath.length === 0) {
      return this.hybridErrorResponse(404);
    }
    const baseFile: string = this.staticFingerprintBase(filePath);
    const fingerprinted: boolean = baseFile !== filePath;
    const exact: WebResourceResponse | undefined = this.readPayloadFile(filePath, fingerprinted);
    if (exact !== undefined) {
      return exact;
    }
    if (fingerprinted) {
      const fallback: WebResourceResponse | undefined = this.readPayloadFile(baseFile, true);
      if (fallback !== undefined) {
        return fallback;
      }
    }
    return this.hybridErrorResponse(404);
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
    // The endpoint belongs to the served hybrid document; a request from any other frame
    // (ArkWeb intercepts iframe requests too) is refused like a malformed one (400), so the
    // page's fetch rejects cleanly instead of waiting.
    if (event.request && typeof event.request.isMainFrame === 'function' && !event.request.isMainFrame()) {
      return this.hybridErrorResponse(400);
    }
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
    const delivered: boolean = this.hostCall('notifyJsMessage', typeof host.notifyJsMessage === 'function', (): void => {
      host.notifyJsMessage(this.originEnvelope(body));
    });
    // The message could not be handed to the managed side (mismatched host library): answer
    // the page's fetch with a malformed-request status instead of a success it never got.
    return this.hybridErrorResponse(delivered ? 204 : 400);
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
    // Same frame check as hybridMessageResponse: only the main document may use the invoke
    // endpoint, everything else gets the malformed-request response.
    if (event.request && typeof event.request.isMainFrame === 'function' && !event.request.isMainFrame()) {
      return this.hybridErrorResponse(400);
    }
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
      this.reportHostUnavailable('notifyHybridInvoke', invokeError as Error);
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
        .onLoadIntercept((event) => {
          // B6 navigation allow-list: a top-level load the app did not originate is cancelled
          // and decided by the managed WebView handler's Navigating event. Frames and
          // subresources (isMainFrame false) and the app's own origin/file/data loads keep
          // loading unchanged. The shell's own reload passes through the one-shot marker.
          try {
            if (!event.data.isMainFrame()) {
              return false;
            }
            const url: string = event.data.getRequestUrl();
            if (this.isAppNavigation(url)) {
              return false;
            }
            if (this.consumeApprovedNavigation(url)) {
              return false;
            }
            if (url.length === 0 || url.length > this.navMaxUrlLength) {
              // Nothing to hand over (or too large to copy): the load stays blocked.
              return true;
            }
            this.askManagedAboutNavigation(url);
            return true;
          } catch (interceptError) {
            // An unexpected event shape must not take the page down; allow the load.
            return false;
          }
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
          const startedUrl: string = event ? event.url : '';
          // B6: the approved/app-requested load started; its one-shot marker is used up.
          this.retireNavigationMarker(startedUrl);
          this.hostCall('notifyWebEvent', typeof host.notifyWebEvent === 'function', (): void => {
            host.notifyWebEvent('started', startedUrl);
          });
        })
        .onPageEnd((event) => {
          const pageUrl: string = event ? event.url : '';
          this.hostCall('notifyWebEvent', typeof host.notifyWebEvent === 'function', (): void => {
            host.notifyWebEvent('finished', pageUrl);
          });
          this.injectPageBridge(pageUrl);
          this.injectBlazorBootstrap(pageUrl);
        })

      // Text entry bridge: the managed Entry reads what is typed here.
      TextInput({ text: this.inputText, placeholder: 'type here', controller: this.controller })
        .id('ohos_dotnet_input')
        .height(56)
        .position({ x: 0, y: 0 })
        .onChange((value: string) => {
          this.inputText = value;
          // Per-keystroke path: a mismatched host logs once, not once per character.
          this.hostCall('notifyTextInput', typeof host.notifyTextInput === 'function', (): void => {
            host.notifyTextInput(value);
          });
        })
        .onSubmit(() => {
          // The managed Entry/SearchBar raises Completed/SearchButtonPressed.
          this.hostCall('notifyTextSubmitted', typeof host.notifyTextSubmitted === 'function', (): void => {
            host.notifyTextSubmitted(this.inputText);
          });
        })

      XComponent({
        id: 'ohos_dotnet_surface',
        type: XComponentType.SURFACE,
        libraryname: 'openharmonyhost',
      })
        .onLoad(() => {
          // Binds the native XComponent so libopenharmonyhost receives surface callbacks.
          host.registerXComponent();
          // Surface ready: publish the app context (payload dir + ability paths) so a
          // startApp without one can still be completed by the managed bridge.
          this.publishAppContext();
        })
        .width('100%')
        .height('100%')

      ContentSlot(this.content)

      // Shell panel (Shell handler extras): the flyout header/footer text and the managed
      // search state. It only appears while one of them is present, so an app without shell
      // chrome keeps the full managed surface. The field reports interactions back through
      // host.notifyShellSearch (0 query changed, 1 submit, 2 cancel). The header/footer are
      // capped (2 lines each) and the panel height is clamped so hostile text cannot cover the
      // managed surface; without the search field the panel is hit-test transparent, so only the
      // interactive search UI ever intercepts taps.
      if (this.flyoutHeader.length > 0 || this.flyoutFooter.length > 0 || this.shellSearchVisible) {
        Column() {
          if (this.flyoutHeader.length > 0) {
            Text(this.flyoutHeader)
              .fontSize(16)
              .fontWeight(FontWeight.Bold)
              .fontColor(Color.White)
              .width('100%')
              .maxLines(2)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .padding({ left: 12, right: 12, top: 8, bottom: 8 })
          }
          if (this.shellSearchVisible) {
            TextInput({ text: this.shellSearchQuery, placeholder: this.shellSearchPlaceholder })
              .id('ohos_shell_search')
              .enabled(this.shellSearchEnabled)
              .height(40)
              .margin({ left: 8, right: 8, bottom: 8 })
              .onChange((value: string): void => {
                if (value === this.shellSearchQuery) {
                  return;
                }
                this.shellSearchQuery = value;
                this.hostCall('notifyShellSearch', typeof host.notifyShellSearch === 'function', (): void => {
                  host.notifyShellSearch(0, value);
                });
              })
              .onSubmit((): void => {
                this.hostCall('notifyShellSearch', typeof host.notifyShellSearch === 'function', (): void => {
                  host.notifyShellSearch(1, this.shellSearchQuery);
                });
              })
            Row() {
              Button('Cancel')
                .height(28)
                .fontSize(12)
                .onClick(() => {
                  this.shellSearchQuery = '';
                  this.hostCall('notifyShellSearch', typeof host.notifyShellSearch === 'function', (): void => {
                    host.notifyShellSearch(2, '');
                  });
                })
            }
            .width('100%')
            .justifyContent(FlexAlign.End)
            .padding({ right: 8, bottom: 8 })
          }
          if (this.flyoutFooter.length > 0) {
            Text(this.flyoutFooter)
              .fontSize(12)
              .fontColor('#DDDDDD')
              .width('100%')
              .maxLines(2)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .padding({ left: 12, right: 12, top: 8, bottom: 8 })
          }
        }
        .width(260)
        .constraintSize({ maxHeight: 240 })
        .clip(true)
        .align(Alignment.TopStart)
        .backgroundColor('#CC101010')
        .borderRadius(8)
        .margin({ top: 8, left: 8 })
        .hitTestBehavior(this.shellSearchVisible ? HitTestMode.Default : HitTestMode.None)
      }

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
