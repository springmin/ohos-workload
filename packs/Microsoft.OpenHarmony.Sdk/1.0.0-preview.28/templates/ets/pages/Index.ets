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
import { NodeContent } from '@kit.ArkUI';
import { abilityAccessCtrl, common, Permissions, Want, wantConstant } from '@kit.AbilityKit';
import { display, window, NodeController } from '@kit.ArkUI';
import { fileIo as fs, fileUri, picker } from '@kit.CoreFileKit';
import host from 'libopenharmonyhost.so';
import { pasteboard } from '@kit.BasicServicesKit';
import { uniformTypeDescriptor as utd } from '@kit.ArkData';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { util } from '@kit.ArkTS';
import { webview as web_webview } from '@kit.ArkWeb';
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
//   media             - Media Kit (AVPlayer type; the module is imported lazily)
//   access            - Connectivity Kit (Bluetooth adapter state)
//   ble               - Connectivity Kit (BLE GATT client: createGattClientDevice and friends)
//   connection        - Network Kit (Connectivity change observer)
//   print             - Print Kit
//   commonEventManager, BusinessError - Basic Services Kit (battery events)
import type { camera } from '@kit.CameraKit';
import type { calendarManager } from '@kit.CalendarKit';
import type { media } from '@kit.MediaKit';
import type { access, ble } from '@kit.ConnectivityKit';
import type { connection } from '@kit.NetworkKit';
import type { commonEventManager, print } from '@kit.BasicServicesKit';
import type { BusinessError } from '@kit.BasicServicesKit';
// Geocoding (Essentials): the module itself is imported lazily (device-compat, see
// runGeocode); this type-only import is erased by the compiler and only names the request
// shapes used in annotations.
import type { geoLocationManager } from '@kit.LocationKit';
// Raw HAP resources (resources/rawfile/**): names the ResourceManager type the ability context
// exposes; the type-only import is erased by the compiler.
import type { resourceManager } from '@kit.LocalizationKit';
// MULTIWINDOW-M: side-effect import that evaluates pages/SubWindow.ets so its @Entry named
// route ('ohos_dotnet_subwindow') is registered in this UI instance. Without the import the
// named route can resolve as an empty content load (the subwindow then shows its background
// only), because nothing else references the page module.
import './SubWindow';

// Menu bridge: the managed side publishes the current page's menu bars (MenuBarItem/MenuFlyout)
// as a structured table through the host. registerMenuChangedSink fires after every commit -
// including the empty table that hides the menu - and the table is pulled back with
// menuCount/menuItem. Each row carries its kind (0 item / 1 submenu header / 2 bar title), its
// nesting level and the owning bar's title (T16); the shell groups the rows per bar with
// MenuItemGroup and renders a submenu header as a nested MenuItem({builder}) menu. A tap goes
// back to the managed item through host.notifyMenuAction(index). A host library that predates
// the structured table returns rows without kind/level; the shell then keeps the legacy flat
// MenuElement rendering.
interface HostMenuItem {
  text: string;
  enabled: boolean;
  kind?: number;
  level?: number;
  barTitle?: string;
}

// One table row plus its index in the pulled table (the value host.notifyMenuAction expects).
interface HostMenuRowRef {
  row: HostMenuItem;
  index: number;
}

// In-app subwindow (MULTIWINDOW-M): the managed slice's OpenHarmonySubWindow sends commands
// through host.registerSubWindowSink as (op, payloadJson) and the shell reports lifecycle,
// geometry and touch back through host.notifySubWindowEvent. Both payloads stay JSON, so the
// command set can grow on either side without a native host rebuild.
interface SubWindowCommand {
  name?: string;
  title?: string;
  x?: number;
  y?: number;
  w?: number;
  h?: number;
}

// One subwindow state report: id + rect (window pixels). Only the fields the op uses are read.
interface SubWindowStatePayload {
  id: number;
  x: number;
  y: number;
  w: number;
  h: number;
}

// One touch inside the shell-drawn subwindow content.
interface SubWindowTouchPayload {
  action: number;
  x: number;
  y: number;
  count: number;
}

// A failed subwindow operation: the shell could not create/drive the child (BusinessError code
// or 801 when the platform has no such affordance, for example Hide).
interface SubWindowErrorPayload {
  code: number;
  message: string;
}

// window.SubWindowOptions plus the platform parser's undocumented zLevelAboveParentLoosened
// flag (window_manager js_window_utils.cpp ParseSubWindowOptions reads it and keeps false when
// absent). Declaring it pins the explicit false this shell passes so creating a child does not
// log the E "Failed to convert parameter to zLevelAboveParentLoosened"; maximizeSupported and
// outlineEnabled are the public optional booleans parsed the same way (absent -> E, default
// false), spelled out for the same reason.
interface ShellSubWindowOptions extends window.SubWindowOptions {
  zLevelAboveParentLoosened?: boolean;
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
  // MULTI-OVL: the overlay slot this registration owns; the shell loads the hybrid origin on
  // that slot's WebviewController. Absent/-1 keeps the legacy first overlay.
  slot?: number;
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
  // Registration mode (B2): "wasm" marks the root as a Blazor WebAssembly site. The shell then
  // serves it exactly like a hybrid content root but injects no Blazor Hybrid bootstrap (the
  // site's own _framework/blazor.webassembly*.js boots the runtime), and the registration does
  // not load the origin (the WebView's Source drives the load). Absent/"hybrid" keeps the
  // BlazorWebView behavior above.
  mode?: string;
  // MULTI-OVL: the overlay slot this registration owns; the shell loads the Blazor origin on
  // that slot's WebviewController. Absent/-1 keeps the legacy first overlay.
  slot?: number;
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
  // MULTI-OVL: the overlay that cancelled this load; the approval reloads that slot's controller.
  slot: number;
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

// Bluetooth GATT (platform extra): one managed GATT request is answered with a result code and
// an operation-specific payload. The code map is the managed OpenHarmonyGattStatus: 0 = the
// request completed, -1 = the platform path is unavailable (permission denied or the kit is
// missing), -2 = a transient kit failure; a failure payload is a diagnostic message. An MTU
// request additionally reports the value from the BLEMtuChange callback (0 when it did not
// arrive in time, in which case the managed side returns the requested value).
interface BluetoothGattAnswer {
  code: number;
  payload: string;
}

interface BluetoothGattMtuAnswer {
  code: number;
  mtu: number;
}

// Media playback (platform extra): one managed media request is answered with a result code and
// an operation-specific payload. The code map is the managed OpenHarmonyMediaStatus: 0 = the
// request completed, -1 = the platform path is unavailable (the Media Kit is missing), -2 = a
// transient kit failure; a failure payload is a diagnostic message. op 6 (status) answers
// "state\tpositionMs\tdurationMs".
interface MediaAnswer {
  code: number;
  payload: string;
}

// Structural view of the @kit.MediaKit namespace: an image whose runtime resolves the module
// without the media members (no createAVPlayer) is treated as unavailable instead of failing
// each call with a TypeError.
interface MediaKitNamespace {
  createAVPlayer(): Promise<media.AVPlayer>;
}

// HMS Kit feature probes (KIT-IMPL 2026-09-25; Share + Scan). The OpenHarmony SDK this shell
// builds against by default has no @kit.ShareKit/@kit.ScanKit declarations, so a literal
// import('@kit.X') is a hard ArkTS compile error (10505001 "Cannot find module ..."; verified
// by the KIT-IMPL probe). The probe therefore keeps the specifier in a variable - the loader
// leaves it as an unresolved runtime import - and casts the resolved value to a local
// structural interface naming exactly the members the sink calls (without the cast the linter
// rejects the unresolved module object as any/unknown: 10605008). On a device whose runtime
// provides the kit the import resolves and the sink registers; anywhere else it throws, the
// failure is cached and the feature stays unavailable (the host export then answers -1 and the
// managed side records the degradation).
interface HmsShareRecord {
  utd: string;
  uri: string;
  title?: string;
}

interface HmsShareData {
  addRecord(record: HmsShareRecord): void;
}

interface HmsShareShowOptions {
  // Reserved for the Share Kit panel options (anchor/previewMode). The default SINGLE-selection
  // panel is what a single target dispatch needs, so the empty object is intentional.
  previewMode?: number;
}

interface HmsShareController {
  show(context: Object, options: HmsShareShowOptions): Promise<void>;
  on(event: string, callback: (result: Object) => void): void;
}

interface HmsSystemShare {
  // The constructors are ESObject (not an interface with a construct signature: the ArkTS
  // linter rejects those with arkts-no-ctor-signatures-iface). `new ctor(...)` on an ESObject
  // crosses into the dynamic shape the unresolved kit module actually has.
  SharedData: ESObject;
  ShareController: ESObject;
}

interface HmsShareKit {
  systemShare: HmsSystemShare;
}

interface HmsScanResult {
  originalValue: string;
}

interface HmsScanBarcode {
  startScanForResult(context: Object): Promise<HmsScanResult>;
}

interface HmsScanKit {
  scanBarcode: HmsScanBarcode;
}

// HMS Kit feature probes (KIT-EXT2 2026-09-25; Push + Account + Map). The same compile-safe
// shape as Share/Scan: the module specifier stays in a variable (a literal import('@kit.X') is
// a hard ArkTS compile error on the OpenHarmony SDK) and the resolved value is cast to a local
// structural interface. The sinks register only when the runtime provides the kit.
interface HmsPushService {
  getToken(): Promise<string>;
  deleteToken(): Promise<void>;
}

interface HmsPushKit {
  pushService: HmsPushService;
}

interface HmsAuthorizationRequest {
  scopes: string[];
  permissions?: string[];
  state: string;
  forceAuthorization: boolean;
}

interface HmsAuthorizationExtraInfo {
  quickLoginAnonymousPhone?: string;
}

interface HmsAuthorizationData {
  authorizationCode?: string;
  extraInfo?: HmsAuthorizationExtraInfo;
}

interface HmsAuthorizationResponse {
  state?: string;
  data?: HmsAuthorizationData;
}

interface HmsAuthorizationController {
  executeRequest(request: HmsAuthorizationRequest): Promise<HmsAuthorizationResponse>;
}

interface HmsHuaweiIDProvider {
  createAuthorizationWithHuaweiIDRequest(): HmsAuthorizationRequest;
}

// The provider/controller constructors are ESObject (the ArkTS linter rejects construct
// signatures on interfaces: arkts-no-ctor-signatures-iface); `new ctor(...)` on an ESObject
// crosses into the dynamic shape the unresolved kit module actually has.
interface HmsAccountAuthentication {
  HuaweiIDProvider: ESObject;
  AuthenticationController: ESObject;
}

interface HmsAccountKit {
  authentication: HmsAccountAuthentication;
}

// Map Kit probe (KIT-EXT2 capability sink + R2-3 overlay, 2026-09-26): the MapComponent ArkUI
// component only exists in the HarmonyOS SDK flavor, so the overlay lives in a separate template
// module (ets/map/MapOverlay.ets) that the ARKTS_SDK_FLAVOR=harmony build compiles and installs
// and the default OpenHarmony SDK build never sees. This shell pulls that module in through a
// variable specifier (a literal './map/MapOverlay' import would be a hard ArkTS compile error in
// the default build, and the module itself cannot compile without the component declaration) and
// casts the resolved value to the local structural interfaces below. A runtime that provides
// @kit.MapKit but no overlay module keeps the capability answer at bit 1 and the managed side on
// its documented degradation; the sink ops then answer -1 instead of guessing.
interface HmsMapKit {
  MapComponent: ESObject;
  map: ESObject;
  mapCommon: ESObject;
}

// Map overlay region/marker the managed side sends through the Map sink (JSON argument of the
// corresponding op; see runMapCommand).
interface HmsMapOverlayRegion {
  latitude: number;
  longitude: number;
  zoom: number;
}

interface HmsMapOverlayMarker {
  id: string;
  latitude: number;
  longitude: number;
  title: string;
}

// Overlay -> shell events (forwarded through the Map sink with request id 0, code 0 and the
// event op: 1 map ready, 2 marker click (payload = marker id), 3 camera idle (payload =
// "latitude\tlongitude\tzoom")).
interface HmsMapOverlayEvents {
  onReady: () => void;
  onMarkerClick: (id: string) => void;
  onCameraIdle: (latitude: number, longitude: number, zoom: number) => void;
}

// Overlay proxy implemented by MapOverlay.ets. Only nodeController is read by build()
// (NodeContainer); the rest are the control surface the sink ops drive.
interface HmsMapOverlayProxy {
  nodeController: NodeController;
  setRegion: (region: HmsMapOverlayRegion) => void;
  addMarker: (marker: HmsMapOverlayMarker) => void;
  dispose: () => void;
}

// The resolved overlay module. The proxy constructor is an ESObject (the ArkTS linter rejects
// construct signatures on interfaces: arkts-no-ctor-signatures-iface), like the kit ctors.
interface HmsMapOverlayModule {
  MapOverlayProxy: ESObject;
}

// Live View Kit probe (R2-SHELL-EXT 2026-09-26; liveViewManager): the third HMS kit probe, the
// same compile-safe shape as Push/Account/Map (the module specifier stays in a variable and the
// resolved value is cast to the local structural interfaces below; a literal
// import('@kit.LiveViewKit') is a hard ArkTS compile error on the OpenHarmony SDK). The sink
// registers only when the device reports the live view syscap and the runtime resolves the kit.
// The scenes implemented here are the TIMER scene's create/update/stop on the progress template:
// title/text/progress plus the timer value in milliseconds.
interface HmsLiveViewContent {
  text: string;
  textColor?: string;
}

// The progress template layout (progress is 0-100; the enum fields carry the kit's constants).
interface HmsLiveViewProgressLayout {
  layoutType: number;
  progress: number;
  color: string;
  backgroundColor: string;
  indicatorType: number;
  indicatorIcon: string;
  lineType: number;
  nodeIcons: string[];
}

interface HmsLiveViewPrimary {
  title: string;
  content: HmsLiveViewContent[];
  keepTime: number;
  layoutData: HmsLiveViewProgressLayout;
}

interface HmsLiveViewCapsule {
  type: number;
  status: number;
  icon?: string;
  backgroundColor?: string;
  title?: string;
  content?: string;
  time?: number;
  isCountdown?: boolean;
  isPaused?: boolean;
}

interface HmsLiveViewTimer {
  time: number;
  isCountdown: boolean;
  isPaused: boolean;
}

interface HmsLiveViewData {
  primary: HmsLiveViewPrimary;
  capsule: HmsLiveViewCapsule;
}

// One live view request body (liveViewManager.LiveView): the shell keeps it across update/stop so
// the sequence is incremented and the same id is targeted.
interface HmsLiveView {
  id: number;
  event: string;
  sequence: number;
  isMute: boolean;
  timer: HmsLiveViewTimer;
  liveViewData: HmsLiveViewData;
}

// The managed side's JSON argument (op 0/1): {"id","title","text","progress","time"}.
interface HmsLiveViewSpec {
  id?: number;
  title?: string;
  text?: string;
  progress?: number;
  time?: number;
}

// liveViewManager's constant tables (the values come from the resolved kit at runtime).
interface HmsLiveViewLayoutTypes {
  LAYOUT_TYPE_PROGRESS: number;
}

interface HmsLiveViewIndicatorTypes {
  INDICATOR_TYPE_UP: number;
}

interface HmsLiveViewLineTypes {
  LINE_TYPE_NORMAL_SOLID_LINE: number;
}

interface HmsLiveViewCapsuleTypes {
  CAPSULE_TYPE_TIMER: number;
  CAPSULE_TYPE_TEXT: number;
}

interface HmsLiveViewManager {
  isLiveViewEnabled(): Promise<boolean>;
  startLiveView(view: HmsLiveView): Promise<Object>;
  updateLiveView(view: HmsLiveView): Promise<Object>;
  stopLiveView(view: HmsLiveView): Promise<Object>;
  LayoutType: HmsLiveViewLayoutTypes;
  IndicatorType: HmsLiveViewIndicatorTypes;
  LineType: HmsLiveViewLineTypes;
  CapsuleType: HmsLiveViewCapsuleTypes;
}

interface HmsLiveViewKit {
  liveViewManager: HmsLiveViewManager;
}

// CoreSpeechKit probe (A2-TTS 2026-09-27; textToSpeech): the same compile-safe shape as the
// other kit probes - the module specifier stays in a variable and the resolved value is cast to
// these local structural interfaces (a literal import('@kit.CoreSpeechKit') is a hard ArkTS
// compile error on the OpenHarmony SDK, whose hms half is absent). The sink registers only when
// the device reports SystemCapability.AI.TextToSpeech and the runtime resolves the kit. The
// engine is created lazily for the first speak (offline mode 1, person 0) and kept so stop, the
// voice list and isBusy share it.
interface HmsTtsVoiceInfo {
  language: string;
  person: number;
  style: string;
  gender: string;
  description: string;
  status?: string;
}

// The managed side's speak/create argument JSON: {"text":"...","locale":"..."}; create only
// reads locale (empty selects the shell's zh-CN default).
interface HmsTtsSpeakArgs {
  text?: string;
  locale?: string;
}

interface HmsTtsCreateEngineParams {
  language: string;
  person: number;
  online: number;
}

interface HmsTtsSpeakParams {
  requestId: string;
}

interface HmsTtsVoiceQuery {
  requestId: string;
  online: number;
}

interface HmsTtsStartResponse {
  audioType: string;
  sampleRate: number;
  sampleBit: number;
  audioChannel: number;
  compressRate: number;
}

interface HmsTtsCompleteResponse {
  type: number;
  message: string;
}

interface HmsTtsStopResponse {
  type: number;
  message: string;
}

interface HmsTtsSpeakListener {
  onStart: (requestId: string, response: HmsTtsStartResponse) => void;
  onComplete: (requestId: string, response: HmsTtsCompleteResponse) => void;
  onStop: (requestId: string, response: HmsTtsStopResponse) => void;
  onError: (requestId: string, errorCode: number, errorMessage: string) => void;
}

interface HmsTtsEngine {
  setListener(listener: HmsTtsSpeakListener): void;
  speak(text: string, speakParams: HmsTtsSpeakParams): void;
  listVoices(params: HmsTtsVoiceQuery): Promise<Array<HmsTtsVoiceInfo>>;
  stop(): void;
  isBusy(): boolean;
  shutdown(): void;
}

interface HmsTtsModule {
  createEngine(params: HmsTtsCreateEngineParams): Promise<HmsTtsEngine>;
  listVoices(queryParams: HmsTtsVoiceQuery): Promise<Array<HmsTtsVoiceInfo>>;
}

interface HmsCoreSpeechKit {
  textToSpeech: HmsTtsModule;
}

// Reduce animations (accessibility, @since 23; P1a-ANIM). The kit is pulled in lazily and the
// probe is defensive (typeof checks + try/catch), so a device whose framework predates the API
// keeps the managed default and the compile stays compatible with the API-18 build config.
// The shell reports the setting with host.notifyAnimationReduce(0/1); the managed side gates
// MAUI's ticker and the slice's page/shared/control transitions on it.
interface HmsAnimationReduceApi {
  isAnimationReduceEnabledSync(): boolean;
  onAnimationReduceStateChange(callback: (enabled: boolean) => void): void;
  offAnimationReduceStateChange(callback?: (enabled: boolean) => void): void;
}

interface HmsAccessibilityKit {
  accessibility: HmsAnimationReduceApi;
}

// Logging (audit ARKTS-S3): the shell logs through hilog with one domain/tag pair; the private
// log helpers in the struct keep the %{public}s format so device logs stay readable.
const DOMAIN = 0x0002;
const TAG = 'OHOS_MAUI';
// Blazor WebAssembly console markers (B2): a staged site logs BLZ_* diagnostics; the Web
// component forwards them to hilog under the same tag the ArkTS Blazor host uses, so a machine
// verdict is `hilog | grep BlazorWebHost` for both hosts (`marker: BLZ_BOOT` / `BLZ_RENDERED`).
const BLZ_TAG = 'BlazorWebHost';

// SLOTS-DYNAMIC overlay pool: the shell declares the hot pair (slots 0/1) at startup and grows
// the overlay set on demand up to WEB_SLOT_MAX. Slots at or above WEB_SLOT_HOT are removed
// again when the managed pool releases them ("slot destroy"), so an idle dynamic ArkWeb cannot
// keep its engine and document alive; the managed pool mirrors both numbers (OHOS_OVERLAY_MAX /
// OHOS_OVERLAY_HOT, defaults 4/2) and learns this ceiling from the "capacity" page event.
const WEB_SLOT_MAX: number = 4;
const WEB_SLOT_HOT: number = 2;
// Bound on the per-slot deferral queue (see pendingWebOps).
const WEB_SLOT_PENDING_MAX: number = 32;

// MULTIWINDOW-M subwindow bridge.
// Commands (managed -> shell; handleSubWindowCommand): 0 create, 1 move, 2 resize, 3 show,
// 4 hide (not supported by the public subwindow API: answered with a Failed event), 5 close.
// Events (shell -> managed; mirror the slice's OpenHarmonySubWindowEventKind): 0 created,
// 1 shown, 2 hidden, 3 moved, 4 resized, 5 closed, 6 touch, 7 failed, 8 page ready,
// 9 main window suspended, 10 main window resumed.
const SUB_CMD_CREATE: number = 0;
const SUB_CMD_MOVE: number = 1;
const SUB_CMD_RESIZE: number = 2;
const SUB_CMD_SHOW: number = 3;
const SUB_CMD_HIDE: number = 4;
const SUB_CMD_CLOSE: number = 5;
const SUB_EVENT_CREATED: number = 0;
const SUB_EVENT_SHOWN: number = 1;
const SUB_EVENT_HIDDEN: number = 2;
const SUB_EVENT_MOVED: number = 3;
const SUB_EVENT_RESIZED: number = 4;
const SUB_EVENT_CLOSED: number = 5;
const SUB_EVENT_FAILED: number = 7;
const SUB_EVENT_SUSPENDED: number = 9;
const SUB_EVENT_RESUMED: number = 10;
// The subwindow's named route (pages/SubWindow.ets) and its parent-window name; both are
// single-instance by design (one application subwindow in this slice).
const SUB_WINDOW_ROUTE: string = 'ohos_dotnet_subwindow';
const SUB_WINDOW_NAME: string = 'ohos_dotnet_subwindow';
// The UI ability publishes these on the UIAbilityContext event hub (EntryAbility.ui.ets); the
// page mirrors them into the same suspend/resume state, because a Home-key/gesture background
// does not deliver WINDOW_HIDDEN to the main window (SOAK49 v1).
const SUB_WINDOW_APP_BACKGROUND_EVENT: string = 'ohos_dotnet_app_background';
const SUB_WINDOW_APP_FOREGROUND_EVENT: string = 'ohos_dotnet_app_foreground';

// One per-overlay command a slot had to defer because its ArkWeb was still being created
// (SLOTS-DYNAMIC): replayed in arrival order from the new component's onControllerAttached.
// requestId is only used by the eval channel (registerWebEvalSink).
interface WebPendingOp {
  op: string;
  arg: string;
  requestId: number;
}

@Entry
@Component
struct Index {
  private content: NodeContent = new NodeContent();

  @State inputText: string = '';
  // MULTI-OVL: the shell declares two ArkWeb overlays and every per-overlay state is indexed by
  // slot (0/1). The managed web handlers claim a slot when they connect (the HybridWebView is
  // created before the BlazorWebView on the sample page, so hybrid -> 0, Blazor -> 1), tag their
  // commands with it ("s<slot>" / "s<slot>\n<arg>") and receive the shell's page events tagged
  // the same way. Global commands (hide/suspend/resume/cookie) stay untagged and apply to both
  // overlays, and an untagged per-overlay command still lands on slot 0 (a legacy handler).
  @State webVisible: boolean[] = [false, false, false, false];
  // MULTI-OVERLAY-FULL z-order: the shell no longer keeps slot 1 permanently above slot 0. Each
  // overlay's activation order (a user touch or a programmatic show/load on that slot) is
  // tracked and applied as its zIndex, so the most recently activated overlay composites on top
  // (U5: overlapping web controls). `.zIndex` is an ArkUI universal attribute inside the same
  // Stack; the declaration order below only decides the initial state.
  @State webZOrder: number[] = [0, 0, 0, 0];
  // The activation counter behind webZOrder. @State (not a plain field) so the A11Y self-check
  // button's zIndex (counter + 1) is refreshed on every web activation: the self-check can
  // never be composited under an activated overlay no matter how many times a web control is
  // touched (FIX-A11YBUTTON).
  @State webZOrderSeq: number = 0;
  // FIX-WVP overlay suspension: a managed drawer renders in the managed surface below the
  // overlays, so while it is presented (`suspend`) every overlay hides and frame/load commands
  // only update its geometry instead of re-showing it; `resume` restores the pre-suspend
  // visibility (a page without a web control cannot make a stale overlay reappear). A tab
  // switch uses the plain `hide`: the hidden page is not arranged, so no stale frame follows,
  // and the next page's web control re-shows through its own frame.
  private webSuspended: boolean = false;
  private webVisibleBeforeSuspend: boolean[] = [false, false, false, false];
  // ArkWeb overlay frames (managed WebView PlatformArrange -> WebCommand "frame"): each overlay
  // starts full-window; the frame arrives in device pixels and is converted to vp with px2vp,
  // and a frame with a non-positive width/height (control not arranged yet) is ignored.
  @State webFrameX: number[] = [0, 0, 0, 0];
  @State webFrameY: number[] = [0, 0, 0, 0];
  @State webFrameW: number[] = [0, 0, 0, 0];
  @State webFrameH: number[] = [0, 0, 0, 0];
  // AOT-STARTUP: the ArkWeb components of webSlots are declared but not instantiated until the
  // managed side first uses an overlay (any defer/ensure). Creating a Web component starts the
  // ArkWeb engine synchronously on the UI thread (~0.25 s on the 2in1), and at page build that
  // init sat between the XComponent attach and its surface callback, pushing the first managed
  // frame out by ~0.27 s. An overlay that is never claimed now costs nothing.
  @State webOverlaysMounted: boolean = false;
  // SLOTS-DYNAMIC: the overlays actually declared in build(). The hot pair [0, 1] always exists;
  // a dynamic slot (>= WEB_SLOT_HOT) is appended on demand - the managed pool's "slot ensure"
  // command, or any tagged command for a slot the shell has not declared yet - and removed by
  // "slot destroy" once the pool releases it. The per-slot tables below are preallocated to
  // WEB_SLOT_MAX, so an index stays valid while a slot is created/destroyed.
  @State webSlots: number[] = [0, 1];
  // Whether a slot's ArkWeb is declared (hot: always; dynamic: after ensure/lazy create) and
  // whether its controller has attached (commands arriving in between are deferred).
  private webSlotCreated: boolean[] = [true, true, false, false];
  private webSlotAttached: boolean[] = [false, false, false, false];
  // Per-overlay commands whose slot was still being created; replayed from onControllerAttached
  // in arrival order and bounded per slot so a burst cannot grow without limit.
  private pendingWebOps: Map<number, WebPendingOp[]> = new Map();
  // One controller per overlay; the Web components below bind them in slot order. The hot pair
  // is created eagerly (the previous single-overlay behavior); a dynamic controller is created
  // by ensureWebSlot and dropped by destroyWebSlot.
  private webControllers: (web_webview.WebviewController | null)[] =
    [new web_webview.WebviewController(), new web_webview.WebviewController(), null, null];
  @State menuItems: HostMenuItem[] = [];
  // HybridWebView asset bridge state (registered by the managed handler; empty -> no
  // interception, so the regular WebView flows are never touched). MULTI-OVERLAY-FULL: the
  // registration state is per overlay slot, because two HybridWebViews on the same page each
  // register their own layout on their own slot and the shell must serve each document from its
  // own registration (same origin, different default file/root, different document id).
  private hybridBase: string[] = ['', '', '', ''];
  private hybridRoot: string[] = ['', '', '', ''];
  private hybridDefaultFile: string[] = ['', '', '', ''];
  private hybridRegistered: boolean[] = [false, false, false, false];
  // Per-registration document id (HybridAssetsConfig.id): stamped into matching documents and
  // echoed in the message envelope; '' means the page was not served for a registration.
  private hybridDocId: string[] = ['', '', '', ''];
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
  // MAUI's Blazor origin: BlazorWebViewHandler.AppOrigin (https://0.0.0.0/). A Blazor
  // WebAssembly site registration may use a different origin (the managed WebView handler's
  // WasmSiteOrigin) and sets blazorWasmMode, which keeps the hybrid bootstrap out of the page.
  private blazorOrigin: string = 'https://0.0.0.0/';
  private blazorWasmMode: boolean = false;
  // Bounded diagnostics: the first few intercepted Blazor requests are logged so a device run
  // shows that the origin is armed and being served (the full 600+ request stream would spam).
  private blazorServeLogs: number = 0;
  // The same bounded diagnostics for the hybrid origin (https://0.0.0.1/): its served requests
  // are the device evidence that the HybridWebView page really loaded (one counter per slot).
  private hybridServeLogs: number[] = [0, 0, 0, 0];
  // Managed status-file polling (device diagnostics): bounded reads of <filesDir>/dotnet-status.txt
  // while the app starts; see pollManagedStatus.
  private statusReads: number = 0;
  private statusSeen: string = '';
  // One bootstrap per loaded document: reset in onPageBegin, so a navigation/reload runs the
  // sequence again while repeated onPageEnd callbacks for the same document do not. Indexed by
  // slot (MULTI-OVL): a slot-0 page begin must not reset the Blazor overlay's bootstrap.
  private blazorBootstrapped: boolean[] = [false, false, false, false];
  // JS -> .NET invocation state: the intercepted __hwvInvokeDotNet responses held open until
  // the managed handler answers through host.registerHybridInvokeResultSink.
  private hybridInvokeSeq: number = 0;
  private hybridInvokes: Map<number, HybridPendingInvoke> = new Map();
  // Bounded diagnostics for the hybrid endpoint frame gate: the first rejected requests log
  // their main-frame/header view, so a device run can explain a 400 without a rebuild.
  private hybridEndpointLogs: number = 0;
  // Last-resort timeout so a lost invocation rejects the fetch instead of hanging it; the
  // managed handler answers with its own error payload after 10 s.
  private hybridInvokeTimeoutMs: number = 15000;
  // JavaScript bridge: set once the dotnetHost proxy was registered on the attached controller,
  // per overlay slot (the proxy is registered on each Web component's controller).
  private dotNetHostRegistered: boolean[] = [false, false, false, false];
  // App theme: 'colorMode' is an ArkUI environment property that the framework keeps in
  // AppStorage and refreshes when the device switches between light and dark. The watch
  // forwards every change to the managed side through host.notifyTheme(isDark).
  @StorageProp('colorMode') @Watch('onColorModeChanged') colorMode: ColorMode = ColorMode.LIGHT;
  // Battery/DeviceDisplay (Essentials): the last batteryInfo/power snapshot is pushed through
  // host.notifyBattery on the battery common events, the display snapshot through
  // host.notifyDisplay on display.on('change'). Registered once per page.
  private batteryEventsRegistered: boolean = false;
  private displayChangeRegistered: boolean = false;
  // MULTIWINDOW-S: the main window's size/free-window observers are registered once per page
  // (see subscribeWindowShapeChange); the flag keeps a repeated aboutToAppear idempotent and
  // the disposer unregisters the exact callbacks.
  private windowShapeRegistered: boolean = false;
  // MULTIWINDOW-M: the one application subwindow and its bookkeeping. All null/0 until the
  // managed side creates it; every operation then degrades to a no-op, so an app that never
  // opens a child pays nothing (no observer, no window, no per-frame work).
  private subWindow: window.Window | null = null;
  private subWindowId: number = -1;
  private subWindowCreating: boolean = false;
  // The main window resolved before the first child exists (getLastWindow would return the
  // focused child afterwards), and the once-registered main-window event observer.
  private subWindowMainWindow: window.Window | null = null;
  private subWindowMainEventsRegistered: boolean = false;
  // The main window's HIDDEN/SHOWN state; while suspended, managed show/move/resize commands are
  // skipped (the system already suspends the child with its parent) and reported as failed.
  private subWindowSuspended: boolean = false;
  // Bundle metadata (Essentials IAppInfo version/build/name): published to the host once at
  // page load from the bundle manager (see reportBundleInfo), guarded so a page reappearance
  // does not re-read it.
  private bundleInfoReported: boolean = false;
  // Clipboard (Essentials): reading the pasteboard needs ohos.permission.READ_PASTEBOARD
  // (user_grant); the grant is cached and only an explicit GetTextAsync (op 1) may prompt. A
  // denied prompt is cached too, and the pasteboard 'update' observer (registered once, freed
  // in aboutToDisappear) never prompts.
  private clipboardReadGranted: boolean = false;
  private clipboardReadDenied: boolean = false;
  private clipboardObserverRegistered: boolean = false;
  private clipboardObserver: (() => void) | null = null;
  // Connectivity (Essentials): the NetworkKit connection observer registers once per page
  // (lazily imported; see subscribeNetworkChanges). Disposal flips networkDisposed so a late
  // kit callback cannot reach the host after the page is gone.
  private networkObserverRegistered: boolean = false;
  private networkDisposed: boolean = false;
  // Safe area (soft input): the window's avoid-area observer tracks the keyboard
  // (AvoidAreaType.TYPE_KEYBOARD) and pushes its height through host.notifySoftInputArea so the
  // managed SafeArea can pad SafeAreaEdges.SoftInput/All above the keyboard. The system avoid
  // area report above keeps its own slot. Registered once per page; unregistered in
  // aboutToDisappear with the stored listener.
  private softInputRegistered: boolean = false;
  private softInputWindow: window.Window | null = null;
  private softInputListener: ((data: window.AvoidAreaOptions) => void) | null = null;
  // Overlay avoid-area (audit ARKTS-S3): the status/navigation bars and the soft keyboard
  // inset the overlay controls (shell panel, menu handle, A11Y button) so a full-screen
  // managed surface cannot hide them. The managed/self-drawn content keeps its existing path
  // (host.notifyAvoidArea/notifySoftInputArea -> managed SafeArea); this state is only read by
  // the overlay layout in build().
  @State avoidTop: number = 0;
  @State avoidBottom: number = 0;
  @State avoidLeft: number = 0;
  @State avoidRight: number = 0;
  @State keyboardBottom: number = 0;
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
  // Bluetooth GATT (platform extra): one cached GattClientDevice per device address; the kit
  // listeners registered with it push value/state/MTU events to the managed side. The
  // createGattClientDevice factory is cached from the lazily imported Connectivity Kit (the same
  // pattern as the flashlight's camera factory), and the two waiter maps resolve an in-flight
  // connect / request-MTU operation from the kit callback.
  private gattClients: Map<string, ble.GattClientDevice> = new Map();
  private gattCreateClient: ((address: string) => ble.GattClientDevice) | undefined = undefined;
  private gattConnectWaiters: Map<string, (connected: boolean) => void> = new Map();
  private gattMtuWaiters: Map<string, (mtu: number) => void> = new Map();
  // Last ProfileConnectionState value reported by the kit per address; a repeated connect while
  // the state is STATE_CONNECTED (2) answers immediately instead of waiting for a state callback
  // that the platform will not send again.
  private gattStates: Map<string, number> = new Map();
  private gattConnectTimeoutMs: number = 10000;
  private gattMtuTimeoutMs: number = 2000;
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
  // HMS Kit feature probes (Share/Scan; see the interface block at the top of the file): the
  // resolved module object once the import succeeded, and the cached failure so the probe runs
  // once per page. A kit whose probe failed keeps its sink unregistered.
  private hmsShareKit: HmsShareKit | undefined = undefined;
  private hmsScanKit: HmsScanKit | undefined = undefined;
  private hmsPushKit: HmsPushKit | undefined = undefined;
  private hmsAccountKit: HmsAccountKit | undefined = undefined;
  private hmsMapKit: HmsMapKit | undefined = undefined;
  // Map overlay (R2-3): the overlay module resolved in this shell build, the live proxy while
  // the overlay exists, the cached capability flags (bit 0 = @kit.MapKit resolved, bit 1 = the
  // overlay module resolved) and the cached overlay-module failure. mapOverlayActive is the
  // @State build() reads (the proxy itself is a plain field: only its nodeController is used).
  private hmsMapOverlay: HmsMapOverlayProxy | undefined = undefined;
  private hmsMapOverlayModule: HmsMapOverlayModule | undefined = undefined;
  private hmsMapOverlayUnavailable: boolean = false;
  private hmsMapFlags: number = 0;
  @State mapOverlayActive: boolean = false;
  @State mapOverlayVisible: boolean = false;
  private hmsShareUnavailable: boolean = false;
  private hmsScanUnavailable: boolean = false;
  private hmsPushUnavailable: boolean = false;
  private hmsAccountUnavailable: boolean = false;
  private hmsMapUnavailable: boolean = false;
  // Live View Kit probe (R2-SHELL-EXT): the resolved kit plus the live view the shell owns
  // (null before create / after stop) and the cached probe failure. The view object is kept so
  // update/stop increment its sequence and target the same id; the managed side only sends the
  // content fields.
  private hmsLiveViewKit: HmsLiveViewKit | undefined = undefined;
  private hmsLiveViewUnavailable: boolean = false;
  private hmsLiveViewView: HmsLiveView | undefined = undefined;
  // CoreSpeechKit probe (A2-TTS): the resolved kit, the cached probe failure, the engine created
  // lazily for the first speak (kept so stop/locales/isBusy share it), the language it was
  // created with, and the in-flight speak requests keyed by the kit request id (the managed
  // request id as text) so onComplete/onStop/onError answer the right managed request.
  private hmsTtsKit: HmsCoreSpeechKit | undefined = undefined;
  private hmsTtsUnavailable: boolean = false;
  private hmsTtsEngine: HmsTtsEngine | undefined = undefined;
  private hmsTtsEngineLanguage: string = '';
  private hmsTtsPending: Map<string, number> = new Map();
  // Reduce animations (accessibility; P1a-ANIM): the resolved API object and the cached probe
  // failure. The native host replays the last reported value when the managed listener
  // registers, so a registration race cannot lose the first notification.
  private animationReduceApi: HmsAnimationReduceApi | undefined = undefined;
  private animationReduceUnavailable: boolean = false;
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
  // Raw HAP resources (resources/rawfile/**): the cap on one read (mirrors
  // OHOS_HOST_RAW_FILE_MAX_BYTES in openharmony_host.h and the managed MaxBytes), the cached
  // resource manager and a one-time log flag for a read error other than "not found" ("not
  // found" is a normal answer).
  private rawFileMaxBytes: number = 8 * 1024 * 1024;
  private rawFileManager: resourceManager.ResourceManager | undefined = undefined;
  private rawFileErrorLogged: boolean = false;
  // B6 navigation allow-list state: a cancelled external navigation waits for the managed
  // Navigating decision under its unguessable id; navApproved/navProgrammatic are the one-shot
  // markers that let the shell's own reloads pass, indexed by overlay slot (MULTI-OVL). All
  // entries are time-bounded and dropped when they expire.
  private navPending: Map<string, PendingNavigation> = new Map();
  private navApproved: (ApprovedNavigation | null)[] = [null, null, null, null];
  private navProgrammatic: (ApprovedNavigation | null)[] = [null, null, null, null];
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
    this.logError(`[maui] ${name} unavailable on this device: ${detail}`);
  }

  // Host-export guard (device-compat): logs a missing/failed host export once per page.
  private reportHostUnavailable(api: string, error: Error | undefined): void {
    if (this.hostUnavailable.has(api)) {
      return;
    }
    this.hostUnavailable.add(api);
    const detail: string = error !== undefined ? ` (${error.message})` : '';
    this.logError(`[maui] host export unavailable: ${api}${detail}`);
  }

  // HMS Kit probes (Share/Scan; see the interface block at the top of the file). Both run once
  // per page: a resolved kit registers its sink, a missing kit caches the failure (one log) and
  // leaves the sink unregistered - the host export then answers -1 and the managed side records
  // the degradation instead of guessing. The specifiers stay in variables so the OpenHarmony SDK
  // build (no @kit.ShareKit/@kit.ScanKit declarations) still compiles; see the probe note above.
  private async probeShareKit(): Promise<void> {
    if (this.hmsShareUnavailable || this.hmsShareKit !== undefined) {
      return;
    }
    const kitName: string = '@kit.ShareKit';
    try {
      const kit = (await import(kitName)) as HmsShareKit;
      if (kit.systemShare === undefined || kit.systemShare.SharedData === undefined || kit.systemShare.ShareController === undefined) {
        throw new Error('the resolved module has no systemShare.SharedData/ShareController');
      }
      this.hmsShareKit = kit;
      this.hostCall('registerShareKitSink', typeof host !== 'undefined' && typeof host.registerShareKitSink === 'function', (): void => {
        host.registerShareKitSink((uris: string, title: string): boolean => {
          return this.dispatchShareKit(uris, title);
        });
      });
      this.logInfo('[maui] Share Kit available: multi-file share sink registered');
    } catch (shareProbeError) {
      this.hmsShareUnavailable = true;
      this.logError(`[maui] Share Kit unavailable on this device: ${(shareProbeError as Error).message}`);
    }
  }

  private async probeScanKit(): Promise<void> {
    if (this.hmsScanUnavailable || this.hmsScanKit !== undefined) {
      return;
    }
    if (!canIUse('SystemCapability.Multimedia.Scan.ScanBarcode')) {
      this.hmsScanUnavailable = true;
      this.logError('[maui] Scan Kit unavailable: the device reports no ScanBarcode syscap');
      return;
    }
    const kitName: string = '@kit.ScanKit';
    try {
      const kit = (await import(kitName)) as HmsScanKit;
      if (kit.scanBarcode === undefined || kit.scanBarcode.startScanForResult === undefined) {
        throw new Error('the resolved module has no scanBarcode.startScanForResult');
      }
      this.hmsScanKit = kit;
      this.hostCall('registerScanSink', typeof host !== 'undefined' && typeof host.registerScanSink === 'function', (): void => {
        host.registerScanSink((requestId: number): void => {
          this.runScan(requestId);
        });
      });
      this.logInfo('[maui] Scan Kit available: default-scan sink registered');
    } catch (scanProbeError) {
      this.hmsScanUnavailable = true;
      this.logError(`[maui] Scan Kit unavailable on this device: ${(scanProbeError as Error).message}`);
    }
  }

  // Share Kit sink body: one SharedData record per file:// URI (converted with
  // fileUri.getUriFromPath so the receiver gets a readable sandbox URI) and the system panel.
  // The show() promise outcome is logged; the boolean answer only reports that the panel was
  // dispatched, matching the ability sink's synchronous contract.
  private dispatchShareKit(uris: string, title: string): boolean {
    const kit = this.hmsShareKit;
    if (kit === undefined || uris.length === 0) {
      return false;
    }
    try {
      const dataCtor: ESObject = kit.systemShare.SharedData;
      let data: HmsShareData | undefined = undefined;
      for (const entry of uris.split('\n')) {
        if (entry.length === 0) {
          continue;
        }
        let uri: string = entry;
        try {
          const path: string = entry.startsWith('file://') ? entry.substring(7) : entry;
          uri = fileUri.getUriFromPath(path);
        } catch {
          // An unconvertible entry keeps its plain file:// form; the panel decides.
        }
        const record: HmsShareRecord = title.length > 0
          ? { utd: utd.UniformDataType.FILE, uri: uri, title: title }
          : { utd: utd.UniformDataType.FILE, uri: uri };
        if (data === undefined) {
          data = new dataCtor(record) as HmsShareData;
        } else {
          data.addRecord(record);
        }
      }
      if (data === undefined) {
        return false;
      }
      const controllerCtor: ESObject = kit.systemShare.ShareController;
      const controller: HmsShareController = new controllerCtor(data) as HmsShareController;
      controller.on('shareCompleted', (result: Object): void => {
        this.logInfo('[maui] share panel completed');
      });
      const showOptions: HmsShareShowOptions = {};
      controller.show(this.hostContext() as Object, showOptions).then((): void => {
        this.logInfo('[maui] share panel dispatched');
      }).catch((showError: Error): void => {
        this.logError(`[maui] share panel failed: ${showError.message}`);
      });
      return true;
    } catch (shareDispatchError) {
      this.logError(`[maui] share dispatch failed: ${(shareDispatchError as Error).message}`);
      return false;
    }
  }

  // Scan Kit sink body: runs the default-UI scan and answers the host. rc (see
  // OpenHarmonyScan.ResultCode): 0 the value was scanned, -1 unavailable/failed, -2 cancelled
  // (Scan Kit error 1000500002).
  private async runScan(requestId: number): Promise<void> {
    const kit = this.hmsScanKit;
    let code: number = -1;
    let value: string = '';
    if (kit !== undefined) {
      try {
        const result = await kit.scanBarcode.startScanForResult(this.hostContext() as Object);
        value = result.originalValue;
        code = 0;
      } catch (scanError) {
        const scanCode: number = (scanError as BusinessError).code;
        code = scanCode === 1000500002 ? -2 : -1;
        this.logError(`[maui] scan request failed: code=${scanCode} ${(scanError as Error).message}`);
      }
    }
    this.hostCall('notifyScanResult', typeof host !== 'undefined' && typeof host.notifyScanResult === 'function', (): void => {
      host.notifyScanResult(requestId, code, value);
    });
  }

  // Push Kit probe (KIT-EXT2; see the interface block at the top of the file). Registers the
  // token sink only when the runtime provides @kit.PushKit with getToken/deleteToken.
  private async probePushKit(): Promise<void> {
    if (this.hmsPushUnavailable || this.hmsPushKit !== undefined) {
      return;
    }
    const kitName: string = '@kit.PushKit';
    try {
      const kit = (await import(kitName)) as HmsPushKit;
      if (kit.pushService === undefined || kit.pushService.getToken === undefined || kit.pushService.deleteToken === undefined) {
        throw new Error('the resolved module has no pushService.getToken/deleteToken');
      }
      this.hmsPushKit = kit;
      this.hostCall('registerPushSink', typeof host !== 'undefined' && typeof host.registerPushSink === 'function', (): void => {
        host.registerPushSink((requestId: number, op: number): void => {
          this.runPush(requestId, op);
        });
      });
      this.logInfo('[maui] Push Kit available: token sink registered');
    } catch (pushProbeError) {
      this.hmsPushUnavailable = true;
      this.logError(`[maui] Push Kit unavailable on this device: ${(pushProbeError as Error).message}`);
    }
  }

  // Push Kit sink body: op 0 getToken, op 1 deleteToken. rc (see OpenHarmonyPush.Status): 0 the
  // call completed (the token payload for op 0), -1 the kit is unavailable or threw a
  // non-positive code, a positive value is the Push Kit BusinessError code (1000900010 AGC
  // configuration/signature, 1000900012 the push entitlement is not enabled, ...) which the
  // managed side maps onto its own status.
  private async runPush(requestId: number, op: number): Promise<void> {
    const kit = this.hmsPushKit;
    let code: number = -1;
    let token: string = '';
    if (kit !== undefined) {
      try {
        if (op === 1) {
          await kit.pushService.deleteToken();
        } else {
          token = await kit.pushService.getToken();
        }
        code = 0;
      } catch (pushError) {
        const pushCode: number = (pushError as BusinessError).code;
        code = pushCode > 0 ? pushCode : -1;
        this.logError(`[maui] push request failed: op=${op} code=${code} ${(pushError as Error).message}`);
      }
    }
    this.hostCall('notifyPushResult', typeof host !== 'undefined' && typeof host.notifyPushResult === 'function', (): void => {
      host.notifyPushResult(requestId, op, code, token);
    });
  }

  // Account Kit probe (KIT-EXT2): registers the authorization sink only when the runtime
  // provides @kit.AccountKit authentication with the HuaweiIDProvider/AuthenticationController
  // constructors.
  private async probeAccountKit(): Promise<void> {
    if (this.hmsAccountUnavailable || this.hmsAccountKit !== undefined) {
      return;
    }
    const kitName: string = '@kit.AccountKit';
    try {
      const kit = (await import(kitName)) as HmsAccountKit;
      if (kit.authentication === undefined || kit.authentication.HuaweiIDProvider === undefined ||
        kit.authentication.AuthenticationController === undefined) {
        throw new Error('the resolved module has no authentication.HuaweiIDProvider/AuthenticationController');
      }
      this.hmsAccountKit = kit;
      this.hostCall('registerAccountSink', typeof host !== 'undefined' && typeof host.registerAccountSink === 'function', (): void => {
        host.registerAccountSink((requestId: number, op: number, scopes: string): void => {
          this.runAccount(requestId, op, scopes);
        });
      });
      this.logInfo('[maui] Account Kit available: authorization sink registered');
    } catch (accountProbeError) {
      this.hmsAccountUnavailable = true;
      this.logError(`[maui] Account Kit unavailable on this device: ${(accountProbeError as Error).message}`);
    }
  }

  // Account Kit sink body: op 0 quick-login anonymous phone (scopes fixed to
  // quickLoginAnonymousPhone, forceAuthorization=false), op 1 authorization with the
  // '\n'-separated scopes from the managed side and permissions=['serviceauthcode'] so the
  // answer carries the authorization code. rc follows OpenHarmonyAccount.Status: 0 success
  // (payload = anonymous phone or authorization code, either may be empty), -1 unavailable or
  // a state mismatch, a positive value is the Account Kit BusinessError code (1001502014 the
  // quick-login scope is not approved, 1001500001 the signing fingerprint does not match, ...).
  private async runAccount(requestId: number, op: number, scopes: string): Promise<void> {
    const kit = this.hmsAccountKit;
    let code: number = -1;
    let payload: string = '';
    if (kit !== undefined) {
      try {
        const providerCtor: ESObject = kit.authentication.HuaweiIDProvider;
        const provider: HmsHuaweiIDProvider = new providerCtor() as HmsHuaweiIDProvider;
        const request: HmsAuthorizationRequest = provider.createAuthorizationWithHuaweiIDRequest();
        request.state = util.generateRandomUUID();
        if (op === 0) {
          request.scopes = ['quickLoginAnonymousPhone'];
          request.forceAuthorization = false;
        } else {
          request.scopes = scopes.length > 0 ? scopes.split('\n') : ['openid'];
          request.permissions = ['serviceauthcode'];
          request.forceAuthorization = true;
        }
        const controllerCtor: ESObject = kit.authentication.AuthenticationController;
        const controller: HmsAuthorizationController = new controllerCtor(this.hostContext()) as HmsAuthorizationController;
        const response: HmsAuthorizationResponse = await controller.executeRequest(request);
        if (response.state !== undefined && response.state !== request.state) {
          // State mismatch: the response does not belong to this request (CSRF guard), so the
          // answer stays the unavailable code instead of carrying an unverified payload.
          code = -1;
        } else if (op === 0) {
          const extra = response.data?.extraInfo;
          payload = extra !== undefined && extra.quickLoginAnonymousPhone !== undefined ? extra.quickLoginAnonymousPhone : '';
          code = 0;
        } else {
          const data = response.data;
          payload = data !== undefined && data.authorizationCode !== undefined ? data.authorizationCode : '';
          code = 0;
        }
      } catch (accountError) {
        const accountCode: number = (accountError as BusinessError).code;
        code = accountCode > 0 ? accountCode : -1;
        this.logError(`[maui] account request failed: op=${op} code=${code} ${(accountError as Error).message}`);
      }
    }
    this.hostCall('notifyAccountResult', typeof host !== 'undefined' && typeof host.notifyAccountResult === 'function', (): void => {
      host.notifyAccountResult(requestId, op, code, payload);
    });
  }

  // Map Kit probe (KIT-EXT2 capability sink + R2-3 overlay): the sink registers only when the
  // runtime provides @kit.MapKit with MapComponent/map/mapCommon. The device syscap
  // (SystemCapability.Map.Core) is checked first so a runtime without the map view never reports
  // the kit as usable. The overlay module probe then decides bit 1 (see probeMapOverlay).
  private async probeMapKit(): Promise<void> {
    if (this.hmsMapUnavailable || this.hmsMapKit !== undefined) {
      return;
    }
    if (!canIUse('SystemCapability.Map.Core')) {
      this.hmsMapUnavailable = true;
      this.logError('[maui] Map Kit unavailable: the device reports no SystemCapability.Map.Core');
      return;
    }
    const kitName: string = '@kit.MapKit';
    try {
      const kit = (await import(kitName)) as HmsMapKit;
      if (kit.map === undefined || kit.mapCommon === undefined || kit.MapComponent === undefined) {
        throw new Error('the resolved module has no MapComponent/map/mapCommon');
      }
      this.hmsMapKit = kit;
      const overlayAvailable: boolean = await this.probeMapOverlay();
      this.hmsMapFlags = overlayAvailable ? 3 : 1;
      this.hostCall('registerMapSink', typeof host !== 'undefined' && typeof host.registerMapSink === 'function', (): void => {
        host.registerMapSink((requestId: number, op: number, args: string): void => {
          this.runMapCommand(requestId, op, args);
        });
      });
      this.logInfo(`[maui] Map Kit available: sink registered (overlay ${overlayAvailable ? 'available' : 'unavailable in this shell build'})`);
    } catch (mapProbeError) {
      this.hmsMapUnavailable = true;
      this.logError(`[maui] Map Kit unavailable on this device: ${(mapProbeError as Error).message}`);
    }
  }

  // Map overlay module probe (R2-3): the overlay module is part of the HarmonyOS-flavor template
  // set only (it names the MapComponent component), so the specifier stays in a variable and the
  // resolved value is cast to HmsMapOverlayModule. The default OpenHarmony shell fails this probe
  // once (logged as a warning: the kit itself is fine, only the overlay is missing) and keeps
  // answering bit 1 = 0, which is what the managed side gates on.
  private async probeMapOverlay(): Promise<boolean> {
    if (this.hmsMapOverlayUnavailable || this.hmsMapOverlayModule !== undefined) {
      return this.hmsMapOverlayModule !== undefined;
    }
    const overlayModule: string = './map/MapOverlay';
    try {
      const module = (await import(overlayModule)) as HmsMapOverlayModule;
      if (module.MapOverlayProxy === undefined) {
        throw new Error('the resolved overlay module has no MapOverlayProxy');
      }
      this.hmsMapOverlayModule = module;
      return true;
    } catch (overlayProbeError) {
      this.hmsMapOverlayUnavailable = true;
      this.logWarn(`[maui] Map overlay unavailable in this shell build: ${(overlayProbeError as Error).message}`);
      return false;
    }
  }

  // Map sink body (R2-3). op 0 answers the capability flags (bit 0 = @kit.MapKit resolved,
  // bit 1 = the overlay module resolved); ops 1..6 drive the overlay: 1 create, 2 destroy,
  // 3 show, 4 hide, 5 set region (JSON HmsMapOverlayRegion), 6 add marker (JSON
  // HmsMapOverlayMarker). host.notifyMapResult(requestId, op, code, payload) carries the answer:
  // code 0 = the op was applied, -1 = the kit/overlay is unavailable or the op is unknown, -2 =
  // the overlay call itself failed. Overlay events go through the same export with requestId 0
  // (see notifyMapEvent), so the managed side can tell answers and events apart.
  private runMapCommand(requestId: number, op: number, args: string): void {
    let code: number = -1;
    let payload: string = '';
    if (op === 0) {
      code = 0;
      payload = `${this.hmsMapFlags}`;
    } else if (this.hmsMapKit === undefined || this.hmsMapOverlayModule === undefined) {
      // No kit or no overlay in this shell build: answer unavailable instead of guessing.
      code = -1;
    } else {
      try {
        if (op === 1) {
          code = this.createMapOverlay() ? 0 : -2;
        } else if (op === 2) {
          code = this.destroyMapOverlay() ? 0 : -2;
        } else if (op === 3) {
          code = this.setMapOverlayVisible(true) ? 0 : -2;
        } else if (op === 4) {
          code = this.setMapOverlayVisible(false) ? 0 : -2;
        } else if (op === 5) {
          const region = JSON.parse(args) as HmsMapOverlayRegion;
          const overlay = this.hmsMapOverlay;
          if (overlay !== undefined) {
            overlay.setRegion(region);
            code = 0;
          } else {
            code = -2;
          }
        } else if (op === 6) {
          const marker = JSON.parse(args) as HmsMapOverlayMarker;
          const overlay = this.hmsMapOverlay;
          if (overlay !== undefined) {
            overlay.addMarker(marker);
            code = 0;
          } else {
            code = -2;
          }
        } else {
          code = -1;
        }
      } catch (mapCommandError) {
        code = -2;
        this.logError(`[maui] map op ${op} failed: ${(mapCommandError as Error).message}`);
      }
    }
    this.hostCall('notifyMapResult', typeof host !== 'undefined' && typeof host.notifyMapResult === 'function', (): void => {
      host.notifyMapResult(requestId, op, code, payload);
    });
  }

  // Creates the overlay proxy (idempotent). The MapComponent only appears once the NodeContainer
  // below mounts the proxy's NodeController, so this returns as soon as the proxy exists; the
  // overlay reports the controller through the onReady event.
  private createMapOverlay(): boolean {
    if (this.hmsMapOverlay !== undefined) {
      return true;
    }
    const module = this.hmsMapOverlayModule;
    if (module === undefined) {
      return false;
    }
    const proxyCtor: ESObject = module.MapOverlayProxy;
    const events: HmsMapOverlayEvents = {
      onReady: (): void => {
        this.notifyMapEvent(1, '');
      },
      onMarkerClick: (id: string): void => {
        this.notifyMapEvent(2, id);
      },
      onCameraIdle: (latitude: number, longitude: number, zoom: number): void => {
        this.notifyMapEvent(3, `${latitude}\t${longitude}\t${zoom}`);
      }
    };
    const proxy: HmsMapOverlayProxy = new proxyCtor(this.getUIContext(), events) as HmsMapOverlayProxy;
    this.hmsMapOverlay = proxy;
    this.mapOverlayVisible = true;
    this.mapOverlayActive = true;
    return true;
  }

  // Destroys the overlay (idempotent): the NodeContainer leaves the tree on the next build and
  // the proxy releases the MapComponent/BuilderNode. A late overlay callback after this point
  // must not reach the host; the proxy owns that guard (see MapOverlay.ets).
  private destroyMapOverlay(): boolean {
    const overlay = this.hmsMapOverlay;
    this.mapOverlayActive = false;
    this.mapOverlayVisible = false;
    this.hmsMapOverlay = undefined;
    if (overlay !== undefined) {
      try {
        overlay.dispose();
      } catch (disposeError) {
        this.logWarn(`[maui] map overlay dispose failed: ${(disposeError as Error).message}`);
      }
    }
    return true;
  }

  private setMapOverlayVisible(visible: boolean): boolean {
    if (this.hmsMapOverlay === undefined) {
      return false;
    }
    this.mapOverlayVisible = visible;
    return true;
  }

  // Overlay -> managed events (requestId 0): op 1 ready, 2 marker click, 3 camera idle.
  private notifyMapEvent(op: number, payload: string): void {
    this.hostCall('notifyMapResult', typeof host !== 'undefined' && typeof host.notifyMapResult === 'function', (): void => {
      host.notifyMapResult(0, op, 0, payload);
    });
  }

  // Live View Kit probe (R2-SHELL-EXT): the sink registers only when the device reports the
  // live view syscap and the runtime resolves @kit.LiveViewKit with the full
  // start/update/stop/isLiveViewEnabled surface. A missing kit caches the failure (one log) and
  // leaves the sink unregistered: the host export then answers -1 and the managed
  // OpenHarmonyLiveView records the degradation instead of guessing. The kit still gates each
  // call on isLiveViewEnabled() (the user's live view switch) and on the AGC entitlement.
  private async probeLiveViewKit(): Promise<void> {
    if (this.hmsLiveViewUnavailable || this.hmsLiveViewKit !== undefined) {
      return;
    }
    if (!canIUse('SystemCapability.LiveView.LiveViewService')) {
      this.hmsLiveViewUnavailable = true;
      this.logError('[maui] Live View Kit unavailable: the device reports no SystemCapability.LiveView.LiveViewService');
      return;
    }
    const kitName: string = '@kit.LiveViewKit';
    try {
      const kit = (await import(kitName)) as HmsLiveViewKit;
      if (kit.liveViewManager === undefined || kit.liveViewManager.isLiveViewEnabled === undefined ||
        kit.liveViewManager.startLiveView === undefined || kit.liveViewManager.updateLiveView === undefined ||
        kit.liveViewManager.stopLiveView === undefined) {
        throw new Error('the resolved module has no liveViewManager start/update/stop/isLiveViewEnabled');
      }
      this.hmsLiveViewKit = kit;
      this.hostCall('registerLiveViewSink', typeof host !== 'undefined' && typeof host.registerLiveViewSink === 'function', (): void => {
        host.registerLiveViewSink((requestId: number, op: number, args: string): void => {
          this.runLiveView(requestId, op, args);
        });
      });
      this.logInfo('[maui] Live View Kit available: sink registered');
    } catch (liveViewProbeError) {
      this.hmsLiveViewUnavailable = true;
      this.logError(`[maui] Live View Kit unavailable on this device: ${(liveViewProbeError as Error).message}`);
    }
  }

  // Live View sink body: op 0 create, op 1 update, op 2 stop. Every op first checks
  // isLiveViewEnabled() (the kit's own switch); update/stop target the view the last create
  // built. host.notifyLiveViewResult(requestId, op, code, payload) carries the answer:
  // code 0 = the op was applied, -1 = no kit/sink (or no view for stop), -2 = the kit call
  // failed or the args were malformed, -3 = the live view switch is off, a positive code = the
  // Live View Kit BusinessError (1003500004/1003500005/1003500006/...) which the managed side
  // maps onto its own status.
  private async runLiveView(requestId: number, op: number, args: string): Promise<void> {
    const kit = this.hmsLiveViewKit;
    let code: number = -1;
    if (kit !== undefined) {
      const spec: HmsLiveViewSpec | undefined = this.parseLiveViewSpec(args);
      if (spec === undefined) {
        code = -2;
      } else {
        try {
          const enabled: boolean = await kit.liveViewManager.isLiveViewEnabled();
          if (!enabled) {
            code = -3;
          } else if (op === 0) {
            const view: HmsLiveView = this.buildLiveView(kit.liveViewManager, spec);
            await kit.liveViewManager.startLiveView(view);
            this.hmsLiveViewView = view;
            code = 0;
          } else {
            const view: HmsLiveView | undefined = this.hmsLiveViewView;
            if (view === undefined) {
              code = -4;
            } else {
              this.applyLiveViewSpec(view, spec);
              view.sequence += 1;
              if (op === 2) {
                view.liveViewData.primary.layoutData.progress = 100;
                await kit.liveViewManager.stopLiveView(view);
                this.hmsLiveViewView = undefined;
              } else {
                await kit.liveViewManager.updateLiveView(view);
              }
              code = 0;
            }
          }
        } catch (liveViewError) {
          const liveViewCode: number = (liveViewError as BusinessError).code;
          code = liveViewCode > 0 ? liveViewCode : -2;
          this.logError(`[maui] live view request failed: op=${op} code=${code} ${(liveViewError as Error).message}`);
        }
      }
    }
    this.hostCall('notifyLiveViewResult', typeof host !== 'undefined' && typeof host.notifyLiveViewResult === 'function', (): void => {
      host.notifyLiveViewResult(requestId, op, code, '');
    });
  }

  // Parses the managed JSON argument. An empty argument is an empty spec (the shell defaults
  // apply); malformed JSON answers undefined so the op reports -2 without calling the kit.
  private parseLiveViewSpec(args: string): HmsLiveViewSpec | undefined {
    if (args.length === 0) {
      return {};
    }
    try {
      return JSON.parse(args) as HmsLiveViewSpec;
    } catch (parseError) {
      this.logError(`[maui] live view args parse failed: ${(parseError as Error).message}`);
      return undefined;
    }
  }

  // Builds the TIMER-scene view (progress template) from one spec. The id comes from the managed
  // side (default 1); title/text defaults keep the kit's no-empty-content rule; the timer shows
  // the elapsed value in milliseconds and the progress bar carries [0, 100].
  private buildLiveView(manager: HmsLiveViewManager, spec: HmsLiveViewSpec): HmsLiveView {
    const id: number = spec.id !== undefined ? spec.id : 1;
    const title: string = spec.title !== undefined && spec.title.length > 0 ? spec.title : '计时中';
    const text: string = spec.text !== undefined && spec.text.length > 0 ? spec.text : `实况窗 ${id}`;
    const progress: number = spec.progress !== undefined && Number.isFinite(spec.progress)
      ? Math.min(100, Math.max(0, spec.progress)) : 0;
    const time: number = spec.time !== undefined && Number.isFinite(spec.time) && spec.time > 0 ? spec.time : 0;
    return {
      id: id,
      event: 'TIMER',
      sequence: 1,
      isMute: false,
      timer: {
        time: time,
        isCountdown: false,
        isPaused: false
      },
      liveViewData: {
        primary: {
          title: title,
          content: [{ text: text }],
          keepTime: 15,
          layoutData: {
            layoutType: manager.LayoutType.LAYOUT_TYPE_PROGRESS,
            progress: progress,
            color: '',
            backgroundColor: '',
            indicatorType: manager.IndicatorType.INDICATOR_TYPE_UP,
            indicatorIcon: '',
            lineType: manager.LineType.LINE_TYPE_NORMAL_SOLID_LINE,
            nodeIcons: []
          }
        },
        capsule: {
          type: manager.CapsuleType.CAPSULE_TYPE_TIMER,
          status: 1,
          icon: '',
          backgroundColor: '#FF308977',
          title: title,
          content: text,
          time: time,
          isCountdown: false,
          isPaused: false
        }
      }
    };
  }

  // Applies the update spec to the live view the shell owns (empty fields keep the previous
  // value). The sequence/stop mutation stays in runLiveView so the kit's ordering rule (sequence
  // must grow) is visible next to the calls.
  private applyLiveViewSpec(view: HmsLiveView, spec: HmsLiveViewSpec): void {
    if (spec.title !== undefined && spec.title.length > 0) {
      view.liveViewData.primary.title = spec.title;
    }
    if (spec.text !== undefined && spec.text.length > 0) {
      view.liveViewData.primary.content = [{ text: spec.text }];
    }
    if (spec.progress !== undefined && Number.isFinite(spec.progress)) {
      view.liveViewData.primary.layoutData.progress = Math.min(100, Math.max(0, spec.progress));
    }
    if (spec.time !== undefined && Number.isFinite(spec.time) && spec.time > 0) {
      view.timer.time = spec.time;
    }
    view.liveViewData.capsule.title = view.liveViewData.primary.title;
    view.liveViewData.capsule.content = view.liveViewData.primary.content[0].text;
    view.liveViewData.capsule.time = view.timer.time;
  }

  // CoreSpeechKit probe (A2-TTS): the sink registers only when the device reports the text-to-
  // speech syscap and the runtime resolves @kit.CoreSpeechKit with a textToSpeech.createEngine
  // surface. A missing kit caches the failure (one log) and leaves the sink unregistered: every
  // export then answers -1 and the managed OpenHarmonyTextToSpeech records the degradation
  // instead of guessing. The engine itself is created on the first speak; the probe never
  // calls it.
  private async probeTtsKit(): Promise<void> {
    if (this.hmsTtsUnavailable || this.hmsTtsKit !== undefined) {
      return;
    }
    if (!canIUse('SystemCapability.AI.TextToSpeech')) {
      this.hmsTtsUnavailable = true;
      this.logError('[maui] CoreSpeechKit unavailable: the device reports no SystemCapability.AI.TextToSpeech');
      return;
    }
    const kitName: string = '@kit.CoreSpeechKit';
    try {
      const kit = (await import(kitName)) as HmsCoreSpeechKit;
      if (kit.textToSpeech === undefined || kit.textToSpeech.createEngine === undefined) {
        throw new Error('the resolved module has no textToSpeech.createEngine');
      }
      this.hmsTtsKit = kit;
      this.hostCall('registerTtsSink', typeof host !== 'undefined' && typeof host.registerTtsSink === 'function', (): void => {
        host.registerTtsSink((requestId: number, op: number, args: string): void => {
          this.runTts(requestId, op, args);
        });
      });
      this.logInfo('[maui] CoreSpeechKit available: textToSpeech sink registered');
    } catch (ttsProbeError) {
      this.hmsTtsUnavailable = true;
      this.logError(`[maui] CoreSpeechKit unavailable on this device: ${(ttsProbeError as Error).message}`);
    }
  }

  // Reduce animations (accessibility; P1a-ANIM): resolve @kit.AccessibilityKit lazily and use
  // the animationReduce surface only when the runtime actually provides it (API 23+). The
  // initial value is reported once, later changes follow through onAnimationReduceStateChange;
  // the listener is unregistered with the page through the disposer ledger. A device/framework
  // without the API (or without the BarrierFree.Core syscap) keeps the managed default and gets
  // one warn log - the animation paths then behave exactly as before.
  private async probeAnimationReduce(): Promise<void> {
    if (this.animationReduceUnavailable || this.animationReduceApi !== undefined) {
      return;
    }
    if (!canIUse('SystemCapability.BarrierFree.Accessibility.Core')) {
      this.animationReduceUnavailable = true;
      this.logWarn('[maui] animation reduce unavailable: the device reports no BarrierFree.Accessibility.Core syscap');
      return;
    }
    const kitName: string = '@kit.AccessibilityKit';
    try {
      const kit = (await import(kitName)) as HmsAccessibilityKit;
      const api = kit.accessibility;
      if (api === undefined || typeof api.isAnimationReduceEnabledSync !== 'function' ||
          typeof api.onAnimationReduceStateChange !== 'function') {
        throw new Error('the resolved module has no animationReduce surface');
      }
      this.animationReduceApi = api;
      this.reportAnimationReduce(undefined);
      const listener = (enabled: boolean): void => {
        this.reportAnimationReduce(enabled);
      };
      api.onAnimationReduceStateChange(listener);
      this.trackDisposer((): void => {
        try {
          api.offAnimationReduceStateChange(listener);
        } catch {
          // The page is going away; a failed unregister is not actionable.
        }
      });
      this.logInfo('[maui] animation reduce observation active');
    } catch (reduceProbeError) {
      this.animationReduceUnavailable = true;
      this.logWarn(`[maui] animation reduce unavailable on this device: ${(reduceProbeError as Error).message}`);
    }
  }

  // Reports the reduce-animations setting to the managed side. The value is read once at probe
  // time when the caller has none; the native host remembers the last value and replays it when
  // the managed listener registers, so a registration race cannot lose the first notification.
  private reportAnimationReduce(enabled: boolean | undefined): void {
    const api = this.animationReduceApi;
    let reduce: boolean = enabled === true;
    if (enabled === undefined) {
      if (api === undefined) {
        return;
      }
      try {
        reduce = api.isAnimationReduceEnabledSync();
      } catch (reduceReadError) {
        this.logWarn(`[maui] animation reduce read failed: ${(reduceReadError as Error).message}`);
        return;
      }
    }
    this.hostCall('notifyAnimationReduce', typeof host !== 'undefined' && typeof host.notifyAnimationReduce === 'function', (): void => {
      host.notifyAnimationReduce(reduce ? 1 : 0);
    });
  }

  // CoreSpeechKit sink body (A2-TTS). op 0 create, op 1 speak, op 2 stop, op 3 locales,
  // op 4 isBusy; args carry the op's JSON ("" is accepted where the op needs none). Answers
  // travel through host.notifyTtsResult(requestId, op, code, payload): code 0 applied, -1 no
  // kit/sink, -2 the kit call failed or the args were malformed, a positive value is the
  // CoreSpeechKit BusinessError (1002300001 text, 1002300002 language, 1002300003 person,
  // 1002300005 engine creation, 401 arguments). A speak answers when the engine reports
  // onComplete/onStop/onError, so the managed SpeakAsync completes with the speech instead of
  // with the dispatch.
  private async runTts(requestId: number, op: number, args: string): Promise<void> {
    const kit = this.hmsTtsKit;
    let code: number = -1;
    let payload: string = '';
    if (kit !== undefined) {
      try {
        if (op === 0) {
          const createSpec: HmsTtsSpeakArgs | undefined = this.parseTtsArgs(args);
          if (createSpec === undefined) {
            code = -2;
          } else {
            const createLanguage: string = createSpec.locale !== undefined ? createSpec.locale : '';
            await this.ensureTtsEngine(kit, createLanguage);
            code = this.hmsTtsEngine !== undefined ? 0 : -2;
          }
        } else if (op === 1) {
          const speakSpec: HmsTtsSpeakArgs | undefined = this.parseTtsArgs(args);
          if (speakSpec === undefined || speakSpec.text === undefined || speakSpec.text.length === 0) {
            code = -2;
          } else {
            const speakLanguage: string = speakSpec.locale !== undefined ? speakSpec.locale : '';
            const engine: HmsTtsEngine = await this.ensureTtsEngine(kit, speakLanguage);
            const kitRequestId: string = `${requestId}`;
            this.hmsTtsPending.set(kitRequestId, requestId);
            try {
              const speakParams: HmsTtsSpeakParams = { requestId: kitRequestId };
              engine.speak(speakSpec.text, speakParams);
            } catch (speakError) {
              this.hmsTtsPending.delete(kitRequestId);
              const speakCode: number = (speakError as BusinessError).code;
              code = speakCode > 0 ? speakCode : -2;
              this.logError(`[maui] text-to-speech speak failed: code=${code} ${(speakError as Error).message}`);
              this.notifyTts(requestId, op, code, payload);
              return;
            }
            // Answered by the listener when the engine completes, stops or fails.
            return;
          }
        } else if (op === 2) {
          const engine: HmsTtsEngine | undefined = this.hmsTtsEngine;
          if (engine === undefined) {
            code = -2;
          } else {
            engine.stop();
            this.answerPendingTts(0, '');
            code = 0;
          }
        } else if (op === 3) {
          payload = await this.listTtsVoices(kit);
          code = 0;
        } else if (op === 4) {
          const engine: HmsTtsEngine | undefined = this.hmsTtsEngine;
          if (engine === undefined) {
            code = -2;
          } else {
            payload = engine.isBusy() ? '1' : '0';
            code = 0;
          }
        } else {
          code = -2;
        }
      } catch (ttsError) {
        const ttsCode: number = (ttsError as BusinessError).code;
        code = ttsCode > 0 ? ttsCode : -2;
        this.logError(`[maui] text-to-speech request failed: op=${op} code=${code} ${(ttsError as Error).message}`);
      }
    }
    this.notifyTts(requestId, op, code, payload);
  }

  // Creates (or reuses) the engine for one language. createEngine validates the language/person
  // pair and throws its BusinessError (1002300002/1002300003/1002300005) up to runTts's code
  // map; a previously created engine is shut down before the switch. An empty language selects
  // the kit's documented zh-CN example language. The listener resolves pending speak requests
  // by the kit request id.
  private async ensureTtsEngine(kit: HmsCoreSpeechKit, language: string): Promise<HmsTtsEngine> {
    const lang: string = language.length > 0 ? language : 'zh-CN';
    const current: HmsTtsEngine | undefined = this.hmsTtsEngine;
    if (current !== undefined && this.hmsTtsEngineLanguage === lang) {
      return current;
    }
    if (current !== undefined) {
      try {
        current.shutdown();
      } catch (shutdownError) {
        this.logWarn(`[maui] text-to-speech engine shutdown failed: ${(shutdownError as Error).message}`);
      }
      this.hmsTtsEngine = undefined;
    }
    const params: HmsTtsCreateEngineParams = { language: lang, person: 0, online: 1 };
    const engine: HmsTtsEngine = await kit.textToSpeech.createEngine(params);
    const listener: HmsTtsSpeakListener = {
      onStart: (kitRequestId: string, response: HmsTtsStartResponse): void => {
        // Informational: the managed side is answered on completion.
      },
      onComplete: (kitRequestId: string, response: HmsTtsCompleteResponse): void => {
        this.answerTtsPending(kitRequestId, 0, '');
      },
      onStop: (kitRequestId: string, response: HmsTtsStopResponse): void => {
        this.answerTtsPending(kitRequestId, 0, '');
      },
      onError: (kitRequestId: string, errorCode: number, errorMessage: string): void => {
        this.answerTtsPending(kitRequestId, errorCode, errorMessage);
      }
    };
    engine.setListener(listener);
    this.hmsTtsEngine = engine;
    this.hmsTtsEngineLanguage = lang;
    return engine;
  }

  // op 3: asks the kit for the voices (module-level listVoices since 5.1.1(19), the engine
  // method otherwise) and serializes them for the managed Locale list. An empty voice list is a
  // valid [] answer; a kit error propagates to runTts's code map.
  private async listTtsVoices(kit: HmsCoreSpeechKit): Promise<string> {
    const query: HmsTtsVoiceQuery = { requestId: `voices-${Date.now()}`, online: 1 };
    let voices: HmsTtsVoiceInfo[];
    if (kit.textToSpeech.listVoices !== undefined) {
      voices = await kit.textToSpeech.listVoices(query);
    } else {
      const engine: HmsTtsEngine = await this.ensureTtsEngine(kit, '');
      voices = await engine.listVoices(query);
    }
    return JSON.stringify(voices);
  }

  // Listener callbacks look the kit request id up in hmsTtsPending (a pending speak is keyed by
  // its managed request id as text, because a speak answers only when the engine completes).
  private answerTtsPending(kitRequestId: string, code: number, payload: string): void {
    const managedId: number | undefined = this.hmsTtsPending.get(kitRequestId);
    if (managedId === undefined) {
      return;
    }
    this.hmsTtsPending.delete(kitRequestId);
    this.notifyTts(managedId, 1, code, payload);
  }

  // Answers every pending speak (used by the stop op: engine.stop() may not raise onStop for
  // each one). Code 0 keeps the managed SpeakAsync contract - stopping completes the speech.
  private answerPendingTts(code: number, payload: string): void {
    const pending: Map<string, number> = this.hmsTtsPending;
    this.hmsTtsPending = new Map();
    pending.forEach((managedId: number, kitRequestId: string): void => {
      this.notifyTts(managedId, 1, code, payload);
    });
  }

  private notifyTts(requestId: number, op: number, code: number, payload: string): void {
    this.hostCall('notifyTtsResult', typeof host !== 'undefined' && typeof host.notifyTtsResult === 'function', (): void => {
      host.notifyTtsResult(requestId, op, code, payload);
    });
  }

  // Parses the managed JSON argument. An empty argument is an empty spec; malformed JSON answers
  // undefined so the op reports -2 without calling the kit.
  private parseTtsArgs(args: string): HmsTtsSpeakArgs | undefined {
    if (args.length === 0) {
      return {};
    }
    try {
      return JSON.parse(args) as HmsTtsSpeakArgs;
    } catch (parseError) {
      this.logError(`[maui] text-to-speech args parse failed: ${(parseError as Error).message}`);
      return undefined;
    }
  }

  // Host-export guard (device-compat): runs a host call behind an explicit existence check
  // and a try/catch so a mismatched .so cannot throw TypeError out of a page callback;
  // returns false when the call was not delivered. Every host.<api> access is routed through
  // this guard, including the XComponent registration that used to be the first unguarded
  // call in onLoad. registerJavaScriptProxy and the Web controller calls stay bare because
  // they are controller methods, not host exports.
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

  // Page context (audit ARKTS-S2): the global context API is deprecated in favour of the
  // component-scoped host context; every page-level context read goes through this helper.
  private hostContext(): common.UIAbilityContext {
    return this.getUIContext().getHostContext() as common.UIAbilityContext;
  }

  // Logging (audit ARKTS-S3): console logging is replaced by hilog under the shared DOMAIN/TAG.
  private logInfo(message: string): void {
    hilog.info(DOMAIN, TAG, '%{public}s', message);
  }

  // Reads the managed bridge's status file a bounded number of times and logs the tail when it
  // changed. The shell and the managed app share the app sandbox, so the page can read what the
  // managed side wrote even though hdc/shell cannot; on images that do route managed stderr to
  // hilog this is harmless (the same lines appear twice at most). W10: the file also receives
  // the app process's stderr (the runtime's unhandled-exception text), and the last poll of a
  // crashed run is what the next launch reads here, so the window covers 60 lines, one hilog
  // entry per line.
  private pollManagedStatus(): void {
    if (this.statusReads >= 12) {
      return;
    }
    this.statusReads++;
    try {
      const statusPath: string = `${this.hostContext().filesDir}/dotnet-status.txt`;
      const text: string = fs.readTextSync(statusPath);
      if (text !== this.statusSeen) {
        // FIX-PREEMPT-RAW: the overlay pool's preempted/restored/replay lines are the forensic
        // record of the slot LRU, but CEF stderr shares dotnet-status.txt and pushes them out of
        // the 60-line tail window below. Scan the segment written since the last poll (the whole
        // file when the managed side trimmed and rewrote it) and export every capacity line to
        // hilog under its own marker, so a low-noise window can always grep the original text.
        // Duplicates after a rewrite are harmless; a missed preempt line is not.
        const fresh: string = this.statusSeen.length > 0 && text.startsWith(this.statusSeen)
          ? text.substring(this.statusSeen.length)
          : text;
        this.statusSeen = text;
        const lines: string[] = text.split('\n');
        const start: number = lines.length > 60 ? lines.length - 60 : 0;
        for (let i = start; i < lines.length; i++) {
          if (lines[i].length > 0) {
            this.logInfo(`[maui] status: ${lines[i]}`);
          }
        }
        const freshLines: string[] = fresh.split('\n');
        for (let i = 0; i < freshLines.length; i++) {
          const line: string = freshLines[i];
          if (line.indexOf('overlay preempted') >= 0 || line.indexOf('overlay restored') >= 0 ||
            line.indexOf('overlay replay') >= 0) {
            this.logInfo(`[maui-capacity] ${line}`);
          }
        }
      }
    } catch {
      // No status file yet (or no context): the next poll tries again.
    }
    setTimeout(() => this.pollManagedStatus(), 3000);
  }

  private logWarn(message: string): void {
    hilog.warn(DOMAIN, TAG, '%{public}s', message);
  }

  private logError(message: string): void {
    hilog.error(DOMAIN, TAG, '%{public}s', message);
  }

  // Callback deregistration ledger (audit ARKTS-S3): every page-scoped kit listener registers a
  // disposer here and aboutToDisappear runs them all, so no callback outlives the page (display,
  // battery common events, connectivity, bluetooth discovery). Window, clipboard and GATT keep
  // their dedicated stored fields because they need the exact listener instance.
  private disposers: Array<() => void> = [];

  private trackDisposer(dispose: () => void): void {
    this.disposers.push(dispose);
  }

  private runDisposers(): void {
    const pending: Array<() => void> = this.disposers;
    this.disposers = [];
    for (const dispose of pending) {
      try {
        dispose();
      } catch (disposeError) {
        this.logWarn(`callback unregister failed: ${(disposeError as Error).message}`);
      }
    }
  }

  // Forwards the current device colour mode (1 = dark, 0 = light) to the managed app.
  private reportTheme(): void {
    try {
      const mode: ColorMode | undefined = AppStorage.get<ColorMode>('colorMode');
      this.hostCall('notifyTheme', typeof host !== 'undefined' && typeof host.notifyTheme === 'function', (): void => {
        host.notifyTheme(mode === ColorMode.DARK ? 1 : 0);
      });
    } catch {
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
        this.hostCall('notifyBattery', typeof host !== 'undefined' && typeof host.notifyBattery === 'function', (): void => {
          host.notifyBattery(payload);
        });
      } catch {
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
      this.hostCall('notifyDisplay', typeof host !== 'undefined' && typeof host.notifyDisplay === 'function', (): void => {
        host.notifyDisplay(payload);
      });
    } catch {
      // The managed side keeps its empty display info.
    }
  }

  // Bundle metadata (Essentials IAppInfo): the managed side reads VersionString/BuildString
  // (and PackageName's host fallback) from the stored bundle info, so the HAP's real values
  // come from bundleManager.getBundleInfoForSelfSync once at page load. Device-compat: the
  // bundle manager is imported lazily; a missing module is cached and the managed side keeps
  // its documented fallbacks ("1.0.0" and the context bundle name).
  private async reportBundleInfo(): Promise<void> {
    if (this.bundleInfoReported || this.lazyUnavailable('bundleManager')) {
      return;
    }
    this.bundleInfoReported = true;
    try {
      const modules = await import('@kit.AbilityKit');
      try {
        const info = modules.bundleManager.getBundleInfoForSelfSync(
          modules.bundleManager.BundleFlag.GET_BUNDLE_INFO_WITH_APPLICATION);
        this.hostCall('setBundleInfo', typeof host !== 'undefined' && typeof host.setBundleInfo === 'function', (): void => {
          host.setBundleInfo(info.versionName, `${info.versionCode}`, info.name);
        });
      } catch (bundleError) {
        this.logError(`[maui] bundle info read failed: ${(bundleError as Error).message}`);
      }
    } catch (bundleImportError) {
      this.noteLazyFailure('bundleManager', bundleImportError as Error);
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
        const eventHandler = (subscribeError: BusinessError, event: commonEventManager.CommonEventData): void => {
          if (!subscribeError) {
            this.reportBattery();
          }
        };
        basicServices.commonEventManager.subscribe(subscriber, eventHandler);
        this.trackDisposer((): void => {
          basicServices.commonEventManager.unsubscribe(subscriber);
          this.batteryEventsRegistered = false;
        });
        this.batteryEventsRegistered = true;
      } catch (batteryEventError) {
        this.logError(`[maui] battery events unavailable: ${(batteryEventError as Error).message}`);
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
      const displayListener = (displayId: number): void => {
        this.reportDisplay();
      };
      display.on('change', displayListener);
      this.trackDisposer((): void => {
        display.off('change', displayListener);
        this.displayChangeRegistered = false;
      });
      this.displayChangeRegistered = true;
    } catch (displayEventError) {
      this.logError(`[maui] display change events unavailable: ${(displayEventError as Error).message}`);
    }
  }

  // Safe area: mirrors the window's system avoid area onto the shell's overlay insets (the
  // A11Y button/menu) and forwards it to the managed SafeArea. Called at startup and on a
  // window size change (MULTIWINDOW-S), which can move the system bars on 2in1.
  private reportWindowAvoidArea(win: window.Window): void {
    const area = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
    this.avoidTop = area.topRect.height;
    this.avoidBottom = area.bottomRect.height;
    this.avoidLeft = area.leftRect.width;
    this.avoidRight = area.rightRect.width;
    this.hostCall('notifyAvoidArea', typeof host !== 'undefined' && typeof host.notifyAvoidArea === 'function', (): void => {
      host.notifyAvoidArea(area.topRect.height, area.bottomRect.height,
                           area.leftRect.width, area.rightRect.width);
    });
  }

  // MULTIWINDOW-S (A0 2in1 form adaptation): the ability declares supportWindowModes
  // (fullscreen/split/floating, see module.json.template), so the 2in1 window can be resized,
  // split or put into free window mode. The page (and its 100% XComponent) follows the new
  // size and the native host re-arranges the managed window through the surface callback; this
  // observer records the shape change and re-reads the avoid area, which can move with the
  // window. Best effort: a runtime without isInFreeWindowMode only costs the mode read.
  private subscribeWindowShapeChange(): void {
    if (this.windowShapeRegistered) {
      return;
    }
    window.getLastWindow(this.hostContext()).then((win) => {
      if (this.windowShapeRegistered) {
        return;
      }
      const sizeListener = (size: window.Size): void => {
        let free: string = '?';
        try {
          free = win.isInFreeWindowMode() ? 'true' : 'false';
        } catch {
          // A runtime without the free-window syscap keeps the unknown marker.
        }
        this.logInfo(`[maui] window size change: ${size.width}x${size.height} free=${free}`);
        try {
          this.reportWindowAvoidArea(win);
        } catch (avoidError) {
          this.logError(`[maui] window avoid area re-read failed: ${(avoidError as Error).message}`);
        }
      };
      const freeListener = (free: boolean): void => {
        this.logInfo(`[maui] free window mode: ${free}`);
      };
      try {
        win.on('windowSizeChange', sizeListener);
        win.on('freeWindowModeChange', freeListener);
        this.trackDisposer((): void => {
          try {
            win.off('windowSizeChange', sizeListener);
          } catch {
            // A disposed window makes the unregister a no-op.
          }
          try {
            win.off('freeWindowModeChange', freeListener);
          } catch {
            // A disposed window makes the unregister a no-op.
          }
          this.windowShapeRegistered = false;
        });
        this.windowShapeRegistered = true;
        let freeNow: string = '?';
        try {
          freeNow = win.isInFreeWindowMode() ? 'true' : 'false';
        } catch {
          // Same syscap guard as the listener above.
        }
        this.logInfo(`[maui] window shape baseline: free=${freeNow}`);
      } catch (shapeError) {
        this.logError(`[maui] window shape observers unavailable: ${(shapeError as Error).message}`);
      }
    }).catch((shapeWindowError: Error): void => {
      this.logError(`[maui] window shape window unavailable: ${shapeWindowError.message}`);
    });
  }

  // MULTIWINDOW-M (in-app subwindow): registers the command sink in aboutToAppear. The managed
  // side (OpenHarmonySubWindow) sends create/move/resize/show/hide/close; an app that never
  // opens a child never sends one, and a shell without the host export logs once through
  // hostCall while the managed side reports the feature unavailable (honest degradation).
  private subscribeSubWindow(): void {
    this.hostCall('registerSubWindowSink', typeof host !== 'undefined' && typeof host.registerSubWindowSink === 'function', (): void => {
      host.registerSubWindowSink((op: number, payload: string): void => {
        this.handleSubWindowCommand(op, payload);
      });
    });
  }

  // Forwards one subwindow event (op + JSON payload) to the managed side.
  private notifySubWindowEvent(op: number, payload: string): void {
    this.hostCall('notifySubWindowEvent', typeof host !== 'undefined' && typeof host.notifySubWindowEvent === 'function', (): void => {
      host.notifySubWindowEvent(op, payload);
    });
  }

  // One JSON state report for the current child rect; an unreadable window degrades to the
  // cached id with a zero rect (the managed side treats a 0-size rect as unknown).
  private subWindowStatePayload(win: window.Window): string {
    let id: number = this.subWindowId;
    let x: number = 0;
    let y: number = 0;
    let w: number = 0;
    let h: number = 0;
    try {
      const props = win.getWindowProperties();
      id = props.id;
      x = props.windowRect.left;
      y = props.windowRect.top;
      w = props.windowRect.width;
      h = props.windowRect.height;
    } catch (stateError) {
      this.logError(`[maui] subwindow state read failed: ${(stateError as Error).message}`);
    }
    const payload: SubWindowStatePayload = { id: id, x: x, y: y, w: w, h: h };
    return JSON.stringify(payload);
  }

  private reportSubWindowState(op: number): void {
    const win = this.subWindow;
    if (win === null) {
      return;
    }
    this.notifySubWindowEvent(op, this.subWindowStatePayload(win));
  }

  private reportSubWindowFailure(code: number, message: string): void {
    const payload: SubWindowErrorPayload = { code: code, message: message };
    this.notifySubWindowEvent(SUB_EVENT_FAILED, JSON.stringify(payload));
  }

  // Clamps a managed request into the window-manager's documented bounds; an absent or
  // non-finite value falls back to the caller's default (the managed side is not trusted to
  // keep its own rect sane).
  private subWindowOffset(value: number | undefined, fallback: number): number {
    if (value === undefined || !Number.isFinite(value)) {
      return fallback;
    }
    const rounded = Math.round(value);
    if (rounded < -32768) {
      return -32768;
    }
    if (rounded > 32768) {
      return 32768;
    }
    return rounded;
  }

  private subWindowDimension(value: number | undefined, fallback: number): number {
    if (value === undefined || !Number.isFinite(value) || value <= 0) {
      return fallback;
    }
    const rounded = Math.round(value);
    if (rounded < 160) {
      return 160;
    }
    if (rounded > 16384) {
      return 16384;
    }
    return rounded;
  }

  // Resolves the main window before the first child exists (getLastWindow would return the
  // focused child afterwards) and subscribes its suspend/resume events once.
  private async resolveMainWindow(): Promise<window.Window> {
    if (this.subWindowMainWindow !== null) {
      return this.subWindowMainWindow;
    }
    const main = await window.getLastWindow(this.hostContext());
    this.subWindowMainWindow = main;
    this.subscribeMainWindowSuspension(main);
    return main;
  }

  // MULTIWINDOW-M suspend/resume coordination: the system already suspends a child window with
  // its parent, so the shell mirrors the main window's HIDDEN/SHOWN state to the managed side
  // and suppresses managed commands while suspended (see handleSubWindowCommand).
  private subscribeMainWindowSuspension(main: window.Window): void {
    if (this.subWindowMainEventsRegistered) {
      return;
    }
    try {
      main.on('windowEvent', (evt: window.WindowEventType): void => {
        if (evt === window.WindowEventType.WINDOW_HIDDEN) {
          this.setSubWindowSuspended(true, 'window event');
        } else if (evt === window.WindowEventType.WINDOW_SHOWN) {
          this.setSubWindowSuspended(false, 'window event');
        }
      });
      this.subWindowMainEventsRegistered = true;
    } catch (eventError) {
      this.logError(`[maui] main window events unavailable: ${(eventError as Error).message}`);
    }
  }

  // Fallback (SOAK49 v1): a Home key or gesture background backgrounds the ability but does not
  // deliver WINDOW_HIDDEN to the main window, so the child only ever resumed. The UI ability
  // emits its foreground/background transitions on the context event hub
  // (EntryAbility.ui.ets); both sources funnel into one deduplicated state, so a title-bar
  // minimize that fires both reports exactly one transition.
  private subscribeAppLifecycleSuspension(): void {
    try {
      const context: common.UIAbilityContext = this.hostContext();
      const backgroundListener = (): void => {
        this.setSubWindowSuspended(true, 'ability background');
      };
      const foregroundListener = (): void => {
        this.setSubWindowSuspended(false, 'ability foreground');
      };
      context.eventHub.on(SUB_WINDOW_APP_BACKGROUND_EVENT, backgroundListener);
      context.eventHub.on(SUB_WINDOW_APP_FOREGROUND_EVENT, foregroundListener);
      this.trackDisposer((): void => {
        try {
          context.eventHub.off(SUB_WINDOW_APP_BACKGROUND_EVENT, backgroundListener);
          context.eventHub.off(SUB_WINDOW_APP_FOREGROUND_EVENT, foregroundListener);
        } catch (offError) {
          this.logWarn(`[maui] app lifecycle event unregister failed: ${(offError as Error).message}`);
        }
      });
    } catch (eventError) {
      this.logWarn(`[maui] app lifecycle events unavailable: ${(eventError as Error).message}`);
    }
  }

  // The one suspend/resume state both the window event and the ability lifecycle write. The log
  // prefix stays the SOAK49/test-script marker; the suffix names the source so a device log
  // shows which path caught it.
  private setSubWindowSuspended(suspended: boolean, source: string): void {
    if (this.subWindowSuspended === suspended) {
      return;
    }
    this.subWindowSuspended = suspended;
    if (suspended) {
      this.logInfo(`[maui] main window hidden: subwindow suspended (${source})`);
      this.notifySubWindowEvent(SUB_EVENT_SUSPENDED, '{}');
    } else {
      this.logInfo(`[maui] main window shown: subwindow resumed (${source})`);
      this.notifySubWindowEvent(SUB_EVENT_RESUMED, '{}');
    }
  }

  // Dispatches one managed command. A malformed payload or an unknown op is reported as Failed
  // instead of silently dropping, so the managed side can record the degradation.
  private handleSubWindowCommand(op: number, payload: string): void {
    let cmd: SubWindowCommand = {};
    try {
      cmd = JSON.parse(payload) as SubWindowCommand;
    } catch (parseError) {
      this.logError(`[maui] subwindow command ${op} has a malformed payload: ${(parseError as Error).message}`);
      this.reportSubWindowFailure(-1, 'malformed subwindow command payload');
      return;
    }
    // While the main window is hidden, only close/hide are meaningful: the child is suspended
    // with its parent and a forced show/move would be applied to a hidden window.
    if (this.subWindowSuspended && op !== SUB_CMD_CLOSE && op !== SUB_CMD_HIDE) {
      this.logInfo(`[maui] subwindow command ${op} skipped: the main window is suspended`);
      return;
    }
    if (op === SUB_CMD_CREATE) {
      this.createSubWindow(cmd);
    } else if (op === SUB_CMD_MOVE) {
      this.moveSubWindow(cmd);
    } else if (op === SUB_CMD_RESIZE) {
      this.resizeSubWindow(cmd);
    } else if (op === SUB_CMD_SHOW) {
      this.showSubWindow();
    } else if (op === SUB_CMD_HIDE) {
      // The public subwindow API has no hide(): the child hides with its parent and close
      // destroys it. The request is answered honestly instead of pretending the state moved.
      this.reportSubWindowFailure(801, 'hiding an application subwindow is not supported; the child hides with the main window and close destroys it');
    } else if (op === SUB_CMD_CLOSE) {
      this.closeSubWindow();
    } else {
      this.logError(`[maui] subwindow command ${op} is unknown`);
      this.reportSubWindowFailure(-1, `unknown subwindow command ${op}`);
    }
  }

  // Creates the child under the main window and loads the shell-drawn page. Single-instance:
  // a repeated create reports the live window instead of leaking a second child.
  private async createSubWindow(cmd: SubWindowCommand): Promise<void> {
    if (this.subWindow !== null) {
      this.reportSubWindowState(SUB_EVENT_CREATED);
      return;
    }
    if (this.subWindowCreating) {
      return;
    }
    this.subWindowCreating = true;
    try {
      const main = await this.resolveMainWindow();
      // ParseSubWindowOptions (window_manager) converts each optional boolean and logs
      // E "Failed to convert parameter to <name>" when one is absent, keeping its false default.
      // Spell all three out (zLevelAboveParentLoosened through ShellSubWindowOptions, which the
      // public SubWindowOptions does not declare) so one create logs no conversion errors and
      // the defaults are explicit.
      const options: ShellSubWindowOptions = {
        title: cmd.title !== undefined && cmd.title.length > 0 ? cmd.title : 'MAUI',
        decorEnabled: false,
        windowRect: {
          left: this.subWindowOffset(cmd.x, 80),
          top: this.subWindowOffset(cmd.y, 120),
          width: this.subWindowDimension(cmd.w, 640),
          height: this.subWindowDimension(cmd.h, 420),
        },
        maximizeSupported: false,
        outlineEnabled: false,
        zLevelAboveParentLoosened: false,
      };
      const child = await main.createSubWindowWithOptions(SUB_WINDOW_NAME, options);
      this.subWindow = child;
      this.subWindowId = child.getWindowProperties().id;
      // pages/SubWindow.ets is a named route compiled into this shell abc; the storage passes
      // the window id so the page can refuse to move a window that is not its own. A runtime
      // without the named-route index falls back to the path form (which also needs the page in
      // the packaged main_pages.json).
      const storage: LocalStorage = new LocalStorage();
      storage.setOrCreate('subWindowId', this.subWindowId);
      try {
        await child.loadContentByName(SUB_WINDOW_ROUTE, storage);
      } catch (namedRouteError) {
        this.logError(`[maui] subwindow named route failed, falling back to setUIContent: ${(namedRouteError as Error).message}`);
        await child.setUIContent('pages/SubWindow');
      }
      child.on('windowEvent', (evt: window.WindowEventType): void => {
        this.onSubWindowWindowEvent(evt);
      });
      child.on('windowSizeChange', (_size: window.Size): void => {
        this.reportSubWindowState(SUB_EVENT_RESIZED);
      });
      child.on('windowRectChange', (_change: window.RectChangeOptions): void => {
        this.reportSubWindowState(SUB_EVENT_MOVED);
      });
      await child.setWindowBackgroundColor('#FF11161C');
      await child.showWindow();
      this.reportSubWindowState(SUB_EVENT_CREATED);
      this.logInfo(`[maui] subwindow created: ${this.subWindowStatePayload(child)}`);
    } catch (createError) {
      const error = createError as BusinessError;
      this.logError(`[maui] subwindow create failed: code=${error.code} message=${error.message}`);
      // Clean up a child created before a later step failed, so no empty frame is left behind.
      const leaked = this.subWindow;
      this.clearSubWindow();
      if (leaked !== null) {
        try {
          await leaked.destroyWindow();
        } catch (cleanupError) {
          this.logError(`[maui] subwindow cleanup failed: ${(cleanupError as Error).message}`);
        }
      }
      this.reportSubWindowFailure(error.code, error.message);
    } finally {
      this.subWindowCreating = false;
    }
  }

  private moveSubWindow(cmd: SubWindowCommand): void {
    const child = this.subWindow;
    if (child === null) {
      this.reportSubWindowFailure(-1, 'move: no subwindow exists');
      return;
    }
    const x = this.subWindowOffset(cmd.x, 0);
    const y = this.subWindowOffset(cmd.y, 0);
    child.moveWindowTo(x, y).then((): void => {
      this.logInfo(`[maui] subwindow move applied: ${x},${y}`);
      this.reportSubWindowState(SUB_EVENT_MOVED);
    }).catch((moveError: Error): void => {
      this.reportSubWindowFailure(-1, `move failed: ${moveError.message}`);
    });
  }

  private resizeSubWindow(cmd: SubWindowCommand): void {
    const child = this.subWindow;
    if (child === null) {
      this.reportSubWindowFailure(-1, 'resize: no subwindow exists');
      return;
    }
    const w = this.subWindowDimension(cmd.w, 640);
    const h = this.subWindowDimension(cmd.h, 420);
    child.resize(w, h).then((): void => {
      this.logInfo(`[maui] subwindow resize applied: ${w}x${h}`);
      this.reportSubWindowState(SUB_EVENT_RESIZED);
    }).catch((resizeError: Error): void => {
      this.reportSubWindowFailure(-1, `resize failed: ${resizeError.message}`);
    });
  }

  private showSubWindow(): void {
    const child = this.subWindow;
    if (child === null) {
      this.reportSubWindowFailure(-1, 'show: no subwindow exists');
      return;
    }
    child.showWindow().then((): void => {
      this.reportSubWindowState(SUB_EVENT_SHOWN);
    }).catch((showError: Error): void => {
      this.reportSubWindowFailure(-1, `show failed: ${showError.message}`);
    });
  }

  private closeSubWindow(): void {
    const child = this.subWindow;
    if (child === null) {
      // Idempotent close: a second close is a state no-op, not a failure.
      this.notifySubWindowEvent(SUB_EVENT_CLOSED, '{}');
      return;
    }
    // A device close logs one platform WARN "AceSubWindow ... Fail to get subwindow in
    // dialogSubwindowMap_" from AceContainer::DestroyContainer -> SubwindowManager::CloseDialog:
    // that runs for every destroyed container before the child's own destroy work, and an app
    // subwindow is never a dialogSubwindowMap_ entry. WMSLife shows a single "Destroy specific
    // session end" per close, so this is platform noise, not a shell double close.
    child.destroyWindow().then((): void => {
      // The windowEvent DESTROYED observer normally finishes the state; this is the belt for a
      // runtime that does not deliver it.
      if (this.subWindow === child) {
        this.finishSubWindowClosed();
      }
    }).catch((closeError: Error): void => {
      this.reportSubWindowFailure(-1, `close failed: ${closeError.message}`);
    });
  }

  // The child's own window events: shown/hidden are mirrored, destroyed finishes the state.
  private onSubWindowWindowEvent(evt: window.WindowEventType): void {
    if (evt === window.WindowEventType.WINDOW_SHOWN) {
      this.reportSubWindowState(SUB_EVENT_SHOWN);
    } else if (evt === window.WindowEventType.WINDOW_HIDDEN) {
      this.reportSubWindowState(SUB_EVENT_HIDDEN);
    } else if (evt === window.WindowEventType.WINDOW_DESTROYED) {
      this.finishSubWindowClosed();
    }
  }

  private finishSubWindowClosed(): void {
    if (this.subWindow === null) {
      return;
    }
    const id = this.subWindowId;
    this.clearSubWindow();
    const payload: SubWindowStatePayload = { id: id, x: 0, y: 0, w: 0, h: 0 };
    this.notifySubWindowEvent(SUB_EVENT_CLOSED, JSON.stringify(payload));
    this.logInfo('[maui] subwindow closed');
  }

  private clearSubWindow(): void {
    this.subWindow = null;
    this.subWindowId = -1;
    this.subWindowSuspended = false;
  }

  // Best-effort teardown when the page disappears; a failure only leaves the child for the
  // system to reap with the ability.
  private destroySubWindowForPage(): void {
    const child = this.subWindow;
    if (child === null) {
      return;
    }
    this.clearSubWindow();
    try {
      child.destroyWindow().catch((destroyError: Error): void => {
        this.logError(`[maui] subwindow page teardown failed: ${destroyError.message}`);
      });
    } catch (destroyError) {
      this.logError(`[maui] subwindow page teardown failed: ${(destroyError as Error).message}`);
    }
  }

  // Connectivity (Essentials): the NetworkKit connection observer pushes host.notifyNetworkAccess
  // (bare on netAvailable/netLost/netUnavailable, with the capped bearer-type encoding on
  // netCapabilitiesChange); the host re-reads the level through the same NDK path as
  // ohos_host_network_access, parses the encoding and hands both to the managed
  // OpenHarmonyConnectivity implementation (ConnectionProfiles). Device-compat: NetworkKit is
  // imported lazily; a missing kit is cached and only costs the change events (the managed
  // NetworkAccess property still reads the NDK path directly).
  private async subscribeNetworkChanges(): Promise<void> {
    if (this.networkObserverRegistered || this.lazyUnavailable('networkKit')) {
      return;
    }
    this.networkDisposed = false;
    try {
      const kit = await import('@kit.NetworkKit');
      try {
        const netConnection = kit.connection.createNetConnection();
        const availableHandler = (_handle: connection.NetHandle): void => {
          if (!this.networkDisposed) {
            this.reportNetworkAccess();
          }
        };
        const lostHandler = (_handle: connection.NetHandle): void => {
          if (!this.networkDisposed) {
            this.reportNetworkAccess();
          }
        };
        const capabilitiesHandler = (info: connection.NetCapabilityInfo): void => {
          if (!this.networkDisposed) {
            this.reportNetworkAccess(this.encodeBearerTypes(info));
          }
        };
        const unavailableHandler = (): void => {
          if (!this.networkDisposed) {
            this.reportNetworkAccess();
          }
        };
        netConnection.on('netAvailable', availableHandler);
        netConnection.on('netLost', lostHandler);
        netConnection.on('netCapabilitiesChange', capabilitiesHandler);
        netConnection.on('netUnavailable', unavailableHandler);
        this.trackDisposer((): void => {
          // API 26 declares on(...) without off(...): unregister(callback) is the declared
          // cancellation entry for the connection observer, and the disposed flag makes a late
          // callback a no-op even when the kit keeps delivering it (see the report note).
          this.networkDisposed = true;
          this.networkObserverRegistered = false;
          netConnection.unregister((unregisterError: BusinessError): void => {
            if (unregisterError) {
              this.logWarn(`network observer unregister failed: ${unregisterError.message}`);
            }
          });
        });
        this.networkObserverRegistered = true;
      } catch (networkObserverError) {
        this.noteLazyFailure('networkKit', networkObserverError as Error);
      }
    } catch (networkImportError) {
      this.noteLazyFailure('networkKit', networkImportError as Error);
    }
  }

  // Capped encoding of the transports a NetCapabilityInfo names: the NetBearType values
  // (0 cellular, 1 wifi, 2 bluetooth, 3 ethernet, 4 vpn), comma-separated, at most 8 entries /
  // 32 characters. The host parses it into the ohos_net_bearer mask behind
  // ohos_host_network_capabilities; an unknown/absent shape answers an empty string (no
  // bearers), which the host stores as "unknown" instead of guessing.
  private encodeBearerTypes(info: connection.NetCapabilityInfo): string {
    try {
      const bearers = info.netCap.bearerTypes;
      if (bearers === undefined || bearers === null) {
        return '';
      }
      let encoded: string = '';
      for (let i = 0; i < bearers.length && i < 8; i++) {
        const value: number = bearers[i] as number;
        if (value < 0 || value > 4) {
          continue;
        }
        if (encoded.length > 0) {
          encoded += ',';
        }
        encoded += value.toString();
        if (encoded.length >= 32) {
          break;
        }
      }
      return encoded;
    } catch (capabilitiesError) {
      this.logError(`[maui] network capabilities read failed: ${(capabilitiesError as Error).message}`);
      return '';
    }
  }

  // Forward one observed network change; the host reads the current level itself and stores the
  // bearer mask when the push carries one. The bare call stays for the events without a
  // NetCapabilityInfo (and for a host library that predates the capability argument).
  private reportNetworkAccess(capabilities?: string): void {
    this.hostCall('notifyNetworkAccess', typeof host !== 'undefined' && typeof host.notifyNetworkAccess === 'function', (): void => {
      if (capabilities !== undefined && capabilities.length > 0) {
        host.notifyNetworkAccess(capabilities);
      } else {
        host.notifyNetworkAccess();
      }
    });
  }

  // Safe area (soft input): the window's avoid-area change for the keyboard reports the
  // keyboard height; the host stores it for the managed SafeArea (SafeAreaEdges.SoftInput/All).
  // The system avoid-area report above is unaffected. Best effort: a missing Window API only
  // costs the soft-input inset, and the managed side keeps its zero default.
  private subscribeSoftInputArea(): void {
    window.getLastWindow(this.hostContext()).then((win) => {
      if (this.softInputRegistered) {
        return;
      }
      const listener = (data: window.AvoidAreaOptions): void => {
        if (data.type === window.AvoidAreaType.TYPE_KEYBOARD) {
          this.reportSoftInputArea(data.area.bottomRect.height);
        }
      };
      try {
        win.on('avoidAreaChange', listener);
        this.softInputWindow = win;
        this.softInputListener = listener;
        this.softInputRegistered = true;
      } catch (softInputError) {
        this.logError(`[maui] soft input observer unavailable: ${(softInputError as Error).message}`);
      }
    }).catch((softInputWindowError: Error): void => {
      this.logError(`[maui] soft input window unavailable: ${softInputWindowError.message}`);
    });
  }

  // Forwards the keyboard height (pixels, 0 when hidden). The host clamps negatives.
  private reportSoftInputArea(bottom: number): void {
    const height: number = bottom > 0 ? Math.floor(bottom) : 0;
    this.keyboardBottom = height;
    this.hostCall('notifySoftInputArea', typeof host !== 'undefined' && typeof host.notifySoftInputArea === 'function', (): void => {
      host.notifySoftInputArea(height);
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
      const context = this.hostContext();
      const permissions: Permissions[] = ['ohos.permission.READ_PASTEBOARD'];
      const atManager = abilityAccessCtrl.createAtManager();
      const granted = await atManager.requestPermissionsFromUser(context, permissions);
      this.clipboardReadGranted = granted.authResults.length > 0 && granted.authResults[0] === 0;
      this.clipboardReadDenied = !this.clipboardReadGranted;
      return this.clipboardReadGranted;
    } catch (clipboardPermissionError) {
      this.clipboardReadDenied = true;
      this.logError(`[maui] clipboard permission request failed: ${(clipboardPermissionError as Error).message}`);
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
    } catch {
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
    window.getLastWindow(this.hostContext()).then((win) => {
      return win.setWindowKeepScreenOn(on === 1);
    }).catch((keepScreenOnError: Error): void => {
      this.logError(`[maui] keep screen on failed: ${keepScreenOnError.message}`);
    });
  }

  // Window chrome: the managed title setter pushes through ohos_host_set_window_title. The
  // main window is resolved on demand (the same getLastWindow path the avoid-area report and
  // keep-screen-on use). setWindowTitle is a SessionManager API (15+), so a device without the
  // syscap rejects the promise; that is logged and leaves the shell title in place.
  private applyWindowTitle(title: string): void {
    this.logInfo(`[maui] window title applied: ${title}`);
    window.getLastWindow(this.hostContext()).then((win) => {
      return win.setWindowTitle(title);
    }).catch((windowTitleError: Error): void => {
      this.logError(`[maui] set window title failed: ${windowTitleError.message}`);
    });
  }

  // Window chrome: the managed rect setter pushes through ohos_host_set_window_rect; the
  // position and size are applied with moveWindowTo + resize (API 11+), both asynchronous.
  private applyWindowRect(x: number, y: number, w: number, h: number): void {
    window.getLastWindow(this.hostContext()).then((win) => {
      return win.moveWindowTo(x, y).then(() => {
        return win.resize(w, h);
      });
    }).catch((windowRectError: Error): void => {
      this.logError(`[maui] set window rect failed: ${windowRectError.message}`);
    });
  }

  // Window decorations (N6): ops pushed by the managed Window.TitleBar row - 0 minimize,
  // 1 maximize/restore toggle, 2 close, 3 start moving, 4 hide the shell decor (the app row
  // takes the caption over), 5 restore the shell decor. The window's own status decides the
  // toggle; every rejection is logged and leaves the window as it was. setWindowDecorVisible
  // throws synchronously on a runtime without the SessionManager syscap, which the sink gate
  // already filters out; the try/catch keeps a device change from breaking the page.
  private applyWindowDecor(win: window.Window, op: number): void {
    switch (op) {
      case 0:
        win.minimize().catch((decorError: Error): void => {
          this.logError(`[maui] window minimize failed: ${decorError.message}`);
        });
        break;
      case 1:
        if (win.getWindowStatus() === window.WindowStatusType.MAXIMIZE) {
          win.recover().catch((decorError: Error): void => {
            this.logError(`[maui] window restore failed: ${decorError.message}`);
          });
        } else {
          win.maximize().catch((decorError: Error): void => {
            this.logError(`[maui] window maximize failed: ${decorError.message}`);
          });
        }
        break;
      case 2:
        this.hostContext().terminateSelf().catch((decorError: Error): void => {
          this.logError(`[maui] window close failed: ${decorError.message}`);
        });
        break;
      case 3:
        win.startMoving().catch((decorError: Error): void => {
          this.logError(`[maui] window move failed: ${decorError.message}`);
        });
        break;
      case 4:
        try {
          win.setWindowDecorVisible(false);
        } catch (decorError) {
          this.logError(`[maui] hide window decor failed: ${(decorError as Error).message}`);
        }
        break;
      case 5:
        try {
          win.setWindowDecorVisible(true);
        } catch (decorError) {
          this.logError(`[maui] show window decor failed: ${(decorError as Error).message}`);
        }
        break;
      default:
        break;
    }
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
    const context = this.hostContext();
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
        if (fs.lstatSync(current).isSymbolicLink()) {
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
  // ohos_host_screenshot (PNG) or ohos_host_screenshot_format (format 0 = PNG, 1 = JPEG, plus
  // the JPEG quality); the shell snapshots the main window and writes the requested format with
  // the image packer. The output path must resolve under the app temp/cache dirs (see
  // canonicalScreenshotPath). The image packer is imported lazily (device-compat), and the
  // packer, the file descriptor and the pixel map are released on every path. Returns 0 when the
  // image was written, -1 otherwise.
  private async captureScreenshot(outPath: string, format?: number, quality?: number): Promise<number> {
    let safePath: string | null = null;
    try {
      safePath = this.canonicalScreenshotPath(outPath);
    } catch (pathError) {
      this.logError(`[maui] screenshot path check failed: ${(pathError as Error).message}`);
      return -1;
    }
    if (safePath === null) {
      this.logError('[maui] screenshot rejected: output path is not under the app temp/cache dir');
      return -1;
    }
    if (this.lazyUnavailable('imagePacker')) {
      return -1;
    }
    const imageFormat: string = format === 1 ? 'image/jpeg' : 'image/png';
    const imageQuality: number = typeof quality === 'number' && quality >= 0 && quality <= 100
      ? quality : 100;
    try {
      const image = await import('@kit.ImageKit');
      try {
        const win = await window.getLastWindow(this.hostContext());
        const pixelMap = await win.snapshot();
        const packer = image.image.createImagePacker();
        const file = fs.openSync(safePath, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE
          | fs.OpenMode.TRUNC);
        try {
          await packer.packToFile(pixelMap, file.fd, { format: imageFormat, quality: imageQuality });
          return 0;
        } finally {
          fs.closeSync(file);
          await packer.release();
          await pixelMap.release();
        }
      } catch (screenshotError) {
        this.logError(`[maui] screenshot failed: ${(screenshotError as Error).message}`);
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
  // getAddressesFromLocation. The entry probe isGeocoderAvailable() runs before any query and
  // the kit error codes map to distinct rc values (see geocodeErrorRc); every failure answers an
  // empty JSON with a non-zero rc so the managed caller degrades without throwing.
  private async runGeocode(requestId: number, op: number, arg: string): Promise<void> {
    let rc: number = -1;
    let json: string = '';
    if (this.lazyUnavailable('geoLocationManager')) {
      this.answerGeocode(requestId, rc, json);
      return;
    }
    try {
      const geo = await import('@kit.LocationKit');
      // Geocoder entry probe (audit ARKTS-S2): a device without the geocoding syscap answers
      // before any query (isGeocoderAvailable throws 801 on unsupported devices). The reverse
      // lookup additionally reads the device location (user_grant), so its permission is
      // pre-checked instead of failing inside the kit call.
      let available: boolean = false;
      try {
        available = geo.geoLocationManager.isGeocoderAvailable();
      } catch (geocoderProbeError) {
        rc = this.geocodeErrorRc(geocoderProbeError as BusinessError);
      }
      if (!available) {
        this.answerGeocode(requestId, rc, json);
        return;
      }
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
          const addresses = await geo.geoLocationManager.getAddressesFromLocationName(request);
          json = JSON.stringify(addresses);
          rc = 0;
        }
      } else if (op === 1) {
        const parts: string[] = arg.split(',');
        const latitude: number = parts.length > 0 ? Number.parseFloat(parts[0]) : Number.NaN;
        const longitude: number = parts.length > 1 ? Number.parseFloat(parts[1]) : Number.NaN;
        if (!Number.isFinite(latitude) || !Number.isFinite(longitude)) {
          this.answerGeocode(requestId, rc, json);
          return;
        }
        if (!(await this.ensureLocationPermission())) {
          // Permission denied: the feature answers unavailable (rc -1), never throws.
          this.answerGeocode(requestId, rc, json);
          return;
        }
        const request: geoLocationManager.ReverseGeoCodeRequest = {
          latitude: latitude,
          longitude: longitude
        };
        const addresses = await geo.geoLocationManager.getAddressesFromLocation(request);
        json = JSON.stringify(addresses);
        rc = 0;
      }
    } catch (geocodeError) {
      rc = this.geocodeErrorRc(geocodeError as BusinessError);
      this.logError(`[maui] geocode op ${op} failed: ${(geocodeError as Error).message}`);
    }
    this.answerGeocode(requestId, rc, json);
  }

  // Location Kit geocoding error mapping (audit ARKTS-S2): 3301000 (location service
  // unavailable) and 801 (no geocoding syscap) answer -1, the managed side's "no result" code;
  // 3301300 (reverse geocoding query failed) and 3301400 (geocoding query failed) answer -2,
  // the query-failure code. Every other code keeps -1.
  private geocodeErrorRc(error: BusinessError): number {
    const code: number = error?.code ?? 0;
    if (code === 3301300 || code === 3301400) {
      return -2;
    }
    return -1;
  }

  // Geocoding (Essentials): completes the pending managed request through host.geocodeResult.
  private answerGeocode(requestId: number, rc: number, json: string): void {
    this.hostCall('geocodeResult', typeof host !== 'undefined' && typeof host.geocodeResult === 'function', (): void => {
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
      const context = this.hostContext();
      const permissions: Permissions[] = ['ohos.permission.APPROXIMATELY_LOCATION'];
      const atManager = abilityAccessCtrl.createAtManager();
      const granted = await atManager.requestPermissionsFromUser(context, permissions);
      this.locationGranted = granted.authResults.length > 0 && granted.authResults[0] === 0;
    } catch (locationPermissionError) {
      this.logError(`[maui] location permission request failed: ${(locationPermissionError as Error).message}`);
    }
    return this.locationGranted;
  }

  // Reads the host's current menu table into @State (empty when the sink is unavailable).
  private pullMenu(): void {
    if (typeof host === 'undefined' || typeof host.menuCount !== 'function' ||
        typeof host.menuItem !== 'function') {
      this.menuItems = [];
      this.reportHostUnavailable('menuCount', undefined);
      return;
    }
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
  // greys out disabled rows and does not run their action. This is the legacy rendering for a
  // host library that predates the structured table (T16).
  private buildMenuElements(): MenuElement[] {
    const elements: MenuElement[] = [];
    for (let i = 0; i < this.menuItems.length; i++) {
      const index: number = i;
      const item: HostMenuItem = this.menuItems[i];
      const element: MenuElement = {
        value: item.text,
        enabled: item.enabled,
        action: (): void => {
          this.hostCall('notifyMenuAction', typeof host !== 'undefined' && typeof host.notifyMenuAction === 'function', (): void => {
            host.notifyMenuAction(index);
          });
        }
      };
      elements.push(element);
    }
    return elements;
  }

  // True when the pulled table carries the structured rows (T16): the managed publisher emits a
  // bar title first, so a non-empty table whose first row is a bar row is structured. A legacy
  // host returns rows without kind/level, and the shell keeps the flat element rendering.
  private hasStructuredMenu(): boolean {
    return this.menuItems.length > 0 && this.menuItems[0].kind === 2;
  }

  // The row's nesting level; a legacy row (no level) is a top-level item of its menu.
  private menuLevel(row: HostMenuItem): number {
    return row.level !== undefined ? row.level : 1;
  }

  // The direct children of the row at `index`: the following rows with the next level, up to
  // the first row that closes the menu (a level <= the parent's). A bar row's direct children
  // are the bar's top-level items; a submenu header's are the items it opens.
  private childMenuRows(index: number): HostMenuRowRef[] {
    const children: HostMenuRowRef[] = [];
    if (index < 0 || index >= this.menuItems.length) {
      return children;
    }
    const parentLevel: number = this.menuLevel(this.menuItems[index]);
    for (let i = index + 1; i < this.menuItems.length; i++) {
      const row: HostMenuItem = this.menuItems[i];
      const level: number = this.menuLevel(row);
      if (level <= parentLevel) {
        break;
      }
      if (level === parentLevel + 1) {
        children.push({ row: row, index: i });
      }
    }
    return children;
  }

  // Sends a leaf row's index back to the managed activation route (host.notifyMenuAction).
  private activateMenuRow(index: number): void {
    this.hostCall('notifyMenuAction', typeof host !== 'undefined' && typeof host.notifyMenuAction === 'function', (): void => {
      host.notifyMenuAction(index);
    });
  }

  // One row of a submenu: a nested submenu header opens its own children (recursively), a leaf
  // sends its index back. The Menu the builder renders is the submenu body.
  @Builder
  subMenuRows(index: number): void {
    Menu() {
      ForEach(this.childMenuRows(index), (entry: HostMenuRowRef) => {
        if (entry.row.kind === 1) {
          MenuItem({ content: entry.row.text, builder: (): void => { this.subMenuRows(entry.index) } })
            .enabled(entry.row.enabled)
        } else {
          MenuItem({ content: entry.row.text })
            .enabled(entry.row.enabled)
            .onClick((): void => { this.activateMenuRow(entry.index) })
        }
      }, (entry: HostMenuRowRef): string => `${entry.index}`)
    }
  }

  // The structured menu (T16): one MenuItemGroup per MenuBarItem (its title is the group
  // header) with the bar's top-level rows; a submenu header renders as a MenuItem that opens
  // its children as a nested menu.
  @Builder
  structuredMenu(): void {
    Menu() {
      ForEach(this.menuItems, (bar: HostMenuItem, barIndex: number) => {
        if (bar.kind === 2) {
          MenuItemGroup({ header: bar.text }) {
            ForEach(this.childMenuRows(barIndex), (entry: HostMenuRowRef) => {
              if (entry.row.kind === 1) {
                MenuItem({ content: entry.row.text, builder: (): void => { this.subMenuRows(entry.index) } })
                  .enabled(entry.row.enabled)
              } else {
                MenuItem({ content: entry.row.text })
                  .enabled(entry.row.enabled)
                  .onClick((): void => { this.activateMenuRow(entry.index) })
              }
            }, (entry: HostMenuRowRef): string => `${entry.index}`)
          }
        }
      }, (bar: HostMenuItem, barIndex: number): string => `${barIndex}`)
    }
  }

  // JavaScript bridge: registers the dotnetHost proxy that page scripts call to reach the
  // managed side. registerJavaScriptProxy needs the controller attached to the Web component
  // (BusinessError 17100001 otherwise), so onControllerAttached calls this.
  private registerDotNetHost(slot: number): void {
    if (this.dotNetHostRegistered[slot]) {
      return;
    }
    try {
      this.slotController(slot).registerJavaScriptProxy({
        postMessage: (payload: string): void => {
          // ArkWeb registers the proxy into every frame, but the managed side trusts the
          // __OHORIGIN envelope built below. Drop the call when the calling frame url is a
          // known non-empty url that is not the main document's; empty/unknown values fail
          // open and the returned url's exact device semantics still need validation.
          let callerUrl: string = '';
          try {
            if (typeof this.slotController(slot).getLastJavascriptProxyCallingFrameUrl === 'function') {
              callerUrl = this.slotController(slot).getLastJavascriptProxyCallingFrameUrl();
            }
          } catch {
            callerUrl = '';
          }
          if (typeof callerUrl === 'string' && callerUrl.length > 0) {
            let mainUrl: string = '';
            try {
              mainUrl = this.slotController(slot).getUrl();
            } catch {
              mainUrl = '';
            }
            if (callerUrl !== mainUrl) {
              return;
            }
          }
          this.hostCall('notifyJsMessage', typeof host !== 'undefined' && typeof host.notifyJsMessage === 'function', (): void => {
            host.notifyJsMessage(this.originEnvelope(payload, slot));
          });
        }
      }, 'dotnetHost', ['postMessage']);
      this.dotNetHostRegistered[slot] = true;
    } catch (proxyError) {
      this.logError(`[maui] dotnetHost proxy registration failed (slot ${slot}): ${(proxyError as Error).message}`);
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
  private originEnvelope(payload: string, slot: number): string {
    let url: string = '';
    try {
      url = this.slotController(slot).getUrl();
    } catch {
      url = '';
    }
    let documentId: string = '';
    if (this.hybridRegistered[slot] && this.hybridDocId[slot].length > 0 && url.startsWith(this.hybridOrigin)) {
      documentId = this.hybridDocId[slot];
    } else if (this.blazorRegistered && this.blazorDocId.length > 0 && url.startsWith(this.blazorOrigin)) {
      documentId = this.blazorDocId;
    }
    return `__OHORIGIN|${url}|${documentId}\n${payload}`;
  }

  // B6: true for the URLs that belong to the app's own content - the hybrid/Blazor app
  // origins, local files, inline/in-page documents and relative references - which keep
  // loading exactly as before (no managed round trip).
  private isAppNavigation(url: string): boolean {
    if (url.length === 0) {
      return true;
    }
    // H-C2: reject protocol-relative and backslash network-path references ("//host",
    // "/\host", "\\host", ...) before the '/' fast path below. A URL parser resolves them
    // against another authority (WHATWG: "//evil.invalid/x" -> "https://evil.invalid/x"),
    // so they must never count as app-local content; returning false hands the load to the
    // managed handler, exactly like any other external URL. Leading whitespace/control
    // characters are skipped first so " //host", "\t//host" and "\u0001//host" cannot dodge
    // the check. Plain same-origin paths ("/page", "#frag", "?q") keep the fast path.
    let lead: number = 0;
    while (lead < url.length) {
      const code: number = url.charCodeAt(lead);
      if (code <= 0x20 || code === 0x7f) {
        lead++;
      } else {
        break;
      }
    }
    if (lead + 1 < url.length) {
      const first: string = url.charAt(lead);
      const second: string = url.charAt(lead + 1);
      if ((first === '/' || first === '\\') && (second === '/' || second === '\\')) {
        return false;
      }
    }
    if (url.charAt(0) === '/' || url.charAt(0) === '#' || url.charAt(0) === '?') {
      return true;
    }
    if (url.startsWith('about:') || url.startsWith('data:') || url.startsWith('blob:') ||
        url.startsWith('javascript:') || url.startsWith('file:')) {
      return true;
    }
    if (this.anyHybridRegistered()) {
      if (url.startsWith(this.hybridOrigin)) {
        return true;
      }
    }
    if (this.blazorRegistered && url.startsWith(this.blazorOrigin)) {
      return true;
    }
    return false;
  }

  // MULTI-OVL slot helpers. A tagged per-overlay argument starts with "s0"/"s1", optionally
  // followed by '\n' and the payload; an untagged argument lands on slot 0 (legacy handler or
  // a global command). The tag is the wire contract the managed handlers build in
  // OpenHarmonyOverlays.Tag/TagScript and parse back from the event states.
  // SLOTS-DYNAMIC: a tag is valid for any declared slot below WEB_SLOT_MAX ("s0".."s3"); the
  // digit-only form keeps the wire protocol unchanged.
  private webSlotDigit(arg: string): number {
    if (arg.length >= 2 && arg.charAt(0) === 's') {
      const slot: number = arg.charCodeAt(1) - 48;
      if (slot >= 0 && slot < WEB_SLOT_MAX && (arg.length === 2 || arg.charAt(2) === '\n')) {
        return slot;
      }
    }
    return -1;
  }

  private webSlotOf(arg: string): number {
    const slot: number = this.webSlotDigit(arg);
    return slot >= 0 ? slot : 0;
  }

  // True when the argument carries an explicit slot tag. `webSlotOf` answers 0 for an untagged
  // argument as the legacy default, so operations whose untagged form means "every overlay"
  // (hide) need this stronger test to tell "s0" from no tag at all.
  private webSlotTagged(arg: string): boolean {
    return this.webSlotDigit(arg) >= 0;
  }

  // MULTI-OVERLAY-FULL z-order: marks the overlay as most recently activated and forwards the
  // user-touch form to the managed side, where the LRU pool refreshes that slot's owner.
  private noteWebActivation(slot: number): void {
    this.webZOrderSeq++;
    this.webZOrder[slot] = this.webZOrderSeq;
  }

  private forwardWebActivation(slot: number): void {
    this.hostCall('notifyWebEvent', typeof host !== 'undefined' && typeof host.notifyWebEvent === 'function', (): void => {
      host.notifyWebEvent(this.webEventState(slot, 'activate'), '');
    });
  }

  private webSlotPayload(arg: string): string {
    const slot: number = this.webSlotDigit(arg);
    return slot >= 0 && arg.length > 2 ? arg.substring(3) : arg;
  }

  // MULTI-OVL: the page-event state carries the slot ("s0|finished"), so the managed side routes
  // the event to the handler that owns the overlay.
  private webEventState(slot: number, state: string): string {
    return `s${slot}|${state}`;
  }

  private slotController(slot: number): web_webview.WebviewController {
    let controller: web_webview.WebviewController | null = this.webControllers[slot];
    if (controller === null) {
      // A dynamic controller is normally created by ensureWebSlot; this is the defensive path
      // for a caller that reached the controller first.
      controller = new web_webview.WebviewController();
      this.webControllers[slot] = controller;
    }
    return controller;
  }

  // ---------------------------------------------------------------------------------------------
  // SLOTS-DYNAMIC: overlay slot lifecycle. Slots 0..WEB_SLOT_HOT-1 are the always-declared hot
  // pair; a slot at/above the floor is declared on demand (the managed pool's "slot ensure"
  // command, or the first tagged command for the slot) and removed by "slot destroy" when the
  // pool releases it. Commands for a slot whose Web component has not attached yet are queued
  // and replayed from onControllerAttached, so the asynchronous ArkUI create cannot lose them.
  // ---------------------------------------------------------------------------------------------

  // Sends the shell's overlay capacity to the managed pool ("capacity" page event). The page can
  // load before the managed WebEvent subscription exists, so aboutToAppear sends it with a
  // couple of bounded retries; a lost notification only delays the pool's clamp (its default is
  // the same WEB_SLOT_MAX).
  private advertiseWebCapacity(): void {
    this.hostCall('notifyWebEvent', typeof host !== 'undefined' && typeof host.notifyWebEvent === 'function', (): void => {
      host.notifyWebEvent('capacity', `${WEB_SLOT_MAX}`);
    });
  }

  private ensureWebSlot(slot: number): void {
    if (slot < 0 || slot >= WEB_SLOT_MAX) {
      this.logError(`[maui] web slot ensure rejected: ${slot}`);
      return;
    }
    if (!this.webOverlaysMounted) {
      this.webOverlaysMounted = true;
      this.logInfo('[maui] web overlays mounted on first use');
    }
    if (this.webSlotCreated[slot]) {
      return;
    }
    this.webSlotCreated[slot] = true;
    if (this.webControllers[slot] === null) {
      this.webControllers[slot] = new web_webview.WebviewController();
    }
    this.rebuildWebSlots(slot, -1);
    this.logInfo(`[maui] web slot create: ${slot}`);
  }

  private destroyWebSlot(slot: number): void {
    if (slot < WEB_SLOT_HOT || slot >= WEB_SLOT_MAX) {
      // The hot pair is never destroyed (the pool's HotOverlays floor), and an out-of-range
      // request is a protocol error.
      this.logError(`[maui] web slot destroy rejected: ${slot}`);
      return;
    }
    if (!this.webSlotCreated[slot]) {
      return;
    }
    this.webSlotCreated[slot] = false;
    this.webSlotAttached[slot] = false;
    try {
      const controller: web_webview.WebviewController | null = this.webControllers[slot];
      if (controller !== null) {
        controller.stop();
      }
    } catch {
      // Stopping a controller that has no active load must not fail the removal.
    }
    this.webControllers[slot] = null;
    this.rebuildWebSlots(-1, slot);
    this.resetWebSlotState(slot);
    this.pendingWebOps.delete(slot);
    this.logInfo(`[maui] web slot destroy: ${slot}`);
  }

  // Rebuilds the declared-slot list (a fresh array so @State reacts): removes `removeSlot` when
  // it is >= 0 and appends `addSlot` when it is >= 0, keeping the ascending order the hot pair
  // starts with (the ArkUI declaration order is cosmetic; z-order decides overlap).
  private rebuildWebSlots(addSlot: number, removeSlot: number): void {
    const next: number[] = [];
    for (let i = 0; i < this.webSlots.length; i++) {
      const current: number = this.webSlots[i];
      if (current !== removeSlot) {
        next.push(current);
      }
    }
    if (addSlot >= 0) {
      let inserted: boolean = false;
      for (let i = 0; i < next.length; i++) {
        if (next[i] > addSlot) {
          next.splice(i, 0, addSlot);
          inserted = true;
          break;
        }
      }
      if (!inserted) {
        next.push(addSlot);
      }
    }
    this.webSlots = next;
  }

  // Clears every per-slot table entry so a re-created slot cannot inherit the previous owner's
  // registration/visibility/history state.
  private resetWebSlotState(slot: number): void {
    this.webVisible[slot] = false;
    this.webZOrder[slot] = 0;
    this.webVisibleBeforeSuspend[slot] = false;
    this.webFrameX[slot] = 0;
    this.webFrameY[slot] = 0;
    this.webFrameW[slot] = 0;
    this.webFrameH[slot] = 0;
    this.hybridBase[slot] = '';
    this.hybridRoot[slot] = '';
    this.hybridDefaultFile[slot] = '';
    this.hybridRegistered[slot] = false;
    this.hybridDocId[slot] = '';
    this.hybridServeLogs[slot] = 0;
    this.blazorBootstrapped[slot] = false;
    this.dotNetHostRegistered[slot] = false;
    this.navProgrammatic[slot] = null;
    this.navApproved[slot] = null;
  }

  // True when the slot's ArkWeb exists and its controller is attached, i.e. a controller call
  // cannot fail with BusinessError 17100001.
  private webSlotReady(slot: number): boolean {
    return slot >= 0 && slot < WEB_SLOT_MAX && this.webSlotCreated[slot] && this.webSlotAttached[slot];
  }

  private deferWebOp(slot: number, op: string, arg: string, requestId: number = -1): void {
    if (slot < 0 || slot >= WEB_SLOT_MAX) {
      this.logError(`[maui] web slot defer rejected: ${slot} ${op}`);
      return;
    }
    let pending: WebPendingOp[] | undefined = this.pendingWebOps.get(slot);
    if (pending === undefined) {
      pending = [];
      this.pendingWebOps.set(slot, pending);
    }
    if (pending.length >= WEB_SLOT_PENDING_MAX) {
      this.logError(`[maui] web slot defer overflow: ${slot} ${op}`);
      return;
    }
    pending.push({ op: op, arg: arg, requestId: requestId });
    this.logInfo(`[maui] web slot defer: ${slot} ${op}`);
    this.ensureWebSlot(slot);
  }

  private flushWebOps(slot: number): void {
    const pending: WebPendingOp[] | undefined = this.pendingWebOps.get(slot);
    if (pending === undefined || pending.length === 0) {
      return;
    }
    this.pendingWebOps.delete(slot);
    for (const item of pending) {
      if (item.op === 'eval') {
        this.runWebEval(item.arg, item.requestId);
      } else {
        this.runWebCommand(item.op, item.arg);
      }
    }
  }

  // True when any hybrid slot is registered; the navigation fast path needs this instead of the
  // fixed slot-0/slot-1 tests of the two-overlay shell.
  private anyHybridRegistered(): boolean {
    for (let slot = 0; slot < WEB_SLOT_MAX; slot++) {
      if (this.hybridRegistered[slot]) {
        return true;
      }
    }
    return false;
  }

  // Slot named by a hybrid/blazor registration JSON ("slot"); absent or out of range keeps the
  // legacy first overlay.
  private registrationSlot(arg: string): number {
    try {
      const config = JSON.parse(arg) as HybridAssetsConfig;
      if (config.slot !== undefined && config.slot >= 0 && config.slot < WEB_SLOT_MAX) {
        return config.slot;
      }
    } catch {
      // A malformed registration falls back to slot 0 and is rejected by its own parser.
    }
    return 0;
  }

  // SLOTS-DYNAMIC: applies one shell web command. Per-overlay commands whose slot's ArkWeb has
  // not attached yet are deferred (deferWebOp) and replayed from onControllerAttached; the
  // untagged global commands keep their all-overlays/untagged meaning.
  private runWebCommand(op: string, arg: string): void {
    if (op === 'slot') {
      // SLOTS-DYNAMIC slot lifecycle from the managed pool: "ensure\n<slot>" declares the
      // ArkWeb, "destroy\n<slot>" removes it (only slots >= WEB_SLOT_HOT).
      this.applySlotCommand(arg);
      return;
    }
    if (op === 'hide' && !this.webSlotTagged(arg)) {
      // FIX-WVP tab switch: hide every overlay; the hidden page is not arranged, so no stale
      // frame re-shows it, and the next page's web control re-shows through its own frame. A
      // slot-tagged hide (below) clears only that overlay (the managed error handler).
      this.webVisible = [false, false, false, false];
      return;
    }
    if (op === 'suspend') {
      // FIX-WVP drawer presented: hide every overlay and keep frame/load commands from
      // re-showing them (the flyout's own arrange cycle re-emits the detail's web frames).
      if (!this.webSuspended) {
        this.webVisibleBeforeSuspend = [this.webVisible[0], this.webVisible[1], this.webVisible[2], this.webVisible[3]];
        this.webSuspended = true;
      }
      this.webVisible = [false, false, false, false];
      return;
    }
    if (op === 'resume') {
      // FIX-WVP drawer dismissed: restore the visibility the suspend remembered.
      this.webSuspended = false;
      this.webVisible = [this.webVisibleBeforeSuspend[0], this.webVisibleBeforeSuspend[1],
        this.webVisibleBeforeSuspend[2], this.webVisibleBeforeSuspend[3]];
      return;
    }
    if (op === 'cookie') {
      // Minimal cookie surface: "<url>\n<Set-Cookie header>". Only absolute http(s) URLs are
      // accepted; the managed side validates its half too.
      const cookieSeparator: number = arg.indexOf('\n');
      if (cookieSeparator > 0) {
        const cookieUrl: string = arg.substring(0, cookieSeparator);
        const cookieValue: string = arg.substring(cookieSeparator + 1);
        if ((cookieUrl.startsWith('http://') || cookieUrl.startsWith('https://')) &&
            cookieValue.length > 0 && cookieValue.length <= 8192) {
          web_webview.WebCookieManager.configCookieSync(cookieUrl, cookieValue);
        }
      }
      return;
    }
    if (op === 'cookieGet') {
      // Minimal cookie read: "<requestId>\n<url>"; the value travels back through the
      // eval-result channel (host.notifyWebEvalResult) keyed by the request id.
      const getSeparator: number = arg.indexOf('\n');
      const requestId: number = getSeparator > 0 ? Number.parseInt(arg.substring(0, getSeparator), 10) : -1;
      const cookieUrl: string = getSeparator > 0 ? arg.substring(getSeparator + 1) : '';
      let cookieValue: string = '';
      let cookieFailed: number = 0;
      try {
        if ((!cookieUrl.startsWith('http://') && !cookieUrl.startsWith('https://')) ||
            !Number.isFinite(requestId) || requestId < 0 || Math.floor(requestId) !== requestId) {
          cookieFailed = 1;
        } else {
          cookieValue = web_webview.WebCookieManager.fetchCookieSync(cookieUrl);
        }
      } catch {
        cookieFailed = 1;
      }
      this.hostCall('notifyWebEvalResult', typeof host !== 'undefined' && typeof host.notifyWebEvalResult === 'function', (): void => {
        host.notifyWebEvalResult(requestId, cookieValue, cookieFailed);
      });
      return;
    }
    // Per-overlay command: the slot comes from the registration JSON for hybrid/blazor and from
    // the "s<slot>" first line otherwise. A command for a not-yet-attached overlay is deferred
    // and replayed when its Web component attaches.
    const commandSlot: number = op === 'hybrid' || op === 'blazor' ? this.registrationSlot(arg) : this.webSlotOf(arg);
    if (!this.webSlotReady(commandSlot)) {
      this.deferWebOp(commandSlot, op, arg);
      return;
    }
    if (op === 'show') {
      // Historical: show one overlay (a WebView without a Source), tagged with its slot. A
      // suspended overlay stays hidden under a presented drawer.
      this.webVisible[commandSlot] = !this.webSuspended;
      this.noteWebActivation(commandSlot);
    } else if (op === 'hide') {
      this.webVisible[commandSlot] = false;
    } else if (op === 'load') {
      const loadUrl: string = this.webSlotPayload(arg);
      this.webVisible[commandSlot] = !this.webSuspended;
      this.noteWebActivation(commandSlot);
      // B6: the app asked for this URL; let this one load through without a round trip.
      this.navProgrammatic[commandSlot] = { url: loadUrl, expires: Date.now() + this.navPendingTtlMs };
      this.slotController(commandSlot).loadUrl(loadUrl);
      this.logInfo(`[maui] web load (slot ${commandSlot}): ${loadUrl}`);
    } else if (op === 'nav') {
      // B6: the managed handler's answer to an intercepted navigation (slot-tagged).
      this.approveNavigation(arg);
    } else if (op === 'data') {
      this.webVisible[commandSlot] = !this.webSuspended;
      this.noteWebActivation(commandSlot);
      this.slotController(commandSlot).loadData(this.webSlotPayload(arg), 'text/html', 'UTF-8');
    } else if (op === 'back') {
      const backController: web_webview.WebviewController = this.slotController(commandSlot);
      if (backController.accessBackward()) {
        backController.backward();
      }
      this.reportWebHistory(commandSlot);
    } else if (op === 'forward') {
      const forwardController: web_webview.WebviewController = this.slotController(commandSlot);
      if (forwardController.accessForward()) {
        forwardController.forward();
      }
      this.reportWebHistory(commandSlot);
    } else if (op === 'refresh') {
      this.slotController(commandSlot).refresh();
      this.reportWebHistory(commandSlot);
    } else if (op === 'frame') {
      // WebView PlatformArrange: "s<slot>\nx\ny\nw\nh" (vp); also shows that overlay.
      this.applyWebFrame(arg);
    } else if (op === 'hybrid') {
      // HybridWebView asset root registration from the managed handler.
      this.registerHybridAssets(arg);
    } else if (op === 'blazor') {
      // BlazorWebView asset root registration from the managed handler (milestone 3).
      this.registerBlazorAssets(arg);
    }
  }

  // SLOTS-DYNAMIC: "ensure\n<slot>" / "destroy\n<slot>" from the managed pool. A malformed or
  // out-of-range request is rejected with one bounded log instead of touching the tables.
  private applySlotCommand(arg: string): void {
    const separator: number = arg.indexOf('\n');
    const action: string = separator > 0 ? arg.substring(0, separator) : arg;
    const slot: number = separator > 0 ? Number.parseInt(arg.substring(separator + 1), 10) : -1;
    if (!Number.isFinite(slot) || Math.floor(slot) !== slot || slot < 0 || slot >= WEB_SLOT_MAX) {
      this.logError(`[maui] web slot command rejected: ${action}`);
      return;
    }
    if (action === 'ensure') {
      this.ensureWebSlot(slot);
    } else if (action === 'destroy') {
      this.destroyWebSlot(slot);
    } else {
      this.logError(`[maui] web slot command unknown: ${action}`);
    }
  }

  // Runs one registerWebEvalSink script on its slot's controller and answers the request id.
  // Shared by the inline sink and the SLOTS-DYNAMIC deferral replay.
  private runWebEval(script: string, requestId: number): void {
    const slot: number = this.webSlotOf(script);
    this.slotController(slot).runJavaScript(this.webSlotPayload(script), (err, result) => {
      this.hostCall('notifyWebEvalResult', typeof host !== 'undefined' && typeof host.notifyWebEvalResult === 'function', (): void => {
        host.notifyWebEvalResult(requestId, result || '', err ? 1 : 0);
      });
    });
  }

  // B6: consumes a one-shot marker for a load the shell itself requested (WebCommand "load")
  // or one the managed handler approved. The marker lets exactly that reload pass
  // onLoadIntercept without another managed round trip (loop guard); expired markers are stale.
  private consumeApprovedNavigation(url: string, slot: number): boolean {
    const now: number = Date.now();
    const programmatic: ApprovedNavigation | null = this.navProgrammatic[slot];
    if (programmatic !== null && programmatic.expires >= now && programmatic.url === url) {
      this.navProgrammatic[slot] = null;
      return true;
    }
    const approved: ApprovedNavigation | null = this.navApproved[slot];
    if (approved !== null && approved.expires >= now && approved.url === url) {
      this.navApproved[slot] = null;
      return true;
    }
    return false;
  }

  // B6: retires a marker once the approved/app-requested load actually started, so a later
  // page-initiated navigation to the same URL is asked about again.
  private retireNavigationMarker(url: string, slot: number): void {
    const programmatic: ApprovedNavigation | null = this.navProgrammatic[slot];
    if (programmatic !== null && programmatic.url === url) {
      this.navProgrammatic[slot] = null;
    }
    const approved: ApprovedNavigation | null = this.navApproved[slot];
    if (approved !== null && approved.url === url) {
      this.navApproved[slot] = null;
    }
  }

  // B6: asks the managed handler for a Navigating decision on a cancelled main-frame load.
  // The URL stays with the shell (the managed side only sees it to decide); the id is
  // unguessable and short-lived, the pending table is bounded, and the oldest entry is
  // dropped when it is full. MULTI-OVL: the cancelled overlay's slot travels in the envelope
  // ("__OHNAV|s<slot>|<url>|<id>") and the managed answer echoes it.
  private askManagedAboutNavigation(slot: number, url: string): void {
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
    } catch {
      id = `${now.toString(16)}-${Math.random().toString(16).substring(2)}`;
    }
    this.navPending.set(id, { url: url, expires: now + this.navPendingTtlMs, slot: slot });
    const delivered: boolean = this.hostCall('notifyJsMessage', typeof host !== 'undefined' && typeof host.notifyJsMessage === 'function', (): void => {
      host.notifyJsMessage(`__OHNAV|s${slot}|${url}|${id}`);
    });
    if (!delivered) {
      // No host channel: nothing can approve the load, so it stays cancelled.
      this.navPending.delete(id);
    }
  }

  // B6: the managed handler answers an intercepted navigation (WebCommand op "nav"); the
  // MULTI-OVL argument is "s<slot>\n<id>\n<url>" (legacy "<id>\n<url>"). The URL must be the
  // exact one the shell cancelled for that id on that slot, and the approval is one-shot: only
  // the reload that follows may pass.
  private approveNavigation(arg: string): void {
    const slot: number = this.webSlotOf(arg);
    const tagged: string = this.webSlotPayload(arg);
    const separator: number = tagged.indexOf('\n');
    const id: string = separator >= 0 ? tagged.substring(0, separator) : tagged;
    const url: string = separator >= 0 ? tagged.substring(separator + 1) : '';
    const pending: PendingNavigation | undefined = this.navPending.get(id);
    if (pending === undefined) {
      return;
    }
    this.navPending.delete(id);
    if (pending.expires < Date.now() || pending.url !== url || pending.slot !== slot) {
      return;
    }
    this.navApproved[slot] = { url: pending.url, expires: Date.now() + this.navPendingTtlMs };
    try {
      this.slotController(slot).loadUrl(pending.url);
    } catch {
      // The reload failed (e.g., the controller detached); the navigation stays cancelled.
    }
  }

  // WebView history: after every page end, back/forward/refresh the shell reports whether the
  // ArkWeb can still navigate back/forward; the managed WebView mirrors it into
  // IWebView.CanGoBack/CanGoForward ("s<slot>|history|<back>|<forward>" on the web event channel).
  private reportWebHistory(slot: number): void {
    let canBack: boolean = false;
    let canForward: boolean = false;
    try {
      const controller: web_webview.WebviewController = this.slotController(slot);
      canBack = controller.accessBackward();
      canForward = controller.accessForward();
    } catch {
      return;
    }
    this.hostCall('notifyWebEvent', typeof host !== 'undefined' && typeof host.notifyWebEvent === 'function', (): void => {
      host.notifyWebEvent(this.webEventState(slot, `history|${canBack ? 1 : 0}|${canForward ? 1 : 0}`), '');
    });
  }

  // WebView frame: the managed PlatformArrange sends "s<slot>\nx\ny\nw\nh" (legacy "x\ny\nw\nh",
  // slot 0). The managed compositor draws in device pixels
  // (OpenHarmonyWindowHandler.RequestDisplayDensity answers 1), so the frame values are pixels;
  // the ArkUI overlay places in vp. Convert with px2vp (the display's own px/vp ratio), so the
  // overlay lands on exactly the frame the managed control was arranged with. A frame with a
  // non-positive width or height is a control that is not laid out yet (e.g. a web handler
  // without a desired height): it is ignored and that overlay keeps its previous placement -
  // full-window until the first valid frame - instead of expanding to the whole window and
  // hiding the rest of the page.
  private applyWebFrame(arg: string): void {
    const slot: number = this.webSlotOf(arg);
    const payload: string = this.webSlotPayload(arg);
    const parts: string[] = payload.split('\n');
    if (parts.length !== 4) {
      return;
    }
    const x: number = Number.parseFloat(parts[0]);
    const y: number = Number.parseFloat(parts[1]);
    const w: number = Number.parseFloat(parts[2]);
    const h: number = Number.parseFloat(parts[3]);
    if (!Number.isFinite(x) || !Number.isFinite(y) || !Number.isFinite(w) || !Number.isFinite(h)) {
      return;
    }
    const xVp: number = px2vp(Math.max(0, x));
    const yVp: number = px2vp(Math.max(0, y));
    const wVp: number = px2vp(w);
    const hVp: number = px2vp(h);
    if (!(wVp > 0) || !(hVp > 0)) {
      return;
    }
    this.webFrameX[slot] = xVp;
    this.webFrameY[slot] = yVp;
    this.webFrameW[slot] = wVp;
    this.webFrameH[slot] = hVp;
    this.webVisible[slot] = !this.webSuspended;
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
  private injectPageBridge(slot: number, pageUrl: string): void {
    let markers: string = '';
    if (this.hybridRegistered[slot] && this.hybridDocId[slot].length > 0 && pageUrl.startsWith(this.hybridOrigin)) {
      markers += `window.__ohHybridId = ${JSON.stringify(this.hybridDocId[slot])};`;
    }
    if (this.blazorRegistered && this.blazorDocId.length > 0 && pageUrl.startsWith(this.blazorOrigin)) {
      markers += `window.__ohBlazorId = ${JSON.stringify(this.blazorDocId)};`;
    }
    try {
      this.slotController(slot).runJavaScript(
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
    } catch {
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
  // shim injected above unchanged. A WASM site registration (blazorWasmMode) is skipped
  // entirely: it ships its own bootstrap and must never receive _framework/blazor.webview.js.
  private injectBlazorBootstrap(slot: number, pageUrl: string): void {
    if (!this.blazorRegistered || this.blazorWasmMode || this.blazorBootstrapped[slot] || !this.isBlazorRootDocument(pageUrl)) {
      return;
    }
    this.blazorBootstrapped[slot] = true;
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
      this.slotController(slot).runJavaScript(bootstrap, () => {
        // Best effort; an error leaves the page with the hybrid bridge only.
      });
    } catch (bootstrapError) {
      this.blazorBootstrapped[slot] = false;
      this.logError(`[maui] blazor bootstrap injection failed: ${(bootstrapError as Error).message}`);
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

  // Device-compat (lazy SDK modules): @kit.CameraKit camera is imported dynamically (the
  // device may lack it), so the API surface the synchronous flashlight sink needs is
  // preloaded once and cached here. A failed import is cached too and the feature degrades.
  private async preloadCamera(): Promise<void> {
    if (this.cameraGetManager !== undefined || this.lazyUnavailable('camera')) {
      return;
    }
    try {
      const cams = await import('@kit.CameraKit');
      this.cameraGetManager = (context: common.Context): camera.CameraManager => cams.camera.getCameraManager(context);
      this.cameraTorchOn = cams.camera.TorchMode.ON;
      this.cameraTorchOff = cams.camera.TorchMode.OFF;
      this.cameraBackPosition = cams.camera.CameraPosition.CAMERA_POSITION_BACK;
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
      manager = this.cameraGetManager(this.hostContext());
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

  // --- Bluetooth GATT (platform extra) ---------------------------------------
  // Managed Ops (the host's ohos_host_bluetooth_gatt_request; see OpenHarmonyBluetoothGatt.cs):
  //   0 connect, 1 disconnect, 2 get services, 3 read characteristic, 4 write characteristic,
  //   5 set notifications, 6 read descriptor, 7 write descriptor, 8 request MTU, 9 release.
  // Request/answer payloads are tab-separated; the managed side rejects any field carrying a
  // tab/LF/CR before it sends, so the split below cannot be forged from user data.

  // Registers the three kit listeners on a freshly created client. Value and state events are
  // pushed to the managed side as "kind\taddress\t..." records; the MTU callback also resolves an
  // in-flight request-MTU waiter and a connected/disconnected state resolves an in-flight connect
  // waiter. Every push is host-call guarded, so an older host library without
  // notifyBluetoothGattEvent only loses the events (requests keep working).
  private gattAttachListeners(client: ble.GattClientDevice, address: string): void {
    client.on('BLECharacteristicChange', (characteristic: ble.BLECharacteristic): void => {
      let value: string = '';
      try {
        value = new util.Base64Helper().encodeToStringSync(new Uint8Array(characteristic.characteristicValue));
      } catch (encodeError) {
        this.logError(`[maui] bluetooth gatt value encoding failed: ${(encodeError as Error).message}`);
        return;
      }
      this.hostCall('notifyBluetoothGattEvent', typeof host !== 'undefined' && typeof host.notifyBluetoothGattEvent === 'function', (): void => {
        host.notifyBluetoothGattEvent(`value\t${this.escapeRecordField(address)}\t${this.escapeRecordField(characteristic.serviceUuid)}\t${this.escapeRecordField(characteristic.characteristicUuid)}\t${value}`);
      });
    });
    client.on('BLEConnectionStateChange', (change: ble.BLEConnectionChangeState): void => {
      this.gattStates.set(address, change.state);
      if (change.state === 2 || change.state === 0) {
        const waiter: ((connected: boolean) => void) | undefined = this.gattConnectWaiters.get(address);
        if (waiter !== undefined) {
          this.gattConnectWaiters.delete(address);
          waiter(change.state === 2);
        }
      }
      const reason: string = change.reason !== undefined ? `${change.reason}` : '';
      this.hostCall('notifyBluetoothGattEvent', typeof host !== 'undefined' && typeof host.notifyBluetoothGattEvent === 'function', (): void => {
        host.notifyBluetoothGattEvent(`state\t${this.escapeRecordField(address)}\t${change.state}\t${reason}`);
      });
    });
    client.on('BLEMtuChange', (mtu: number): void => {
      const waiter: ((mtu: number) => void) | undefined = this.gattMtuWaiters.get(address);
      if (waiter !== undefined) {
        this.gattMtuWaiters.delete(address);
        waiter(mtu);
      }
      this.hostCall('notifyBluetoothGattEvent', typeof host !== 'undefined' && typeof host.notifyBluetoothGattEvent === 'function', (): void => {
        host.notifyBluetoothGattEvent(`mtu\t${this.escapeRecordField(address)}\t${mtu}`);
      });
    });
  }

  // Returns the cached client for an address, creating it and registering its kit listeners on
  // first use. Throws only when the lazily imported create factory is missing; the sink handler
  // turns that into the unavailable answer and caches the missing kit.
  private gattClientFor(address: string): ble.GattClientDevice {
    let client: ble.GattClientDevice | undefined = this.gattClients.get(address);
    if (client !== undefined) {
      return client;
    }
    const create: ((address: string) => ble.GattClientDevice) | undefined = this.gattCreateClient;
    if (create === undefined) {
      throw new Error('connectivity kit is not available');
    }
    client = create(address);
    this.gattAttachListeners(client, address);
    this.gattClients.set(address, client);
    return client;
  }

  // Connects the client and resolves 0 only once the BLEConnectionStateChange callback reports
  // STATE_CONNECTED (2). A reported disconnect (0) and the timeout both answer -2; the state
  // itself is always pushed to the managed side.
  private async gattConnect(client: ble.GattClientDevice, address: string): Promise<number> {
    return new Promise<number>((resolve: (value: number) => void): void => {
      let settled: boolean = false;
      const finish = (code: number): void => {
        if (settled) {
          return;
        }
        settled = true;
        this.gattConnectWaiters.delete(address);
        resolve(code);
      };
      this.gattConnectWaiters.set(address, (connected: boolean): void => {
        finish(connected ? 0 : -2);
      });
      setTimeout((): void => {
        finish(-2);
      }, this.gattConnectTimeoutMs);
      try {
        client.connect();
      } catch (connectError) {
        this.logError(`[maui] bluetooth gatt connect failed: ${(connectError as Error).message}`);
        finish(-2);
      }
    });
  }

  // Requests an MTU (setBLEMtuSize is fire-and-forget) and resolves with the BLEMtuChange value
  // when it arrives within the MTU timeout; a timeout answers code 0 with mtu 0, which the
  // managed side reports as "the requested value was not negotiated".
  private async gattRequestMtu(client: ble.GattClientDevice, address: string, mtu: number): Promise<BluetoothGattMtuAnswer> {
    return new Promise<BluetoothGattMtuAnswer>((resolve: (value: BluetoothGattMtuAnswer) => void): void => {
      let settled: boolean = false;
      const finish = (code: number, negotiated: number): void => {
        if (settled) {
          return;
        }
        settled = true;
        this.gattMtuWaiters.delete(address);
        resolve({ code: code, mtu: negotiated });
      };
      this.gattMtuWaiters.set(address, (negotiated: number): void => {
        finish(0, negotiated);
      });
      setTimeout((): void => {
        finish(0, 0);
      }, this.gattMtuTimeoutMs);
      try {
        client.setBLEMtuSize(mtu);
      } catch (mtuError) {
        this.logError(`[maui] bluetooth gatt mtu request failed: ${(mtuError as Error).message}`);
        finish(-2, 0);
      }
    });
  }

  // Packs the optional GattProperties into the decimal bitmask the managed
  // OpenHarmonyGattProperty mirrors (1 read, 2 write, 4 write without response, 8 notify,
  // 16 indicate, 32 broadcast, 64 authenticated signed write, 128 extended properties).
  private gattPropertyFlags(properties: ble.GattProperties | undefined): number {
    if (properties === undefined) {
      return 0;
    }
    let flags: number = 0;
    if (properties.read === true) { flags += 1; }
    if (properties.write === true) { flags += 2; }
    if (properties.writeNoResponse === true) { flags += 4; }
    if (properties.notify === true) { flags += 8; }
    if (properties.indicate === true) { flags += 16; }
    if (properties.broadcast === true) { flags += 32; }
    if (properties.authenticatedSignedWrite === true) { flags += 64; }
    if (properties.extendedProperties === true) { flags += 128; }
    return flags;
  }

  private answerBluetoothGatt(requestId: number, code: number, payload: string): void {
    this.hostCall('notifyBluetoothGattResult', typeof host !== 'undefined' && typeof host.notifyBluetoothGattResult === 'function', (): void => {
      host.notifyBluetoothGattResult(requestId, code, payload);
    });
  }

  // Runs one managed GATT request. The lazy import stays outside the inner try so a missing
  // Connectivity Kit bubbles to the sink handler (cached, answered -1); everything after the
  // import answers its own code (-1 for a denied permission, -2 for kit/argument failures).
  private async runBluetoothGatt(op: number, payload: string): Promise<BluetoothGattAnswer> {
    const kit = await import('@kit.ConnectivityKit');
    try {
      const context = this.hostContext();
      const permissions: Permissions[] = ['ohos.permission.ACCESS_BLUETOOTH'];
      const atManager = abilityAccessCtrl.createAtManager();
      const granted = await atManager.requestPermissionsFromUser(context, permissions);
      if (granted.authResults.length === 0 || granted.authResults[0] !== 0) {
        return { code: -1, payload: 'bluetooth permission denied' };
      }
      if (this.gattCreateClient === undefined) {
        this.gattCreateClient = (address: string): ble.GattClientDevice => kit.ble.createGattClientDevice(address);
      }
      const fields: string[] = payload.length > 0 ? payload.split('\t') : [];
      const address: string = fields.length > 0 ? fields[0] : '';
      if (address.length === 0) {
        return { code: -2, payload: 'the device address is required' };
      }
      if (op === 0) {
        if (this.gattStates.get(address) === 2) {
          return { code: 0, payload: '' };
        }
        const code: number = await this.gattConnect(this.gattClientFor(address), address);
        return { code: code, payload: code === 0 ? '' : 'connect did not reach the connected state' };
      }
      if (op === 1) {
        this.gattClientFor(address).disconnect();
        return { code: 0, payload: '' };
      }
      if (op === 2) {
        const services: ble.GattService[] = await this.gattClientFor(address).getServices();
        const rows: string[] = [];
        for (const service of services) {
          const primary: number = service.isPrimary ? 1 : 0;
          if (service.characteristics.length === 0) {
            // A service without characteristics still appears (characteristic/properties empty).
            rows.push(`${this.escapeRecordField(service.serviceUuid)}\t${primary}\t\t`);
          }
          for (const characteristic of service.characteristics) {
            rows.push(`${this.escapeRecordField(service.serviceUuid)}\t${primary}\t${this.escapeRecordField(characteristic.characteristicUuid)}\t${this.gattPropertyFlags(characteristic.properties)}`);
          }
        }
        return { code: 0, payload: rows.join('\n') };
      }
      if (op === 9) {
        const client: ble.GattClientDevice | undefined = this.gattClients.get(address);
        if (client !== undefined) {
          this.gattClients.delete(address);
          this.gattConnectWaiters.delete(address);
          this.gattMtuWaiters.delete(address);
          this.gattStates.delete(address);
          client.close();
        }
        return { code: 0, payload: '' };
      }
      if (op === 8) {
        if (fields.length < 2) {
          return { code: -2, payload: 'the MTU value is required' };
        }
        const mtu: number = Number.parseInt(fields[1], 10);
        const answer: BluetoothGattMtuAnswer = await this.gattRequestMtu(this.gattClientFor(address), address, mtu);
        return { code: answer.code, payload: answer.mtu > 0 ? `${answer.mtu}` : '' };
      }
      if (fields.length < 3) {
        return { code: -2, payload: 'the service and characteristic UUIDs are required' };
      }
      const serviceUuid: string = fields[1];
      const characteristicUuid: string = fields[2];
      const client: ble.GattClientDevice = this.gattClientFor(address);
      if (op === 3) {
        const characteristic: ble.BLECharacteristic = {
          serviceUuid: serviceUuid,
          characteristicUuid: characteristicUuid,
          characteristicValue: new ArrayBuffer(0),
          descriptors: [],
        };
        const read: ble.BLECharacteristic = await client.readCharacteristicValue(characteristic);
        return { code: 0, payload: new util.Base64Helper().encodeToStringSync(new Uint8Array(read.characteristicValue)) };
      }
      if (op === 4) {
        if (fields.length < 5) {
          return { code: -2, payload: 'the write type and value are required' };
        }
        const value: Uint8Array = new util.Base64Helper().decodeSync(fields[4]);
        const characteristic: ble.BLECharacteristic = {
          serviceUuid: serviceUuid,
          characteristicUuid: characteristicUuid,
          characteristicValue: value.buffer as ArrayBuffer,
          descriptors: [],
        };
        const writeType: ble.GattWriteType = fields[3] === '2' ? kit.ble.GattWriteType.WRITE_NO_RESPONSE : kit.ble.GattWriteType.WRITE;
        await client.writeCharacteristicValue(characteristic, writeType);
        return { code: 0, payload: '' };
      }
      if (op === 5) {
        if (fields.length < 4) {
          return { code: -2, payload: 'the enable flag is required' };
        }
        const characteristic: ble.BLECharacteristic = {
          serviceUuid: serviceUuid,
          characteristicUuid: characteristicUuid,
          characteristicValue: new ArrayBuffer(0),
          descriptors: [],
        };
        await client.setCharacteristicChangeNotification(characteristic, fields[3] === '1');
        return { code: 0, payload: '' };
      }
      if (fields.length < 4) {
        return { code: -2, payload: 'the descriptor UUID is required' };
      }
      const descriptorUuid: string = fields[3];
      if (op === 6) {
        const descriptor: ble.BLEDescriptor = {
          serviceUuid: serviceUuid,
          characteristicUuid: characteristicUuid,
          descriptorUuid: descriptorUuid,
          descriptorValue: new ArrayBuffer(0),
        };
        const read: ble.BLEDescriptor = await client.readDescriptorValue(descriptor);
        return { code: 0, payload: new util.Base64Helper().encodeToStringSync(new Uint8Array(read.descriptorValue)) };
      }
      if (op === 7) {
        if (fields.length < 5) {
          return { code: -2, payload: 'the descriptor value is required' };
        }
        const value: Uint8Array = new util.Base64Helper().decodeSync(fields[4]);
        const descriptor: ble.BLEDescriptor = {
          serviceUuid: serviceUuid,
          characteristicUuid: characteristicUuid,
          descriptorUuid: descriptorUuid,
          descriptorValue: value.buffer as ArrayBuffer,
        };
        await client.writeDescriptorValue(descriptor);
        return { code: 0, payload: '' };
      }
      return { code: -2, payload: `unsupported bluetooth gatt op ${op}` };
    } catch (gattError) {
      this.logError(`[maui] bluetooth gatt op ${op} failed: ${(gattError as Error).message}`);
      return { code: -2, payload: (gattError as Error).message };
    }
  }

  // --- Media playback (platform extra) ---------------------------------------
  // Managed Ops (the host's ohos_host_media_request; see OpenHarmonyMediaPlayer.cs):
  //   0 load (payload "kind\tlocation"; kind 0 url / 1 rawfile / 2 sandbox file path),
  //   1 play, 2 pause, 3 stop, 4 seek (payload = position ms), 5 release,
  //   6 status (answers "state\tpositionMs\tdurationMs").
  // One AVPlayer is owned per process (the managed surface is static): a load releases the
  // previous source first. Every stateChange/timeUpdate/durationUpdate/error is pushed to the
  // managed side through host.notifyMediaEvent as "state\tname[\treason]" / "time\tms" /
  // "duration\tms" / "error\tcode\tmessage". Requests are serialized through a promise chain,
  // so one load cannot race another. Device-compat: the Media Kit is imported lazily on the
  // first request; a missing kit is cached and answers -1 (the Bluetooth GATT sink pattern).
  private mediaPlayer: media.AVPlayer | undefined = undefined;
  private mediaFile: fs.File | undefined = undefined;
  private mediaRawName: string = '';
  private mediaState: string = 'idle';
  private mediaWaiters: Map<string, () => void> = new Map();
  private mediaChain: Promise<void> = Promise.resolve();

  private answerMedia(requestId: number, code: number, payload: string): void {
    this.logInfo(`[maui] media answer request=${requestId} code=${code}${payload.length > 0 ? ` payload=${payload}` : ''}`);
    this.hostCall('notifyMediaResult', typeof host !== 'undefined' && typeof host.notifyMediaResult === 'function', (): void => {
      host.notifyMediaResult(requestId, code, payload);
    });
  }

  private pushMedia(record: string): void {
    this.hostCall('notifyMediaEvent', typeof host !== 'undefined' && typeof host.notifyMediaEvent === 'function', (): void => {
      host.notifyMediaEvent(record);
    });
  }

  // The SDK's StateChangeReason enum (user 1 / background 2); an unknown value travels as its
  // decimal form so the managed side still sees it.
  private mediaReasonName(reason: number): string {
    if (reason === 1) {
      return 'user';
    }
    if (reason === 2) {
      return 'background';
    }
    return `${reason}`;
  }

  // Registers the AVPlayer listeners once per player. The state waiters are resolved here, so a
  // load can await the 'initialized'/'prepared' transitions without polling.
  private mediaAttach(player: media.AVPlayer): void {
    player.on('stateChange', (state: media.AVPlayerState, reason: media.StateChangeReason): void => {
      this.mediaState = state;
      this.logInfo(`[maui] media state=${state} reason=${this.mediaReasonName(reason)}`);
      const waiter: (() => void) | undefined = this.mediaWaiters.get(`state:${state}`);
      if (waiter !== undefined) {
        this.mediaWaiters.delete(`state:${state}`);
        waiter();
      }
      this.pushMedia(`state\t${state}\t${this.mediaReasonName(reason)}`);
    });
    player.on('timeUpdate', (position: number): void => {
      this.pushMedia(`time\t${Math.max(0, Math.trunc(position))}`);
    });
    player.on('durationUpdate', (duration: number): void => {
      this.pushMedia(`duration\t${Math.max(0, Math.trunc(duration))}`);
    });
    player.on('error', (error: BusinessError): void => {
      this.logError(`[maui] media player error code=${error.code} message=${error.message}`);
      this.pushMedia(`error\t${error.code}\t${this.escapeRecordField(error.message)}`);
    });
  }

  // Resolves true when the player reaches <name> before the timeout. Requests are serialized,
  // so at most one state wait is pending.
  private mediaWaitForState(name: string, timeoutMs: number): Promise<boolean> {
    if (this.mediaState === name) {
      return Promise.resolve(true);
    }
    return new Promise<boolean>((resolve: (value: boolean) => void): void => {
      let settled: boolean = false;
      const finish = (ok: boolean): void => {
        if (settled) {
          return;
        }
        settled = true;
        this.mediaWaiters.delete(`state:${name}`);
        resolve(ok);
      };
      this.mediaWaiters.set(`state:${name}`, (): void => {
        finish(true);
      });
      setTimeout((): void => {
        finish(false);
      }, timeoutMs);
    });
  }

  // Releases the current player and closes whichever descriptor was opened for it, best effort:
  // a failing release/close is logged and never fails the caller.
  private async mediaTeardown(): Promise<void> {
    const player: media.AVPlayer | undefined = this.mediaPlayer;
    this.mediaPlayer = undefined;
    if (player !== undefined) {
      try {
        await player.release();
      } catch (releaseError) {
        this.logWarn(`[maui] media release failed: ${(releaseError as Error).message}`);
      }
    }
    if (this.mediaFile !== undefined) {
      try {
        fs.closeSync(this.mediaFile);
      } catch (closeError) {
        this.logWarn(`[maui] media file close failed: ${(closeError as Error).message}`);
      }
      this.mediaFile = undefined;
    }
    if (this.mediaRawName.length > 0) {
      const rawName: string = this.mediaRawName;
      this.mediaRawName = '';
      try {
        const manager: resourceManager.ResourceManager = this.hostContext().resourceManager;
        await manager.closeRawFd(rawName);
      } catch (rawCloseError) {
        this.logWarn(`[maui] media rawfile close failed: ${(rawCloseError as Error).message}`);
      }
    }
    this.mediaState = 'released';
    this.mediaWaiters.clear();
  }

  // Serializes one media request behind the previous one and keeps the chain alive after a
  // failure (the failure still reaches this request's caller).
  private mediaEnqueue(op: number, payload: string): Promise<MediaAnswer> {
    const result: Promise<MediaAnswer> = this.mediaChain.then((): Promise<MediaAnswer> => this.runMedia(op, payload));
    this.mediaChain = result.then((): void => {}, (): void => {});
    return result;
  }

  // Runs one managed media request. The lazy import stays outside the inner try so a missing
  // Media Kit bubbles to the sink handler (cached, answered -1); a kit namespace that resolves
  // without the player factory is treated the same way, because this image family ships images
  // whose runtime resolves @kit.MediaKit but carries no media namespace (the player API is
  // unreachable). Everything after the namespace check answers its own code (-2 for kit or
  // argument failures).
  private async runMedia(op: number, payload: string): Promise<MediaAnswer> {
    if (op === 5) {
      await this.mediaTeardown();
      return { code: 0, payload: '' };
    }
    if (op === 6 && this.mediaPlayer === undefined) {
      // No source is loaded: status answers idle without importing the kit.
      return { code: 0, payload: 'idle\t0\t0' };
    }
    const kit = await import('@kit.MediaKit');
    const mediaKit: MediaKitNamespace | undefined = (kit as ESObject).media as MediaKitNamespace | undefined;
    if (mediaKit === undefined || mediaKit === null || typeof mediaKit.createAVPlayer !== 'function') {
      this.noteLazyFailure('mediaKit', new Error('the Media Kit namespace or createAVPlayer is missing'));
      return { code: -1, payload: '' };
    }
    try {
      if (op === 0) {
        await this.mediaTeardown();
        const fields: string[] = payload.length > 0 ? payload.split('\t') : [];
        if (fields.length < 2 || fields[1].length === 0) {
          return { code: -2, payload: 'the source location is required' };
        }
        const kind: number = Number(fields[0]);
        const location: string = fields[1];
        const player: media.AVPlayer = await mediaKit.createAVPlayer();
        this.mediaAttach(player);
        this.mediaPlayer = player;
        if (kind === 0) {
          // Stream or file URL: the Media Kit owns the fetch.
          player.url = location;
        } else if (kind === 1) {
          // HAP rawfile: the resource manager hands the descriptor to the player, which reads
          // it for the whole playback; it is closed on release/teardown.
          const info: resourceManager.RawFileDescriptor = await this.hostContext().resourceManager.getRawFd(location);
          this.mediaRawName = location;
          const rawFd: media.AVFileDescriptor = { fd: info.fd, offset: info.offset, length: info.length };
          player.fdSrc = rawFd;
        } else if (kind === 2) {
          // Sandbox file (app files/cache dir): the shell owns the descriptor until release.
          const file: fs.File = fs.openSync(location, fs.OpenMode.READ_ONLY);
          this.mediaFile = file;
          const size: number = fs.statSync(location).size;
          const fileFd: media.AVFileDescriptor = { fd: file.fd, offset: 0, length: size };
          player.fdSrc = fileFd;
        } else {
          return { code: -2, payload: `unknown media source kind ${kind}` };
        }
        if (!(await this.mediaWaitForState('initialized', 10000))) {
          return { code: -2, payload: 'the player did not reach initialized' };
        }
        await player.prepare();
        if (!(await this.mediaWaitForState('prepared', 10000))) {
          return { code: -2, payload: 'the player did not reach prepared' };
        }
        return { code: 0, payload: '' };
      }
      const player: media.AVPlayer | undefined = this.mediaPlayer;
      if (player === undefined) {
        return { code: -2, payload: 'no media source is loaded' };
      }
      if (op === 1) {
        if (this.mediaState !== 'playing') {
          await player.play();
        }
        return { code: 0, payload: '' };
      }
      if (op === 2) {
        if (this.mediaState === 'playing') {
          await player.pause();
        }
        return { code: 0, payload: '' };
      }
      if (op === 3) {
        if (this.mediaState !== 'stopped' && this.mediaState !== 'released' && this.mediaState !== 'idle') {
          await player.stop();
        }
        return { code: 0, payload: '' };
      }
      if (op === 4) {
        const positionMs: number = Number(payload);
        if (!Number.isFinite(positionMs) || positionMs < 0) {
          return { code: -2, payload: 'the seek position is required' };
        }
        player.seek(Math.trunc(positionMs));
        return { code: 0, payload: '' };
      }
      if (op === 6) {
        let position: number = 0;
        let duration: number = 0;
        try {
          position = Math.max(0, Math.trunc(player.currentTime));
        } catch (positionError) {
          position = 0;
        }
        try {
          const reported: number = player.duration;
          duration = reported > 0 ? Math.trunc(reported) : 0;
        } catch (durationError) {
          duration = 0;
        }
        return { code: 0, payload: `${this.mediaState}\t${position}\t${duration}` };
      }
      return { code: -2, payload: `unsupported media op ${op}` };
    } catch (mediaError) {
      this.logError(`[maui] media op ${op} failed: ${(mediaError as Error).message}`);
      return { code: -2, payload: (mediaError as Error).message };
    }
  }

  // Device probe: checks whether this runtime can reach the Media Kit player API and answers
  // one op-6 status through the sink's own processing path, so every device run carries a
  // clear media availability line in hilog independently of the managed side.
  private async mediaSelfTest(): Promise<void> {
    try {
      const kit: ESObject = await import('@kit.MediaKit');
      const mediaObject: ESObject = kit.media;
      let available: boolean = mediaObject !== undefined && mediaObject !== null;
      if (available) {
        const create: ESObject = mediaObject.createAVPlayer;
        available = typeof create === 'function';
      }
      this.logInfo(`[maui] media self-test media-kit=${available ? 'available' : 'missing'} media-core-capability=${typeof canIUse === 'function' ? canIUse('SystemCapability.Multimedia.Media.Core') : false}`);
    } catch (shapeError) {
      this.logWarn(`[maui] media self-test kit probe failed: ${(shapeError as Error).message}`);
    }
    const status: MediaAnswer = await this.runMedia(6, '');
    this.logInfo(`[maui] media self-test status code=${status.code} payload='${status.payload}'`);
  }

  aboutToAppear(): void {
    // 0 = create: the ability exists by the time the page appears. The native host queues
    // lifecycle events that arrive before the managed app is up, so sending it before the
    // Foreground event below makes the managed window's Created/Activated precede Resumed.
    this.hostCall('notifyLifecycle', typeof host !== 'undefined' && typeof host.notifyLifecycle === 'function', (): void => {
      host.notifyLifecycle(0);
    });
    // 2 = foreground; the native host forwards it to the managed bridge.
    this.hostCall('notifyLifecycle', typeof host !== 'undefined' && typeof host.notifyLifecycle === 'function', (): void => {
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
    this.reportBundleInfo();
    this.subscribeBatteryEvents();
    this.subscribeDisplayChange();
    this.subscribeWindowShapeChange();
    // MULTIWINDOW-M: the managed subwindow commands arrive through this sink (create is the
    // only entry; nothing is allocated until then, so apps without a child pay nothing).
    this.subscribeSubWindow();
    // MULTIWINDOW-M fallback: Home-key/gesture background does not deliver WINDOW_HIDDEN, so the
    // ability lifecycle mirrors into the subwindow suspend state (no child -> state only).
    this.subscribeAppLifecycleSuspension();
    this.subscribeNetworkChanges();
    // Device-compat (lazy SDK modules): the camera module is needed by the synchronous
    // flashlight sink and by the picker's camera position, so it is preloaded once here.
    this.preloadCamera();
    // Keep screen on (DeviceDisplay): the managed setter pushes 0/1 through
    // ohos_host_keep_screen_on. Best effort: an older host library without the export leaves
    // the managed cached value unchanged instead of failing the page.
    this.hostCall('registerKeepScreenOnSink', typeof host !== 'undefined' && typeof host.registerKeepScreenOnSink === 'function', (): void => {
      host.registerKeepScreenOnSink((on: number): void => {
        this.applyKeepScreenOn(on);
      });
    });
    // Window chrome (Window handler): the managed title/rect setters arrive here and are
    // applied to the main window. Both are one-way: the .so's 0/-1 only reports the queueing.
    this.hostCall('registerWindowTitleSink', typeof host !== 'undefined' && typeof host.registerWindowTitleSink === 'function', (): void => {
      host.registerWindowTitleSink((title: string): void => {
        this.applyWindowTitle(title);
      });
    });
    this.hostCall('registerWindowRectSink', typeof host !== 'undefined' && typeof host.registerWindowRectSink === 'function', (): void => {
      host.registerWindowRectSink((x: number, y: number, w: number, h: number): void => {
        this.applyWindowRect(x, y, w, h);
      });
    });
    // Window decorations (N6): the managed Window.TitleBar row takes the window's caption over.
    // The sink is registered only when the runtime can actually hand it over - SessionManager
    // present and the window not fullscreen - so a fullscreen phone window keeps its system
    // decorations and the managed row's availability probe stays 0 (no caption buttons drawn,
    // no decor hidden).
    const decorSupported: boolean = typeof canIUse === 'function' &&
      canIUse('SystemCapability.Window.SessionManager');
    if (decorSupported) {
      window.getLastWindow(this.hostContext()).then((decorWindow) => {
        if (decorWindow.getWindowStatus() === window.WindowStatusType.FULL_SCREEN) {
          return;
        }
        this.hostCall('registerWindowDecorSink', typeof host !== 'undefined' && typeof host.registerWindowDecorSink === 'function', (): void => {
          host.registerWindowDecorSink((op: number): void => {
            this.applyWindowDecor(decorWindow, op);
          });
        });
      }).catch((decorWindowError: Error): void => {
        this.logError(`[maui] window decor window unavailable: ${decorWindowError.message}`);
      });
    }
    // Screenshot (Window handler): a one-way request carrying an app-owned output path (and,
    // for ohos_host_screenshot_format, the format/quality).
    this.hostCall('registerScreenshotSink', typeof host !== 'undefined' && typeof host.registerScreenshotSink === 'function', (): void => {
      host.registerScreenshotSink(async (outPath: string, format?: number, quality?: number): Promise<void> => {
        await this.captureScreenshot(outPath, format, quality);
      });
    });
    // Shell search/flyout (Shell handler): the managed SearchHandler state and the flyout
    // section text. A registration after the managed publish can miss the first push, so the
    // hosts' stored getters seed the labels; the search field reports user interactions back
    // through host.notifyShellSearch (0 query, 1 submit, 2 cancel).
    this.hostCall('registerShellSearchChangedSink', typeof host !== 'undefined' && typeof host.registerShellSearchChangedSink === 'function', (): void => {
      host.registerShellSearchChangedSink((query: string, placeholder: string, visible: number, enabled: number): void => {
        this.shellSearchQuery = query;
        this.shellSearchPlaceholder = placeholder;
        this.shellSearchVisible = visible !== 0;
        this.shellSearchEnabled = enabled !== 0;
      });
    });
    this.hostCall('registerShellFlyoutChangedSink', typeof host !== 'undefined' && typeof host.registerShellFlyoutChangedSink === 'function', (): void => {
      host.registerShellFlyoutChangedSink((op: number, text: string): void => {
        if (op === 0) {
          this.flyoutHeader = text;
        } else if (op === 1) {
          this.flyoutFooter = text;
        }
      });
    });
    this.hostCall('shellSearchQuery', typeof host !== 'undefined' && typeof host.shellSearchQuery === 'function', (): void => {
      this.shellSearchQuery = host.shellSearchQuery() as string;
      this.shellSearchPlaceholder = host.shellSearchPlaceholder() as string;
      this.shellSearchVisible = (host.shellSearchVisible() as number) !== 0;
      this.shellSearchEnabled = (host.shellSearchEnabled() as number) !== 0;
    });
    this.hostCall('shellFlyoutHeader', typeof host !== 'undefined' && typeof host.shellFlyoutHeader === 'function', (): void => {
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
    // Safe area: report the system avoid area so the managed layout can inset its content, and
    // subscribe to the keyboard's avoid-area change so the soft-input inset reaches the managed
    // SafeArea (SafeAreaEdges.SoftInput/All) through host.notifySoftInputArea.
    window.getLastWindow(this.hostContext()).then((win) => {
      this.reportWindowAvoidArea(win);
    }).catch(() => {
      // Window information is optional.
    });
    this.subscribeSoftInputArea();

    // WebView: a hidden ArkWeb component that the managed WebView handler drives.
    // Host callback: every controller call runs on the page's UI thread (see runOnUiThread).
    // The registration result and the navigation-carrying commands are logged: a device run
    // needs to distinguish "the managed handler never sent" from "the shell never armed".
    const webSinkRegistered: boolean = this.hostCall('registerWebSink', typeof host !== 'undefined' && typeof host.registerWebSink === 'function', (): void => {
      host.registerWebSink((op: string, arg: string) => {
        if (op !== 'frame' && op !== 'cookieGet') {
          this.logInfo(`[maui] web cmd: ${op}`);
        }
        this.runOnUiThread(() => {
          try {
            this.runWebCommand(op, arg);
          } catch {
            // Web errors never take the app down.
          }
        });
      });
    });

    // JavaScript bridge: the managed side evaluates scripts through ohos_host_web_eval; the
    // runJavaScript result (or its error) travels back to the awaiting request.
    // Host callback: runJavaScript is UI-thread only (see runOnUiThread).
    this.hostCall('registerWebEvalSink', typeof host !== 'undefined' && typeof host.registerWebEvalSink === 'function', (): void => {
      host.registerWebEvalSink((script: string, requestId: number): void => {
        this.runOnUiThread(() => {
          try {
            // MULTI-OVL: the managed eval is tagged "s<slot>\n<script>"; untagged scripts run
            // on the first overlay (cookie reads and legacy diagnostics). SLOTS-DYNAMIC: a
            // script for a slot whose ArkWeb has not attached yet is deferred and replayed from
            // onControllerAttached (with its request id, so the await still completes).
            const evalSlot: number = this.webSlotOf(script);
            if (!this.webSlotReady(evalSlot)) {
              this.deferWebOp(evalSlot, 'eval', script, requestId);
              return;
            }
            this.runWebEval(script, requestId);
          } catch (evalError) {
            this.hostCall('notifyWebEvalResult', typeof host !== 'undefined' && typeof host.notifyWebEvalResult === 'function', (): void => {
              host.notifyWebEvalResult(requestId, '', 1);
            });
          }
        });
      });
    });
    this.logInfo(`[maui] web sink: ${webSinkRegistered}`);
    // SLOTS-DYNAMIC: tell the managed pool how many overlays this shell can declare. The page
    // can load before the managed WebEvent subscription exists, so the notification is sent
    // with two bounded retries (the pool's default is the same WEB_SLOT_MAX, so a lost event
    // only delays a downgrade on a legacy shell).
    this.advertiseWebCapacity();
    setTimeout((): void => {
      this.advertiseWebCapacity();
    }, 1500);
    setTimeout((): void => {
      this.advertiseWebCapacity();
    }, 4000);
    // Managed status file (device diagnostics): the managed bridge appends one line per event
    // to <filesDir>/dotnet-status.txt, but this image does not route managed stderr to hilog,
    // so a few bounded reads surface the managed side's own view (window created, web commands
    // sent, failures). Reads stop after 12 iterations; only changed content is logged.
    this.pollManagedStatus();

    // HybridWebView JS -> .NET invocation results: the managed handler answers a
    // host.notifyHybridInvoke call through ohos_host_hwv_invoke_result, which lands here and
    // completes the delayed __hwvInvokeDotNet response.
    this.hostCall('registerHybridInvokeResultSink', typeof host !== 'undefined' && typeof host.registerHybridInvokeResultSink === 'function', (): void => {
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
    // @kit.CoreFileKit picker PhotoViewPicker is deprecated in its favour) and modes 3/4 are the
    // separate camera-capture path (cameraPicker). Device-compat: photoAccessHelper, camera
    // and cameraPicker are imported lazily; when camera/cameraPicker is missing the capture
    // branch answers -1 (the managed side reports IsSupported == false), and when
    // photoAccessHelper is missing photo/video picking falls back to the document picker.
    this.hostCall('registerPickerSink', typeof host !== 'undefined' && typeof host.registerPickerSink === 'function', (): void => {
      host.registerPickerSink(async (requestId: number, kind: number) => {
        const mode: number = kind & 7;
        const multi: boolean = (kind & 8) !== 0;
        const rawCount: number = kind >> 4;
        const count: number = multi ? (rawCount === 0 ? 500 : Math.min(rawCount, 500)) : 1;
        if (mode === 3 || mode === 4) {
          if (this.lazyUnavailable('camera') || this.lazyUnavailable('cameraPicker')) {
            this.hostCall('notifyPickerResult', typeof host !== 'undefined' && typeof host.notifyPickerResult === 'function', (): void => {
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
              const cams = await import('@kit.CameraKit');
              cameraPosition = cams.camera.CameraPosition.CAMERA_POSITION_BACK;
              this.cameraBackPosition = cameraPosition;
            } catch (cameraPickImportError) {
              this.noteLazyFailure('camera', cameraPickImportError as Error);
            }
          }
          if (cameraPosition === undefined) {
            this.hostCall('notifyPickerResult', typeof host !== 'undefined' && typeof host.notifyPickerResult === 'function', (): void => {
              host.notifyPickerResult(requestId, -1, '', '');
            });
            return;
          }
          const backPosition: camera.CameraPosition = cameraPosition;
          try {
            const pickers = await import('@kit.CameraKit');
            try {
              const mediaType = mode === 3 ? pickers.cameraPicker.PickerMediaType.PHOTO : pickers.cameraPicker.PickerMediaType.VIDEO;
              const picked = await pickers.cameraPicker.pick(this.hostContext(), [mediaType], {
                cameraPosition: backPosition,
              });
              const captureUri: string = picked.resultUri;
              const captureName: string = captureUri.substring(captureUri.lastIndexOf('/') + 1);
              const captureFile = fs.openSync(captureUri, fs.OpenMode.READ_ONLY);
              const captureBuffer = new ArrayBuffer(fs.statSync(captureUri).size);
              fs.readSync(captureFile.fd, captureBuffer);
              fs.closeSync(captureFile);
              const captureBase64 = new util.Base64Helper().encodeToStringSync(new Uint8Array(captureBuffer));
              this.hostCall('notifyPickerResult', typeof host !== 'undefined' && typeof host.notifyPickerResult === 'function', (): void => {
                host.notifyPickerResult(requestId, 0, captureName, captureBase64);
              });
            } catch (captureError) {
              this.logError(`camera capture failed: ${(captureError as Error).message}`);
              this.hostCall('notifyPickerResult', typeof host !== 'undefined' && typeof host.notifyPickerResult === 'function', (): void => {
                host.notifyPickerResult(requestId, -1, '', '');
              });
            }
          } catch (pickerImportError) {
            this.noteLazyFailure('cameraPicker', pickerImportError as Error);
            this.hostCall('notifyPickerResult', typeof host !== 'undefined' && typeof host.notifyPickerResult === 'function', (): void => {
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
        // Documents (and the media fallback) stay on the static @kit.CoreFileKit picker /
        // @kit.CoreFileKit fileIo imports, with the caller's maxSelectNumber (1 for single-select).
        await this.selectDocumentUris(requestId, multi, count);
      });
    });

    // Raw HAP resources (resources/rawfile/**): the managed FileSystem asks for one asset
    // through host.registerRawFileSink - op 0 reads it, op 1 probes existence. op 0 prefers the
    // descriptor transport: getRawFd hands the host {fd, offset, length} and the host preads the
    // bytes straight into the managed byte[] (no base64 string), then the descriptor is closed;
    // when the descriptor or the host export is unavailable, or the host did not answer the
    // read, op 0 falls back to getRawFileContent + base64. Device-compat: the resource manager
    // comes from the ability context on the first request and is cached, so nothing is imported
    // at page start and a context without one answers rc=-1. rc map (matches ohos_raw_file_rc in
    // openharmony_host.h): 0 ok, -1 unavailable, -2 not found, -3 over rawFileMaxBytes. The cap
    // is checked before the content is read or encoded, so a bigger file is answered with -3 and
    // never copied.
    this.hostCall('registerRawFileSink', typeof host !== 'undefined' && typeof host.registerRawFileSink === 'function', (): void => {
      host.registerRawFileSink(async (requestId: number, op: number, name: string): Promise<void> => {
        const answer = (rc: number, dataBase64: string): void => {
          this.hostCall('notifyRawFileResult', typeof host !== 'undefined' && typeof host.notifyRawFileResult === 'function', (): void => {
            host.notifyRawFileResult(requestId, rc, dataBase64);
          });
        };
        // The descriptor's owner is the shell; the host only reads it during the synchronous
        // notifyRawFileFd call, so closing it here (on every path) is safe.
        const closeRawFd = async (manager: resourceManager.ResourceManager, relative: string): Promise<void> => {
          try {
            await manager.closeRawFd(relative);
          } catch (closeError) {
            // The answer (if any) is already delivered; a close failure must not change it.
            this.logError(`[maui] rawfile closeRawFd failed: ${(closeError as Error).message}`);
          }
        };
        const relative: string = name.replace(/\\/g, '/').replace(/^\/+/, '');
        if (relative.length === 0 || relative.length > 4096) {
          answer(-1, '');
          return;
        }
        try {
          let manager: resourceManager.ResourceManager | undefined = this.rawFileManager;
          if (manager === undefined) {
            // Stage model: the ability context owns the app's resource manager (resolved on
            // the first request, then cached; no import at page start).
            const context = this.hostContext();
            manager = context.resourceManager;
            this.rawFileManager = manager;
          }
          if (manager === undefined) {
            answer(-1, '');
            return;
          }
          if (op === 1) {
            // Existence probe: getRawFd reads no content; closeRawFd releases the descriptor.
            try {
              await manager.getRawFd(relative);
            } catch (probeError) {
              answer((probeError as BusinessError).code === 9001005 ? -2 : -1, '');
              return;
            }
            await closeRawFd(manager, relative);
            answer(0, '');
            return;
          }
          if (typeof host !== 'undefined' && typeof host.notifyRawFileFd === 'function') {
            let info: resourceManager.RawFileDescriptor | undefined = undefined;
            try {
              info = await manager.getRawFd(relative);
            } catch {
              // No descriptor (missing rawfile, older SDK, unsupported entry): the base64
              // read below answers and reports the rc exactly as before.
              info = undefined;
            }
            if (info !== undefined) {
              let answered: boolean = false;
              try {
                if (info.length > this.rawFileMaxBytes) {
                  // Refused before any copy; the base64 path answers the same rc.
                  answer(-3, '');
                  answered = true;
                } else {
                  // 1 = the host read the descriptor and answered; 0 = it could not (it then
                  // leaves the request to the base64 fallback below).
                  answered = (host.notifyRawFileFd(requestId, info.fd, info.offset, info.length) as number) === 1;
                }
              } catch (fdReadError) {
                this.logError(`[maui] rawfile fd read failed: ${(fdReadError as Error).message}`);
              } finally {
                await closeRawFd(manager, relative);
              }
              if (answered) {
                return;
              }
            }
          }
          const bytes: Uint8Array = await manager.getRawFileContent(relative);
          if (bytes.byteLength > this.rawFileMaxBytes) {
            answer(-3, '');
            return;
          }
          answer(0, new util.Base64Helper().encodeToStringSync(bytes));
        } catch (rawFileError) {
          if ((rawFileError as BusinessError).code === 9001005) {
            // Missing rawfile: a normal answer, not a failure, so nothing is logged.
            answer(-2, '');
            return;
          }
          if (!this.rawFileErrorLogged) {
            this.rawFileErrorLogged = true;
            this.logError(`[maui] rawfile read failed: ${(rawFileError as Error).message}`);
          }
          answer(-1, '');
        }
      });
    });

    // Runtime permissions (Essentials IPermissions.RequestAsync): the managed side asks for one
    // permission through ohos_host_request_permission; the prompt runs through
    // abilityAccessCtrl (a core module, imported statically) and the answer travels back as
    // host.permissionResult(id, granted) so the managed request completes (deny on timeout).
    this.hostCall('registerPermissionSink', typeof host !== 'undefined' && typeof host.registerPermissionSink === 'function', (): void => {
      host.registerPermissionSink(async (permission: string, requestId: number): Promise<void> => {
        let granted: boolean = false;
        try {
          const context = this.hostContext();
          const permissions: Permissions[] = [permission as Permissions];
          const atManager = abilityAccessCtrl.createAtManager();
          const result = await atManager.requestPermissionsFromUser(context, permissions);
          granted = result.authResults.length > 0 && result.authResults[0] === 0;
        } catch (permissionError) {
          this.logError(`[maui] permission request failed: ${(permissionError as Error).message}`);
        }
        this.hostCall('permissionResult', typeof host !== 'undefined' && typeof host.permissionResult === 'function', (): void => {
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
    this.hostCall('registerClipboardSink', typeof host !== 'undefined' && typeof host.registerClipboardSink === 'function', (): void => {
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
          this.logError(`[maui] clipboard op ${op} failed: ${(clipboardError as Error).message}`);
        }
        this.hostCall('clipboardResult', typeof host !== 'undefined' && typeof host.clipboardResult === 'function', (): void => {
          host.clipboardResult(requestId, rc, value);
        });
      });
    });
    if (!this.clipboardObserverRegistered) {
      try {
        // The observer is stored so aboutToDisappear can unregister exactly this callback; it
        // only reports the change and never prompts (the denial is cached in the sink above).
        const clipboardObserver = (): void => {
          this.hostCall('notifyClipboardChanged', typeof host !== 'undefined' && typeof host.notifyClipboardChanged === 'function', (): void => {
            host.notifyClipboardChanged();
          });
        };
        pasteboard.getSystemPasteboard().on('update', clipboardObserver);
        this.clipboardObserver = clipboardObserver;
        this.clipboardObserverRegistered = true;
      } catch (clipboardObserverError) {
        this.logError(`[maui] clipboard observer unavailable: ${(clipboardObserverError as Error).message}`);
      }
    }

    // Geocoding (Essentials): the managed geolocation service asks through
    // ohos_host_geocode_request (op 0 address -> location, op 1 location -> address); the shell
    // runs the lazily imported @kit.LocationKit geoLocationManager (permission-aware for the reverse
    // lookup) and answers host.geocodeResult(requestId, rc, json).
    this.hostCall('registerGeocodeSink', typeof host !== 'undefined' && typeof host.registerGeocodeSink === 'function', (): void => {
      host.registerGeocodeSink(async (requestId: number, op: number, arg: string): Promise<void> => {
        await this.runGeocode(requestId, op, arg);
      });
    });

    // Notifications (H5a): this registration is a sibling of the picker sink, not nested inside
    // it - nested, it only ran after a picker request, so notification events were never
    // registered at page startup. Device-compat: the notification manager is imported lazily; a
    // missing module is cached and the publish is skipped.
    this.hostCall('registerNotificationSink', typeof host !== 'undefined' && typeof host.registerNotificationSink === 'function', (): void => {
      host.registerNotificationSink(async (notificationId: number, notificationTitle: string, notificationText: string): Promise<void> => {
        if (this.lazyUnavailable('notificationManager')) {
          return;
        }
        try {
          const nm = await import('@kit.NotificationKit');
          try {
            await nm.notificationManager.publish({
              id: notificationId,
              content: {
                notificationContentType: nm.notificationManager.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
                normal: { title: notificationTitle, text: notificationText, additionalText: '' }
              }
            });
          } catch (publishError) {
            this.logError(`notification publish failed: ${(publishError as Error).message}`);
          }
        } catch (notificationImportError) {
          this.noteLazyFailure('notificationManager', notificationImportError as Error);
        }
      });
    });

    // Notification enablement (Essentials Permissions.PostNotifications): the managed side asks
    // through ohos_host_notification_permission_request (op 0 = read the system enable state,
    // op 1 = show the system enable dialog); the shell answers with
    // host.notificationPermissionResult(requestId, granted). Device-compat: the notification
    // manager is imported lazily like the publish sink above; a missing module is cached and
    // both ops answer 0, so the managed side keeps its documented Unknown/Denied fallback.
    this.hostCall('registerNotificationPermissionSink', typeof host !== 'undefined' && typeof host.registerNotificationPermissionSink === 'function', (): void => {
      host.registerNotificationPermissionSink(async (op: number, requestId: number): Promise<void> => {
        let granted: boolean = false;
        if (!this.lazyUnavailable('notificationManager')) {
          try {
            const nm = await import('@kit.NotificationKit');
            try {
              if (op === 1) {
                const context = this.hostContext();
                await nm.notificationManager.requestEnableNotification(this.hostContext());
              }
              granted = nm.notificationManager.isNotificationEnabledSync();
            } catch (notificationPermissionError) {
              // A refused dialog (1600004) or a missing service: answer the last known state.
              // Not a lazy-module failure, so it is not cached.
              this.logError(`[maui] notification enablement ${op === 1 ? 'request' : 'check'} failed: ${(notificationPermissionError as Error).message}`);
            }
          } catch (notificationImportError) {
            // Device-compat: cache the missing module once; later requests answer granted=false
            // without re-importing or re-logging.
            this.noteLazyFailure('notificationManager', notificationImportError as Error);
          }
        }
        this.hostCall('notificationPermissionResult', typeof host !== 'undefined' && typeof host.notificationPermissionResult === 'function', (): void => {
          host.notificationPermissionResult(requestId, granted ? 1 : 0);
        });
      });
    });

    this.hostCall('registerVibrationSink', typeof host !== 'undefined' && typeof host.registerVibrationSink === 'function', (): void => {
      host.registerVibrationSink((durationMs: number) => {
      });
    });

    // SecureStorage: the managed side asks HUKS to generate/encrypt/decrypt.
    // The keystore kit is not part of this minimal shell project's dependencies/syscap yet, so
    // every request is answered with rc=-1 and the managed side uses its documented file
    // fallback. Enabling the real path means adding the universal keystore kit to the shell
    // project (see docs/plans/2026-09-18-ohos-secure-storage-huks-plan.md).
    this.hostCall('registerKeystoreSink', typeof host !== 'undefined' && typeof host.registerKeystoreSink === 'function', (): void => {
      host.registerKeystoreSink((requestId: number, op: string, alias: string, data: string) => {
        this.hostCall('notifyKeystoreResult', typeof host !== 'undefined' && typeof host.notifyKeystoreResult === 'function', (): void => {
          host.notifyKeystoreResult(requestId, -1, '');
        });
      });
    });

    // TextToSpeech (CoreSpeechKit; A2-TTS): unlike the always-on sinks above, the TTS sink is
    // registered only after probeTtsKit resolves @kit.CoreSpeechKit (see the probe); on the
    // OpenHarmony SDK the sink stays unregistered and the managed side degrades (no throw,
    // IsSupported=false) instead of being answered a fake result here.

    // Contacts (platform extra): the managed side asks through ohos_host_contacts_query. The
    // sink requires ohos.permission.READ_CONTACTS, queries the Contacts Kit
    // (@kit.ContactsKit -> contact.queryContacts) and answers with "name\tphone" lines, capped
    // at the managed limit. A missing kit or a denied permission answers code -1, which the
    // managed side reports as IsSupported == false instead of guessing. Device-compat: the
    // Contacts Kit is imported lazily; a missing kit is cached and every later request
    // answers -1 without re-importing.
    this.hostCall('registerContactsSink', typeof host !== 'undefined' && typeof host.registerContactsSink === 'function', (): void => {
      host.registerContactsSink(async (requestId: number, namePrefix: string, limit: number): Promise<void> => {
        if (this.lazyUnavailable('contactsKit')) {
          this.hostCall('notifyContactsResult', typeof host !== 'undefined' && typeof host.notifyContactsResult === 'function', (): void => {
            host.notifyContactsResult(requestId, -1, '');
          });
          return;
        }
        try {
          const kit = await import('@kit.ContactsKit');
          try {
            const context = this.hostContext();
            const permissions: Permissions[] = ['ohos.permission.READ_CONTACTS'];
            const atManager = abilityAccessCtrl.createAtManager();
            const granted = await atManager.requestPermissionsFromUser(context, permissions);
            if (granted.authResults.length === 0 || granted.authResults[0] !== 0) {
              this.hostCall('notifyContactsResult', typeof host !== 'undefined' && typeof host.notifyContactsResult === 'function', (): void => {
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
            this.hostCall('notifyContactsResult', typeof host !== 'undefined' && typeof host.notifyContactsResult === 'function', (): void => {
              host.notifyContactsResult(requestId, 0, rows.join('\n'));
            });
          } catch (contactsError) {
            this.logError(`[maui] contacts query failed: ${(contactsError as Error).message}`);
            this.hostCall('notifyContactsResult', typeof host !== 'undefined' && typeof host.notifyContactsResult === 'function', (): void => {
              host.notifyContactsResult(requestId, -1, '');
            });
          }
        } catch (contactsImportError) {
          this.noteLazyFailure('contactsKit', contactsImportError as Error);
          this.hostCall('notifyContactsResult', typeof host !== 'undefined' && typeof host.notifyContactsResult === 'function', (): void => {
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
    this.hostCall('registerCalendarSink', typeof host !== 'undefined' && typeof host.registerCalendarSink === 'function', (): void => {
      host.registerCalendarSink(async (requestId: number, op: number, arg1: string, arg2: string, arg3: string): Promise<void> => {
        if (this.lazyUnavailable('calendarKit')) {
          this.hostCall('notifyCalendarResult', typeof host !== 'undefined' && typeof host.notifyCalendarResult === 'function', (): void => {
            host.notifyCalendarResult(requestId, -1, '');
          });
          return;
        }
        try {
          const kit = await import('@kit.CalendarKit');
          try {
            const context = this.hostContext();
            const permissions: Permissions[] = op === 0
              ? ['ohos.permission.READ_CALENDAR']
              : ['ohos.permission.READ_CALENDAR', 'ohos.permission.WRITE_CALENDAR'];
            const atManager = abilityAccessCtrl.createAtManager();
            const granted = await atManager.requestPermissionsFromUser(context, permissions);
            for (let i = 0; i < granted.authResults.length; i++) {
              if (granted.authResults[i] !== 0) {
                this.hostCall('notifyCalendarResult', typeof host !== 'undefined' && typeof host.notifyCalendarResult === 'function', (): void => {
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
              this.hostCall('notifyCalendarResult', typeof host !== 'undefined' && typeof host.notifyCalendarResult === 'function', (): void => {
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
            this.hostCall('notifyCalendarResult', typeof host !== 'undefined' && typeof host.notifyCalendarResult === 'function', (): void => {
              host.notifyCalendarResult(requestId, 0, '');
            });
          } catch (calendarError) {
            this.logError(`[maui] calendar request failed: ${(calendarError as Error).message}`);
            this.hostCall('notifyCalendarResult', typeof host !== 'undefined' && typeof host.notifyCalendarResult === 'function', (): void => {
              host.notifyCalendarResult(requestId, -1, '');
            });
          }
        } catch (calendarImportError) {
          this.noteLazyFailure('calendarKit', calendarImportError as Error);
          this.hostCall('notifyCalendarResult', typeof host !== 'undefined' && typeof host.notifyCalendarResult === 'function', (): void => {
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
    this.hostCall('registerBluetoothSink', typeof host !== 'undefined' && typeof host.registerBluetoothSink === 'function', (): void => {
      host.registerBluetoothSink(async (requestId: number, op: number): Promise<void> => {
        if (this.lazyUnavailable('connectivityKit')) {
          this.hostCall('notifyBluetoothResult', typeof host !== 'undefined' && typeof host.notifyBluetoothResult === 'function', (): void => {
            host.notifyBluetoothResult(requestId, -1, '');
          });
          return;
        }
        try {
          const kit = await import('@kit.ConnectivityKit');
          try {
            const context = this.hostContext();
            const permissions: Permissions[] = ['ohos.permission.ACCESS_BLUETOOTH'];
            const atManager = abilityAccessCtrl.createAtManager();
            const granted = await atManager.requestPermissionsFromUser(context, permissions);
            if (granted.authResults.length === 0 || granted.authResults[0] !== 0) {
              this.hostCall('notifyBluetoothResult', typeof host !== 'undefined' && typeof host.notifyBluetoothResult === 'function', (): void => {
                host.notifyBluetoothResult(requestId, -1, '');
              });
              return;
            }
            const state: access.BluetoothState = kit.access.getState();
            if (op === 0) {
              this.hostCall('notifyBluetoothResult', typeof host !== 'undefined' && typeof host.notifyBluetoothResult === 'function', (): void => {
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
              this.hostCall('notifyBluetoothResult', typeof host !== 'undefined' && typeof host.notifyBluetoothResult === 'function', (): void => {
                host.notifyBluetoothResult(requestId, 0, discovered.join('\n'));
              });
              return;
            }
            if (op === 2 || op === 3) {
              // Discovery and its stop need a powered adapter; while it is off they would throw
              // 2900003. That is a transient device state, so it answers code -2 (the managed side
              // fails the call but keeps IsSupported) instead of -1 (platform unavailable).
              if (state !== kit.access.BluetoothState.STATE_ON) {
                this.hostCall('notifyBluetoothResult', typeof host !== 'undefined' && typeof host.notifyBluetoothResult === 'function', (): void => {
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
                  const findListener = (devices: Array<string>): void => {
                    for (const deviceId of devices) {
                      let name: string = '';
                      try {
                        name = kit.connection.getRemoteDeviceName(deviceId);
                      } catch {
                        name = '';
                      }
                      this.discoveredBluetooth.set(deviceId, name);
                      this.hostCall('notifyBluetoothDeviceFound', typeof host !== 'undefined' && typeof host.notifyBluetoothDeviceFound === 'function', (): void => {
                        host.notifyBluetoothDeviceFound(`${this.escapeRecordField(name)}\t${this.escapeRecordField(deviceId)}`);
                      });
                    }
                  };
                  kit.connection.on('bluetoothDeviceFind', findListener);
                  this.trackDisposer((): void => {
                    kit.connection.off('bluetoothDeviceFind', findListener);
                    this.bluetoothDeviceRegistered = false;
                  });
                  this.bluetoothDeviceRegistered = true;
                }
                kit.connection.startBluetoothDiscovery();
              } else {
                kit.connection.stopBluetoothDiscovery();
                if (this.bluetoothDeviceRegistered) {
                  try {
                    kit.connection.off('bluetoothDeviceFind');
                  } catch {
                    // Stopping discovery already succeeded; a stale listener is harmless.
                  }
                  this.bluetoothDeviceRegistered = false;
                }
              }
              this.hostCall('notifyBluetoothResult', typeof host !== 'undefined' && typeof host.notifyBluetoothResult === 'function', (): void => {
                host.notifyBluetoothResult(requestId, 0, '');
              });
              return;
            }
            // Paired devices need a powered adapter; while it is off the platform throws
            // 2900003, which is answered as a valid empty list instead of a failure.
            if (state !== kit.access.BluetoothState.STATE_ON) {
              this.hostCall('notifyBluetoothResult', typeof host !== 'undefined' && typeof host.notifyBluetoothResult === 'function', (): void => {
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
              } catch {
                name = '';
              }
              rows.push(`${this.escapeRecordField(name)}\t${this.escapeRecordField(deviceId)}`);
            }
            this.hostCall('notifyBluetoothResult', typeof host !== 'undefined' && typeof host.notifyBluetoothResult === 'function', (): void => {
              host.notifyBluetoothResult(requestId, 0, rows.join('\n'));
            });
          } catch (bluetoothError) {
            this.logError(`[maui] bluetooth request failed: ${(bluetoothError as Error).message}`);
            this.hostCall('notifyBluetoothResult', typeof host !== 'undefined' && typeof host.notifyBluetoothResult === 'function', (): void => {
              host.notifyBluetoothResult(requestId, -1, '');
            });
          }
        } catch (bluetoothImportError) {
          this.noteLazyFailure('connectivityKit', bluetoothImportError as Error);
          this.hostCall('notifyBluetoothResult', typeof host !== 'undefined' && typeof host.notifyBluetoothResult === 'function', (): void => {
            host.notifyBluetoothResult(requestId, -1, '');
          });
        }
      });
    });

    // Bluetooth GATT (platform extra): the managed side asks through
    // ohos_host_bluetooth_gatt_request with (op, '\t' separated fields) and is answered through
    // host.notifyBluetoothGattResult(requestId, code, payload). The shell requests
    // ACCESS_BLUETOOTH per call, runs ble.createGattClientDevice operations and pushes value/
    // state/MTU changes through host.notifyBluetoothGattEvent. Device-compat: the Connectivity
    // Kit is imported lazily by runBluetoothGatt; a missing kit is cached and answers -1.
    this.hostCall('registerBluetoothGattSink', typeof host !== 'undefined' && typeof host.registerBluetoothGattSink === 'function', (): void => {
      host.registerBluetoothGattSink(async (requestId: number, op: number, payload: string): Promise<void> => {
        if (this.lazyUnavailable('connectivityKit')) {
          this.answerBluetoothGatt(requestId, -1, '');
          return;
        }
        let code: number = -1;
        let answer: string = '';
        try {
          const result: BluetoothGattAnswer = await this.runBluetoothGatt(op, payload);
          code = result.code;
          answer = result.payload;
        } catch (gattImportError) {
          this.noteLazyFailure('connectivityKit', gattImportError as Error);
        }
        this.answerBluetoothGatt(requestId, code, answer);
      });
    });

    // Printing (platform extra): the managed side asks through ohos_host_print_file with an
    // absolute path to a PDF/image it rendered (PrintTextAsync writes <cacheDir>/<job>.pdf).
    // ohos.permission.PRINT is system_grant, so there is no runtime prompt: a packaged app
    // that declares it can print. print.print resolves once the system print UI accepted the
    // job; the final page outcome belongs to the print service, so code 0 means "accepted".
    // Device-compat: the print module is imported lazily; a missing module is cached and
    // answers -1.
    this.hostCall('registerPrintSink', typeof host !== 'undefined' && typeof host.registerPrintSink === 'function', (): void => {
      host.registerPrintSink(async (requestId: number, path: string): Promise<void> => {
        if (this.lazyUnavailable('print')) {
          this.hostCall('notifyPrintResult', typeof host !== 'undefined' && typeof host.notifyPrintResult === 'function', (): void => {
            host.notifyPrintResult(requestId, -1, '');
          });
          return;
        }
        if (!canIUse('SystemCapability.Print.PrintFramework')) {
          // Entry probe (audit ARKTS-S2): a device without the print framework answers
          // unavailable before the module is imported, matching the syscap-declared capability.
          this.logWarn('print unavailable: the device reports no PrintFramework syscap');
          this.hostCall('notifyPrintResult', typeof host !== 'undefined' && typeof host.notifyPrintResult === 'function', (): void => {
            host.notifyPrintResult(requestId, -1, '');
          });
          return;
        }
        try {
          const printer = await import('@kit.BasicServicesKit');
          try {
            const context = this.hostContext();
            const task: print.PrintTask = await printer.print.print([path], context);
            task.on('fail', (): void => {
              this.logError('[maui] print task reported failure');
            });
            task.on('cancel', (): void => {
              this.logInfo('[maui] print task cancelled');
            });
            this.hostCall('notifyPrintResult', typeof host !== 'undefined' && typeof host.notifyPrintResult === 'function', (): void => {
              host.notifyPrintResult(requestId, 0, '');
            });
          } catch (printError) {
            this.logError(`[maui] print request failed: ${(printError as Error).message}`);
            this.hostCall('notifyPrintResult', typeof host !== 'undefined' && typeof host.notifyPrintResult === 'function', (): void => {
              host.notifyPrintResult(requestId, -1, (printError as Error).message);
            });
          }
        } catch (printImportError) {
          this.noteLazyFailure('print', printImportError as Error);
          this.hostCall('notifyPrintResult', typeof host !== 'undefined' && typeof host.notifyPrintResult === 'function', (): void => {
            host.notifyPrintResult(requestId, -1, '');
          });
        }
      });
    });

    // Media playback (platform extra): the managed side asks through ohos_host_media_request
    // with (op, '\t' separated fields) and is answered through host.notifyMediaResult(
    // requestId, code, payload); the shell drives one AVPlayer and pushes state/time/duration/
    // error records through host.notifyMediaEvent. Device-compat: the Media Kit is imported
    // lazily inside runMedia; a missing kit is cached and answers -1.
    this.hostCall('registerMediaSink', typeof host !== 'undefined' && typeof host.registerMediaSink === 'function', (): void => {
      host.registerMediaSink(async (requestId: number, op: number, payload: string): Promise<void> => {
        this.logInfo(`[maui] media request op=${op} request=${requestId}${payload.length > 0 ? ` payload=${payload}` : ''}`);
        if (this.lazyUnavailable('mediaKit')) {
          this.answerMedia(requestId, -1, '');
          return;
        }
        let answer: MediaAnswer = { code: -1, payload: '' };
        try {
          answer = await this.mediaEnqueue(op, payload);
        } catch (mediaImportError) {
          this.noteLazyFailure('mediaKit', mediaImportError as Error);
        }
        this.answerMedia(requestId, answer.code, answer.payload);
      });
      this.logInfo('[maui] media sink registered');
      // Self-test (temporary device probe): write a short WAV into the cache dir and drive the
      // same runMedia path the managed bridge uses (load -> play -> status), so the AVPlayer
      // sink is exercised on-device independently of the managed side.
      setTimeout((): void => {
        try {
          this.mediaSelfTest();
        } catch (selfTestError) {
          this.logWarn(`[maui] media self-test threw: ${(selfTestError as Error).message}`);
        }
      }, 3000);
    });

    // Device diagnostics (W9D): mirror the managed status file's tail to hilog once at startup,
    // so the managed app is observable on images whose host hilog bridge is missing (the file
    // itself is 0600 in the ability's files dir, unreadable for the hdc shell).
    this.hostCall('statusMirror', true, (): void => {
      setTimeout((): void => {
        try {
          const statusPath: string = `${this.hostContext().filesDir}/dotnet-status.txt`;
          if (!fs.accessSync(statusPath)) {
            this.logInfo('[managed] dotnet-status.txt not present');
            return;
          }
          const lines: string[] = fs.readTextSync(statusPath).split('\n');
          const meaningful: string[] = [];
          for (const line of lines) {
            if (line.length > 0 && !line.includes('OHOS_DOTNET probe:')) {
              meaningful.push(line);
            }
          }
          this.logInfo(`[managed] dotnet-status.txt lines=${lines.length} meaningful=${meaningful.length}`);
          const from: number = Math.max(0, meaningful.length - 120);
          for (let i = from; i < meaningful.length; i++) {
            this.logInfo(`[managed] ${meaningful[i]}`);
          }
        } catch (statusError) {
          this.logWarn(`[maui] managed status mirror failed: ${(statusError as Error).message}`);
        }
      }, 9000);
    });

    // Launcher/Browser/Share: managed requests arrive through ohos_host_ability_start /
    // ohos_host_ability_start_ex. kind 0 opens a uri (implicit viewData Want), kind 1 shares
    // plain text (implicit sendData Want), kind 2 is the availability probe (never launches),
    // kind 3 shares a file (implicit sendData Want with uri + MIME type), kind 4 starts an
    // explicit Want (uri = bundle name, text = ability name; used by IAppInfo.ShowSettingsUI).
    // The UIAbilityContext owns the actual startAbility call; a rejected launch is logged, and
    // only the dispatch status (true when the request was handed to the system) is reported
    // back to the managed side.
    // Plain text has no wantConstant key in this SDK (Share Kit/systemShare is not part of it),
    // so the text travels under 'ohos.extra.param.key.content', the key used by the
    // pre-Share-Kit samples for ohos.want.action.sendData.
    // Title: the managed side passes ShareTextRequest.Title/Subject and ShareFileRequest.Title
    // as the fifth/fourth sink argument; it travels under
    // wantConstant.Params.CONTENT_TITLE_KEY ('ohos.extra.param.key.contentTitle'), which this
    // SDK declares in @kit.AbilityKit wantConstant. The key is only set when non-empty; a
    // receiver that ignores it simply shows its own title.
    // Read grant: wantConstant.Flags.FLAG_AUTH_READ_URI_PERMISSION (0x1) asks the ability manager
    // to grant the receiver read access to the file:// uri. Kind 3 always sets it, and kind 0
    // sets it for a file:// uri (the managed launcher's OpenFileRequest path) so opening a
    // sandbox file can reach its receiver too. Whether the target app can actually read the
    // sandbox file depends on that app and is not verifiable from this shell.
    // Kind 4 carries the well-known OpenHarmony settings bundle (com.ohos.settings /
    // com.ohos.settings.MainAbility) and falls back to the implicit 'ohos.settings' action when
    // the explicit Want does not resolve, so devices whose settings app uses another bundle id
    // still have a chance to open it.
    this.hostCall('registerAbilitySink', typeof host !== 'undefined' && typeof host.registerAbilitySink === 'function', (): void => {
      host.registerAbilitySink((kind: number, uri: string, text: string, title: string): boolean => {
        try {
          const context = this.hostContext();
          if (kind === 2) {
            return context !== undefined && context !== null;
          }
          if (kind === 4) {
            const explicitWant: Want = new Want();
            explicitWant.bundleName = uri;
            explicitWant.abilityName = text;
            context.startAbility(explicitWant).then((): void => {
              this.logInfo('[maui] settings ability start dispatched (explicit)');
            }).catch((explicitError: Error): void => {
              const implicitWant: Want = new Want();
              implicitWant.action = 'ohos.settings';
              context.startAbility(implicitWant).then((): void => {
                this.logInfo('[maui] settings ability start dispatched (implicit)');
              }).catch((implicitError: Error): void => {
                this.logError(`[maui] settings ability start failed: explicit=${explicitError.message} implicit=${implicitError.message}`);
              });
            });
            return true;
          }
          const want: Want = new Want();
          if (kind === 1) {
            want.action = 'ohos.want.action.sendData';
            want.type = 'text/plain';
            want.parameters = { 'ohos.extra.param.key.content': text };
            if (title.length > 0) {
              want.parameters[wantConstant.Params.CONTENT_TITLE_KEY] = title;
            }
          } else if (kind === 3) {
            // File share: uri = file:// URI (built by the managed side), text = MIME type.
            want.action = 'ohos.want.action.sendData';
            want.uri = uri;
            want.type = text;
            want.flags = wantConstant.Flags.FLAG_AUTH_READ_URI_PERMISSION;
            if (title.length > 0) {
              want.parameters = { 'ohos.extra.param.key.contentTitle': title };
            }
          } else {
            want.action = 'ohos.want.action.viewData';
            want.uri = uri;
            // Opening a sandbox file: the receiver needs the read grant for the file:// uri.
            if (uri.startsWith('file://')) {
              want.flags = wantConstant.Flags.FLAG_AUTH_READ_URI_PERMISSION;
            }
            if (title.length > 0) {
              want.parameters = { 'ohos.extra.param.key.contentTitle': title };
            }
          }
          context.startAbility(want).then((): void => {
            this.logInfo(`[maui] ability start dispatched: kind=${kind}`);
          }).catch((startError: Error): void => {
            this.logError(`[maui] ability start failed: kind=${kind} ${startError.message}`);
          });
          return true;
        } catch (startError) {
          this.logError(`[maui] ability start threw: ${(startError as Error).message}`);
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
    this.hostCall('registerFlashlightSink', typeof host !== 'undefined' && typeof host.registerFlashlightSink === 'function', (): void => {
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
          this.logError(`[maui] flashlight request failed: ${(flashlightError as Error).message}`);
          this.flashlightManager = undefined;
          return false;
        }
      });
    });

    // Focus (managed VisualElement.Focus/Unfocus on the text handlers): the managed side names
    // an ArkUI id through ohos_host_request_focus; this sink hands it focus. The text-input
    // sink below keeps focusing the input as the keyboard fallback path (an older host library
    // without the focus export still focuses when it drives the keyboard through the shell).
    this.hostCall('registerFocusSink', typeof host !== 'undefined' && typeof host.registerFocusSink === 'function', (): void => {
      host.registerFocusSink((id: string): boolean => {
        try {
          const target: string = id.length > 0 ? id : 'ohos_dotnet_surface';
          this.getUIContext().getFocusController().requestFocus(target);
          return true;
        } catch (focusError) {
          this.logError(`[maui] focus request failed: ${(focusError as Error).message}`);
          return false;
        }
      });
    });

    // The managed Entry asks for the soft keyboard through this sink. The caret from the
    // managed editor (host.setKeyboardCaret -> the sink post's second argument) is applied to
    // the input control so IME composition and typing use the managed cursor offset.
    this.hostCall('registerTextInputSink', typeof host !== 'undefined' && typeof host.registerTextInputSink === 'function', (): void => {
      host.registerTextInputSink((show: number, caret: number) => {
        if (show === 1) {
          this.controller.caretPosition(caret >= 0 ? caret : 0);
          this.getUIContext().getFocusController().requestFocus('ohos_dotnet_input');
        } else {
          this.getUIContext().getFocusController().requestFocus('ohos_dotnet_surface');
        }
      });
    });

    // Menus: pull the initial table, then refresh on every commit from the managed side.
    // A host library without the menu exports degrades to no menu instead of failing the page.
    this.hostCall('registerMenuChangedSink', typeof host !== 'undefined' && typeof host.registerMenuChangedSink === 'function', (): void => {
      host.registerMenuChangedSink((count: number): void => {
        this.logInfo(`[maui] menu table changed: ${count} rows`);
        this.pullMenu();
      });
    });
    this.pullMenu();

    // HMS Kit feature probes (Share/Scan/Push/Account/Map/LiveView/CoreSpeech): the sinks
    // register only after the kit resolves, so a device without the kit keeps the managed
    // side's documented degradation (see the probes).
    this.probeShareKit();
    this.probeScanKit();
    this.probePushKit();
    this.probeAccountKit();
    this.probeMapKit();
    this.probeLiveViewKit();
    this.probeTtsKit();
    this.probeAnimationReduce();
  }

  // Picker result framing (managed OpenHarmonyPickerClient.Complete): a cancel/unavailable
  // answer is rc=-1, each picked file is one rc=0 callback, and a multi pick ends with rc=1.
  // The callbacks are delivered in order, so the managed accumulator completes on the marker.
  private answerPickerCancel(requestId: number): void {
    this.hostCall('notifyPickerResult', typeof host !== 'undefined' && typeof host.notifyPickerResult === 'function', (): void => {
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
        this.logError(`[maui] picker read failed: ${(readError as Error).message}`);
        encoded = '';
      }
      this.hostCall('notifyPickerResult', typeof host !== 'undefined' && typeof host.notifyPickerResult === 'function', (): void => {
        host.notifyPickerResult(requestId, 0, name, encoded);
      });
    }
    if (multi) {
      this.hostCall('notifyPickerResult', typeof host !== 'undefined' && typeof host.notifyPickerResult === 'function', (): void => {
        host.notifyPickerResult(requestId, 1, '', '');
      });
    }
  }

  // Documents: the pre-existing DocumentViewPicker path, extended with the caller-provided
  // maxSelectNumber (1 for every single-select request, so those keep their exact behaviour).
  private async selectDocumentUris(requestId: number, multi: boolean, count: number): Promise<void> {
    try {
      const documentPicker = new picker.DocumentViewPicker(this.hostContext());
      const uris = await documentPicker.select({ maxSelectNumber: count });
      if (!uris || uris.length === 0) {
        this.answerPickerCancel(requestId);
        return;
      }
      this.answerPickerFiles(requestId, multi, uris);
    } catch (error) {
      this.logError(`[maui] document picker failed: ${(error as Error).message}`);
      this.answerPickerCancel(requestId);
    }
  }

  // WebView file selection (matrix #11): <input type=file> in an ArkWeb page. The document
  // picker answers the page's request directly (no managed picker request id): multiple URIs
  // for a multi-select page, one otherwise, an empty list on cancel/failure.
  private async selectWebFileUris(multiple: boolean): Promise<string[]> {
    try {
      const documentPicker = new picker.DocumentViewPicker(this.hostContext());
      const uris = await documentPicker.select({ maxSelectNumber: multiple ? 100 : 1 });
      return uris && uris.length > 0 ? uris : [];
    } catch (documentError) {
      this.logError(`[maui] web file selection failed: ${(documentError as Error).message}`);
      return [];
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
      const photoAccess = await import('@kit.MediaLibraryKit');
      try {
        const selectOptions = new photoAccess.photoAccessHelper.PhotoSelectOptions();
        selectOptions.MIMEType = mode === 1
          ? photoAccess.photoAccessHelper.PhotoViewMIMETypes.IMAGE_TYPE
          : photoAccess.photoAccessHelper.PhotoViewMIMETypes.VIDEO_TYPE;
        selectOptions.maxSelectNumber = count;
        const photoPicker = new photoAccess.photoAccessHelper.PhotoViewPicker();
        const picked = await photoPicker.select(selectOptions);
        const uris: string[] = picked.photoUris;
        return uris ? uris : [];
      } catch (pickError) {
        this.logError(`[maui] photo picker failed: ${(pickError as Error).message}`);
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
      if (typeof host !== 'undefined' && typeof host.setAppContext !== 'function') {
        return;
      }
      // A host that never loaded (the NAPI import failed) leaves the default export
      // undefined: report it through the same once-per-page unavailable set instead of
      // letting the call below throw and log a misleading "publish failed".
      if (typeof host === 'undefined') {
        this.reportHostUnavailable('setAppContext', undefined);
        return;
      }
      const context = this.hostContext();
      const json = JSON.stringify({
        appDir: this.resolvePayloadDir(context),
        filesDir: context.filesDir,
        cacheDir: context.cacheDir,
        bundleName: context.abilityInfo.bundleName,
        abilityName: context.abilityInfo.name,
        nodeContent: 0,
      });
      const rc: number = host.setAppContext(json) as number;
      if (rc !== 0) {
        this.logError(`[maui] app context publish declined: ${rc}`);
      }
    } catch (contextError) {
      this.logError(`[maui] app context publish failed: ${(contextError as Error).message}`);
    }
  }

  // The payload directory the managed app was started from. EntryAbility prefers the staged
  // bundle payload (payload-in-libs: `libs/<abi>/.dotnet-payload.json` next to the app or its
  // AOT library) and only falls back to the extracted `<filesDir>/dotnet` tree. Publishing
  // `<filesDir>/dotnet` unconditionally (the pre-MULTI-OVERLAY-FULL behaviour) replaced a
  // valid in-libs context after the surface came up, so a web handler that registered later
  // served from the extracted tree: on an AOT hap that tree may not exist or may be stale, and
  // the third web control (or a restored handler) showed "Not Found" instead of its page.
  private resolvePayloadDir(context: common.UIAbilityContext): string {
    const fallback: string = `${context.filesDir}/dotnet`;
    try {
      const bundleCodeDir: string = context.bundleCodeDir;
      if (bundleCodeDir.length === 0) {
        return fallback;
      }
      const moduleName: string = context.abilityInfo.moduleName;
      const roots: string[] = moduleName.length > 0
        ? [`${bundleCodeDir}/${moduleName}/libs`, `${bundleCodeDir}/libs`]
        : [`${bundleCodeDir}/libs`];
      const abis: string[] = ['arm64-v8a', 'arm64'];
      for (const root of roots) {
        for (const abi of abis) {
          const dir: string = `${root}/${abi}`;
          try {
            if (fs.accessSync(dir) && fs.accessSync(`${dir}/.dotnet-payload.json`)) {
              return dir;
            }
          } catch {
            // An unreadable candidate is not a staged payload; keep probing.
          }
        }
      }
    } catch {
      // Fall through to the extracted payload.
    }
    return fallback;
  }

  // Accessibility: host.setNodeContent hands this.content to the native host, which creates
  // the CUSTOM node and calls OH_ArkUI_NodeContent_AddNode on it. The ContentSlot that hosts
  // the NodeContent only exists once build() has mounted the page, so attaching it in
  // aboutToAppear ran before the container was there and left the node unattached (host
  // status 3). onPageShow runs after the page (and its ContentSlot) is mounted; the host
  // caches the created node, so a repeated page show cannot attach it twice.
  onPageShow(): void {
    this.hostCall('setNodeContent', typeof host !== 'undefined' && typeof host.setNodeContent === 'function', (): void => {
      host.setNodeContent(this.content);
    });
  }

  // System Back: the platform consumes the key before the XComponent's onKeyEvent sees it, so a
  // presented drawer could not be closed (the window simply backgrounded; FIX-DISMISS device
  // note). onBackPress runs on the page and forwards through host.backPressed ->
  // ohos_host_register_back_pressed; the managed slice's drawer handlers answer true (consumed)
  // and the page returns true so the system does not background the app. With no drawer open -
  // or on a host library without the export - the result is false and the platform default runs.
  onBackPress(): boolean {
    let handled: boolean = false;
    this.hostCall('backPressed', typeof host !== 'undefined' && typeof host.backPressed === 'function', (): void => {
      handled = host.backPressed() === true;
    });
    return handled;
  }

  // Clipboard (Essentials): the pasteboard 'update' observer is registered on the page's
  // context and would outlive the page, so it is unregistered with the exact stored callback
  // when the page disappears; a later page registers again. The Bluetooth GATT clients (platform
  // extra) are closed for the same reason: their kit listeners are bound to this page instance.
  // The soft-input avoid-area listener is window-scoped and is unregistered the same way.
  aboutToDisappear(): void {
    // Map overlay (R2-3): release the MapComponent/BuilderNode with the page so the kit's map
    // view and its listeners do not outlive it (the proxy also drops late callbacks).
    this.destroyMapOverlay();
    // MULTIWINDOW-M: the child window is page-scoped; destroy it with the page.
    this.destroySubWindowForPage();
    // Callback deregistration ledger first: the kit listeners (display, battery events,
    // connectivity, bluetooth discovery) must not outlive the page.
    this.runDisposers();
    if (this.softInputRegistered && this.softInputWindow !== null && this.softInputListener !== null) {
      try {
        this.softInputWindow.off('avoidAreaChange', this.softInputListener);
      } catch (softInputOffError) {
        this.logError(`[maui] soft input observer unregister failed: ${(softInputOffError as Error).message}`);
      }
      this.softInputRegistered = false;
      this.softInputWindow = null;
      this.softInputListener = null;
    }
    if (this.clipboardObserverRegistered && this.clipboardObserver !== null) {
      try {
        pasteboard.getSystemPasteboard().off('update', this.clipboardObserver);
      } catch (clipboardOffError) {
        this.logError(`[maui] clipboard observer unregister failed: ${(clipboardOffError as Error).message}`);
      }
      this.clipboardObserverRegistered = false;
      this.clipboardObserver = null;
    }
    this.gattClients.forEach((client: ble.GattClientDevice, address: string): void => {
      try {
        client.close();
      } catch (gattCloseError) {
        this.logError(`[maui] bluetooth gatt close failed for ${address}: ${(gattCloseError as Error).message}`);
      }
    });
    this.gattClients.clear();
    this.gattConnectWaiters.clear();
    this.gattMtuWaiters.clear();
    this.gattStates.clear();
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
    } catch {
      statusText = 'unavailable (the host does not export accessibilityStatus)';
    }
    let message: string = `accessibilityStatus: ${statusText}`;
    try {
      // Optional export: only newer host libraries publish it, so it is read behind a
      // runtime typeof check and simply omitted when the library has no such export.
      if (typeof host !== 'undefined' && typeof host.accessibilityNodeCount === 'function') {
        message += `\naccessibilityNodeCount: ${host.accessibilityNodeCount() as number}`;
      }
    } catch {
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
  // the MAUI hybrid origin, whose requests onInterceptRequest answers from the payload. The
  // registration state is per overlay slot (MULTI-OVERLAY-FULL): two HybridWebViews on the same
  // page each keep their own base/root/defaultFile/document id, so the same origin URL serves
  // each one's document on its own overlay.
  private registerHybridAssets(arg: string): void {
    try {
      const config = JSON.parse(arg) as HybridAssetsConfig;
      const hybridSlot: number = config.slot !== undefined && config.slot >= 0 && config.slot < WEB_SLOT_MAX ? config.slot : 0;
      this.hybridBase[hybridSlot] = config.base;
      this.hybridRoot[hybridSlot] = config.root;
      this.hybridDefaultFile[hybridSlot] = config.defaultFile;
      this.hybridDocId[hybridSlot] = config.id !== undefined && config.id.length > 0 ? config.id : '';
      const safeLayout: boolean = this.isSafeLayoutPart(this.hybridRoot[hybridSlot])
        && this.isSafeLayoutPart(this.hybridDefaultFile[hybridSlot]);
      if (!safeLayout) {
        this.logError('[maui] hybrid assets registration rejected: root/defaultFile are not safe relative paths');
      }
      this.hybridRegistered[hybridSlot] = safeLayout && this.hybridBase[hybridSlot].length > 0
        && this.hybridRoot[hybridSlot].length > 0 && this.hybridDefaultFile[hybridSlot].length > 0;
      if (this.hybridRegistered[hybridSlot]) {
        this.hybridServeLogs[hybridSlot] = 0;
        this.logInfo(`[maui] hybrid assets: origin=${this.hybridOrigin} root=${this.hybridRoot[hybridSlot]} base=${this.hybridBase[hybridSlot]} slot=${hybridSlot}`);
        this.webVisible[hybridSlot] = !this.webSuspended;
        this.noteWebActivation(hybridSlot);
        this.slotController(hybridSlot).loadUrl(this.hybridOrigin);
      }
    } catch (hybridError) {
      this.logError(`[maui] hybrid assets registration failed: ${(hybridError as Error).message}`);
      for (let hybridResetSlot = 0; hybridResetSlot < WEB_SLOT_MAX; hybridResetSlot++) {
        this.hybridRegistered[hybridResetSlot] = false;
      }
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
      // B2: a WASM site registration serves the same layout but must not run the hybrid
      // bootstrap (the site ships its own blazor.webassembly*.js), and it does not load the
      // origin: a WebView whose Source is this origin drives the load.
      this.blazorWasmMode = config.mode === 'wasm';
      this.blazorServeLogs = 0;
      const safeLayout: boolean = this.isSafeLayoutPart(this.blazorRoot)
        && this.isSafeLayoutPart(this.blazorDefaultFile);
      if (!safeLayout) {
        this.logError('[maui] blazor assets registration rejected: root/defaultFile are not safe relative paths');
      }
      this.blazorRegistered = safeLayout && this.blazorBase.length > 0 && this.blazorRoot.length > 0
        && this.blazorDefaultFile.length > 0;
      if (this.blazorRegistered) {
        // MULTI-OVL: the registration names the overlay it belongs to; absent/-1 lands on the
        // first overlay (a WebView-driven WASM site or a legacy handler).
        const blazorSlot: number = config.slot !== undefined && config.slot >= 0 && config.slot < WEB_SLOT_MAX ? config.slot : 0;
        this.logInfo(`[maui] blazor assets: origin=${this.blazorOrigin} root=${this.blazorRoot} base=${this.blazorBase} mode=${this.blazorWasmMode ? 'wasm' : 'hybrid'} slot=${blazorSlot}`);
        if (!this.blazorWasmMode) {
          // MULTI-OVL replaces the single-overlay arbitration (FIX-WVP): the Blazor page loads
          // on its own overlay even while a HybridWebView owns another one. Activation order
          // (z-order) follows the newly loaded page.
          this.webVisible[blazorSlot] = !this.webSuspended;
          this.noteWebActivation(blazorSlot);
          this.slotController(blazorSlot).loadUrl(this.blazorOrigin);
        }
      }
    } catch (blazorError) {
      this.logError(`[maui] blazor assets registration failed: ${(blazorError as Error).message}`);
      this.blazorRegistered = false;
    }
  }

  // Resolves an app-origin URL to an absolute file below the payload directory. Unknown and
  // malformed paths (including traversal attempts) resolve to '' and are answered with 404.
  // MULTI-OVERLAY-FULL: the layout (base/root/defaultFile) is read from the requesting overlay's
  // own registration, so two HybridWebViews on the same origin serve their own documents.
  private hybridFilePath(url: string, slot: number): string {
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
    } catch {
      return '';
    }
    while (path.startsWith('/')) {
      path = path.substring(1);
    }
    if (path.indexOf('..') >= 0 || path.indexOf('\\') >= 0) {
      return '';
    }
    if (path.length === 0) {
      path = this.hybridDefaultFile[slot];
    }
    if (path === '_framework/hybridwebview.js') {
      return `${this.hybridBase[slot]}/${path}`;
    }
    return `${this.hybridBase[slot]}/${this.hybridRoot[slot]}/${path}`;
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
    } catch {
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
  // fingerprinted names (stem.<10 lowercase alnum chars>.ext) while the extracted payload
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
    // .NET static web asset fingerprints are 10 lowercase alphanumerics (observed:
    // dotnet.s704ca7iy0.js) - NOT hex, so [0-9a-f] would never strip a real fingerprint.
    const match = new RegExp('^(.+)\\.[0-9a-z]{10}$').exec(stem);
    if (match === null) {
      return filePath;
    }
    return `${filePath.substring(0, nameStart)}${match[1]}${extension}`;
  }

  // Fingerprint lookup in the base-name direction (W10): .NET static web assets are published
  // only under their fingerprinted names while the Blazor boot script still requests the base
  // name (`_framework/dotnet.js` next to `dotnet.<fingerprint>.js`). A static host has to
  // perform the mapping the ASP.NET Core static file middleware normally does: when the
  // requested exact file is missing and the parent directory carries
  // `<stem>.<10 lowercase alnum><extension>`, that file is served. Returns undefined when no
  // match exists.
  private staticFingerprintFile(filePath: string): string | undefined {
    const slash: number = filePath.lastIndexOf('/');
    const nameStart: number = slash + 1;
    const dot: number = filePath.lastIndexOf('.');
    if (dot <= nameStart) {
      return undefined;
    }
    const stem: string = filePath.substring(nameStart, dot);
    const extension: string = filePath.substring(dot);
    const directory: string = slash > 0 ? filePath.substring(0, slash) : '/';
    try {
      const names: string[] = fs.listFileSync(directory);
      const prefix: string = `${stem}.`;
      for (const name of names) {
        if (!name.startsWith(prefix) || !name.endsWith(extension)) {
          continue;
        }
        const hash: string = name.substring(prefix.length, name.length - extension.length);
        if (hash.length !== 10) {
          continue;
        }
        let alnum: boolean = true;
        for (let i = 0; i < hash.length; i++) {
          const c: number = hash.charCodeAt(i);
          if ((c < 0x30 || c > 0x39) && (c < 0x61 || c > 0x7a)) {
            alnum = false;
            break;
          }
        }
        if (alnum) {
          return `${directory}/${name}`;
        }
      }
    } catch {
      // A missing directory or a listing failure is not a readable file.
    }
    return undefined;
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
      const stat = fs.statSync(filePath);
      if (!stat.isFile()) {
        return undefined;
      }
      const file = fs.openSync(filePath, fs.OpenMode.READ_ONLY);
      fd = file.fd;
      const buffer = new ArrayBuffer(stat.size);
      fs.readSync(fd, buffer);
      const response: WebResourceResponse = new WebResourceResponse();
      response.setResponseCode(200);
      response.setResponseMimeType(this.hybridMimeType(filePath));
      response.setResponseEncoding('utf-8');
      response.setResponseData(buffer);
      response.setResponseHeader(this.payloadCacheHeaders(fingerprinted));
      return response;
    } catch (readError) {
      // W10 serve diagnostics: the first intercepted reads log their failure so a device run
      // shows why a registered payload file is answered 404 (path typo vs access vs missing).
      if (this.blazorServeLogs <= 4) {
        this.logWarn(`[maui] payload read failed: ${filePath}: ${(readError as Error).message}`);
      }
      return undefined;
    } finally {
      if (fd >= 0) {
        try {
          fs.closeSync(fd);
        } catch {
          // The handle is released with the response in the worst case.
        }
      }
    }
  }

  // ArkWeb needs the intercepted response synchronously, and payload assets are small, so the
  // file is read inline through @kit.CoreFileKit fileIo (open/read/close). '' (an unknown or unsafe path)
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
    } else {
      // Base name requested, fingerprinted file published (W10: the Blazor boot script imports
      // `_framework/dotnet.js` while the publish carries `dotnet.<hash>.js`).
      const resolved: string | undefined = this.staticFingerprintFile(filePath);
      if (resolved !== undefined) {
        const mapped: WebResourceResponse | undefined = this.readPayloadFile(resolved, true);
        if (mapped !== undefined) {
          return mapped;
        }
      }
    }
    return this.hybridErrorResponse(404);
  }

  // HybridWebView assets live under the requesting slot's own <base>/<root> registration.
  private serveHybridFile(url: string, slot: number): WebResourceResponse {
    return this.servePayloadFile(this.hybridFilePath(url, slot));
  }

  // BlazorWebView assets live under <base>/<root> only.
  private serveBlazorFile(url: string): WebResourceResponse {
    return this.servePayloadFile(this.blazorFilePath(url));
  }

  // MULTI-OVERLAY-FULL: the hybrid __hwv endpoints are POSTed with fetch by the served
  // document (the stock hybridwebview.js transport). CEF reports such a fetch as a non-main-
  // frame resource request, so the old isMainFrame() guard rejected the legitimate transport
  // with 400. Device evidence: the fetch carries "Origin: <hybridOrigin>" and
  // "Sec-Fetch-Site: same-origin" (no Referer). The request is accepted when it is the main
  // frame itself, when its Origin is this hybrid origin (cross-site iframes carry their own
  // Origin and stay refused) or when a Referer on this hybrid origin identifies the document.
  private hybridEndpointAllowed(event: OnInterceptRequestEvent): boolean {
    if (!event.request || typeof event.request.isMainFrame !== 'function') {
      return true;
    }
    try {
      if (event.request.isMainFrame()) {
        return true;
      }
      let origin: string = '';
      let referer: string = '';
      let fetchSite: string = '';
      const headers = event.request.getRequestHeader();
      for (let i = 0; i < headers.length; i++) {
        const name: string = headers[i].headerKey.toLowerCase();
        if (name === 'origin') {
          origin = headers[i].headerValue;
        } else if (name === 'referer') {
          referer = headers[i].headerValue;
        } else if (name === 'sec-fetch-site') {
          fetchSite = headers[i].headerValue;
        }
      }
      const originName: string = this.hybridOrigin.endsWith('/')
        ? this.hybridOrigin.substring(0, this.hybridOrigin.length - 1)
        : this.hybridOrigin;
      if (origin === originName && (fetchSite.length === 0 || fetchSite === 'same-origin')) {
        return true;
      }
      return referer.startsWith(this.hybridOrigin);
    } catch {
      return false;
    }
  }

  // Bounded diagnostic for a refused hybrid endpoint request (the first few only).
  private logHybridEndpointRejection(endpoint: string, event: OnInterceptRequestEvent): void {
    if (this.hybridEndpointLogs >= 3) {
      return;
    }
    this.hybridEndpointLogs++;
    let mainFrame: boolean = false;
    let headerNames: string = '';
    try {
      mainFrame = typeof event.request.isMainFrame === 'function' ? event.request.isMainFrame() : false;
      const headers = event.request.getRequestHeader();
      for (let i = 0; i < headers.length; i++) {
        headerNames += `${headers[i].headerKey}=${headers[i].headerValue.substring(0, 64)};`;
      }
    } catch {
      headerNames = '<unreadable>';
    }
    this.logError(`[maui] hybrid ${endpoint} request refused: mainFrame=${mainFrame} headers=${headerNames}`);
  }

  // JS -> .NET channel of the served hybridwebview.js: the script POSTs its payload in the
  // X-Maui-Request-Body header (the same transport Android uses). The body is handed to the
  // existing JS message sink, so __RawMessage / __InvokeJavaScript* records reach the managed
  // HybridWebView handler. MULTI-OVERLAY-FULL: the intercept runs inside the requesting
  // overlay's webOverlay(slot) builder, so the slot stamps the envelope and the message reaches
  // that overlay's own document registration. The matching __hwvInvokeDotNet endpoint is
  // hybridInvokeResponse.
  private hybridMessageResponse(event: OnInterceptRequestEvent, slot: number): WebResourceResponse {
    // The endpoint belongs to the served hybrid document; a request from another frame
    // (ArkWeb intercepts iframe requests too) is refused like a malformed one (400), so the
    // page's fetch rejects cleanly instead of waiting. A same-origin fetch is the document's
    // own transport (see hybridEndpointAllowed).
    if (!this.hybridEndpointAllowed(event)) {
      this.logHybridEndpointRejection('message', event);
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
    const delivered: boolean = this.hostCall('notifyJsMessage', typeof host !== 'undefined' && typeof host.notifyJsMessage === 'function', (): void => {
      host.notifyJsMessage(this.originEnvelope(body, slot));
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
        this.logError(`[maui] hybrid invoke response failed: ${(completeError as Error).message}`);
      }
    });
  }

  // JS -> .NET invocation endpoint: hybridwebview.js POSTs
  // { MethodName, ParamValues } to <origin>/__hwvInvokeDotNet. The intercepted response is
  // returned not-ready (setResponseIsReady(false)), the invocation is handed to the managed
  // handler through host.notifyHybridInvoke, and completeHybridInvoke answers it. Every
  // failure path (bad request, missing host export, managed error, timeout) completes the
  // response with an error payload, so the page's promise rejects instead of hanging.
  // MULTI-OVERLAY-FULL: the request id carries the requesting overlay's slot
  // (((slot + 1) << 24) | sequence, mirroring OpenHarmonyOverlays.EncodeInvokeRequestId), so
  // the managed side dispatches to the HybridWebView that owns that slot and the shell completes
  // the held-open response of that same overlay; a request from another overlay can never be
  // answered into this one. The intercept runs inside webOverlay(slot), so no native signature
  // or host-export change is needed.
  private hybridInvokeResponse(event: OnInterceptRequestEvent, slot: number): WebResourceResponse {
    // Same frame check as hybridMessageResponse: only the served document's own request may
    // use the invoke endpoint, everything else gets the malformed-request response.
    if (!this.hybridEndpointAllowed(event)) {
      this.logHybridEndpointRejection('invoke', event);
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
    } catch {
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
    // Tagged request id: ((slot + 1) << 24) | (sequence & 0xFFFFFF). The 24-bit sequence wraps
    // (the map holds only in-flight responses, so a wrapped id is unique among them).
    this.hybridInvokeSeq = (this.hybridInvokeSeq + 1) & 0xFFFFFF;
    const requestId: number = ((slot + 1) << 24) | this.hybridInvokeSeq;
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

  // Overlay avoid-area (audit ARKTS-S3): the keyboard inset can exceed the static system
  // bottom inset while it is up, so the overlay bottom uses the larger of the two.
  private overlayBottomInset(): number {
    return Math.max(this.avoidBottom, this.keyboardBottom);
  }

  // build() stays ternary-free (audit ARKTS-S3): the visibility and hit-test decisions live in
  // named helpers so the declarative tree remains reviewable. MULTI-OVL: visibility is per
  // overlay slot.
  private webVisibility(slot: number): Visibility {
    return this.webVisible[slot] ? Visibility.Visible : Visibility.None;
  }

  // MULTI-OVL: the ArkWeb overlay declaration, instantiated once per declared slot. Each overlay
  // starts hidden until a managed web control claims its slot and sends a frame. The frame
  // command moves/sizes it (a zero dimension stays full-window); DOM storage is on by default,
  // matching the MAUI Android handler (DomStorageEnabled=true), so localStorage works in
  // hybrid/Blazor pages. Declared after the XComponent/ContentSlot: a Stack composites later
  // children above earlier ones, and the managed app surface is the earlier child, so the
  // overlays really show over the managed surface (FIX-WVP; declared first they stayed under
  // the surface and every served web page was invisible). MULTI-OVERLAY-FULL: the fixed
  // slot-1-on-top order is gone; .zIndex applies the activation order (a touch or a programmatic
  // show/load) so the most recently activated overlay composites on top of an overlapping one.
  // SLOTS-DYNAMIC: the builder is instantiated from the @State webSlots list, so adding a slot
  // creates its ArkWeb on demand and removing it (slot destroy) tears the component down.
  @Builder
  webOverlay(slot: number): void {
    Web({ src: '', controller: this.slotController(slot) })
      .domStorageAccess(true)
      .visibility(this.webVisibility(slot))
      .zIndex(this.webZOrder[slot])
      .onTouch((event: TouchEvent) => {
        // A user touch activates the overlay (z-order) and refreshes its LRU slot on the
        // managed side; the event is not consumed, so the page keeps receiving it.
        if (event.type === TouchType.Down) {
          this.noteWebActivation(slot);
          this.forwardWebActivation(slot);
        }
      })
      .width(this.webFrameW[slot] > 0 ? `${this.webFrameW[slot]}vp` : '100%')
      .height(this.webFrameH[slot] > 0 ? `${this.webFrameH[slot]}vp` : '100%')
      .position({ x: this.webFrameX[slot], y: this.webFrameY[slot] })
      // The controller is attached here; registering the dotnetHost proxy any earlier fails
      // with BusinessError 17100001 (controller not associated with a Web component). The
      // dynamic slot marks itself attached and replays the commands that were deferred while
      // the component was being created.
      .onControllerAttached(() => {
        this.webSlotAttached[slot] = true;
        this.registerDotNetHost(slot);
        this.flushWebOps(slot);
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
          if (this.consumeApprovedNavigation(url, slot)) {
            return false;
          }
          if (url.length === 0 || url.length > this.navMaxUrlLength) {
            // Nothing to hand over (or too large to copy): the load stays blocked.
            return true;
          }
          this.askManagedAboutNavigation(slot, url);
          return true;
        } catch {
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
            if (this.blazorServeLogs < 3) {
              this.blazorServeLogs++;
              this.logInfo(`[maui] web serve: ${url} -> ${this.blazorFilePath(url)}`);
            }
            return this.serveBlazorFile(url);
          }
          // Only the MAUI hybrid origin is intercepted, and only after that overlay's managed
          // handler registered the payload root; everything else is left to the Web engine.
          // MULTI-OVERLAY-FULL: the registration, serving and invoke/message endpoints are all
          // scoped to this builder's slot, so two HybridWebViews on the same page each serve
          // their own document even though they share the origin.
          if (!this.hybridRegistered[slot] || !url.startsWith(this.hybridOrigin)) {
            return null;
          }
          if (this.hybridServeLogs[slot] < 3) {
            this.hybridServeLogs[slot]++;
            this.logInfo(`[maui] web serve (slot ${slot}): ${url} -> ${this.hybridFilePath(url, slot)}`);
          }
          if (url.startsWith(this.hybridOrigin + '__hwvInvokeDotNet')) {
            return this.hybridInvokeResponse(event, slot);
          }
          if (url.startsWith(this.hybridOrigin + '__hwvSendMessage')) {
            return this.hybridMessageResponse(event, slot);
          }
          return this.serveHybridFile(url, slot);
        } catch {
          return null;
        }
      })
      .onPageBegin((event) => {
        // A new main-frame document gets its own Blazor bootstrap.
        this.blazorBootstrapped[slot] = false;
        const startedUrl: string = event ? event.url : '';
        // B6: the approved/app-requested load started; its one-shot marker is used up.
        this.retireNavigationMarker(startedUrl, slot);
        this.hostCall('notifyWebEvent', typeof host !== 'undefined' && typeof host.notifyWebEvent === 'function', (): void => {
          host.notifyWebEvent(this.webEventState(slot, 'started'), startedUrl);
        });
      })
      .onPageEnd((event) => {
        const pageUrl: string = event ? event.url : '';
        this.logInfo(`[maui] web page (slot ${slot}): ${pageUrl}`);
        this.hostCall('notifyWebEvent', typeof host !== 'undefined' && typeof host.notifyWebEvent === 'function', (): void => {
          host.notifyWebEvent(this.webEventState(slot, 'finished'), pageUrl);
        });
        this.injectPageBridge(slot, pageUrl);
        this.injectBlazorBootstrap(slot, pageUrl);
        // History availability changed with this document; the managed WebView mirrors it
        // into IWebView.CanGoBack/CanGoForward.
        this.reportWebHistory(slot);
      })
      // Blazor WebAssembly console markers (B2): the staged site logs BLZ_* diagnostics;
      // forward them to hilog under the shared BlazorWebHost tag, so a device run has a
      // machine verdict (`hilog | grep BlazorWebHost`) independent of the managed status
      // file. Returning false keeps the browser console output as well.
      .onConsole((event) => {
        try {
          const consoleMessage: string = event.message.getMessage();
          if (consoleMessage.startsWith('BLZ_')) {
            hilog.info(DOMAIN, BLZ_TAG, 'marker: %{public}s', consoleMessage);
          }
        } catch {
          // A console event the shell cannot read must not take the page down.
        }
        return false;
      })
      .onErrorReceive((event) => {
        // A failed main-frame load: tell the managed side so it can raise Navigated(Failure)
        // and clear the overlay (the managed surface shows through); subresource errors are
        // not page failures and stay on the page.
        try {
          if (event && event.request && !event.request.isMainFrame()) {
            return;
          }
          const errorUrl: string = event && event.request ? event.request.getRequestUrl() : '';
          this.logError(`[maui] web error (slot ${slot}): ${errorUrl}`);
          this.hostCall('notifyWebEvent', typeof host !== 'undefined' && typeof host.notifyWebEvent === 'function', (): void => {
            host.notifyWebEvent(this.webEventState(slot, 'error'), errorUrl);
          });
        } catch {
          // An unexpected event shape must not take the page down.
        }
      })
      // File selection (matrix #11): an <input type=file> in the page reaches
      // onShowFileSelector; the shell opens the system document picker (multi-select when the
      // page asked for it) and hands the selection back to ArkWeb. Returning true takes the
      // selection over; the page's request is always answered (an empty list cancels).
      .onShowFileSelector((event) => {
        try {
          const multiple: boolean = event.fileSelector.getMode() === 1;
          this.selectWebFileUris(multiple).then((uris: string[]): void => {
            event.result.handleFileList(uris);
          }).catch((fileSelectError: Error): void => {
            this.logError(`[maui] web file selection failed: ${fileSelectError.message}`);
            event.result.handleFileList([]);
          });
        } catch (fileSelectorError) {
          this.logError(`[maui] web file selection failed: ${(fileSelectorError as Error).message}`);
          event.result.handleFileList([]);
        }
        return true;
      })
      // Media permissions (matrix #12): getUserMedia's camera/microphone reaches
      // onPermissionRequest. The shell prompts for the resources it owns (declared through the
      // webview-media feature) and grants exactly those; every other resource is denied, so a
      // page can never self-grant.
      .onPermissionRequest((event) => {
        try {
          const resources: string[] = event.request.getAccessibleResource();
          const permissions: Permissions[] = [];
          for (let i = 0; i < resources.length; i++) {
            const resource: string = resources[i];
            if (resource === 'ohos.permission.CAMERA' || resource === 'ohos.permission.MICROPHONE') {
              permissions.push(resource as Permissions);
            }
          }
          if (permissions.length === 0) {
            event.request.deny();
            return;
          }
          const atManager = abilityAccessCtrl.createAtManager();
          atManager.requestPermissionsFromUser(this.hostContext(), permissions).then((result) => {
            const granted: Permissions[] = [];
            for (let i = 0; i < permissions.length && i < result.authResults.length; i++) {
              if (result.authResults[i] === 0) {
                granted.push(permissions[i]);
              }
            }
            if (granted.length > 0) {
              event.request.grant(granted);
            } else {
              event.request.deny();
            }
          }).catch((mediaError: Error): void => {
            this.logError(`[maui] web media permission failed: ${mediaError.message}`);
            event.request.deny();
          });
        } catch (permissionRequestError) {
          this.logError(`[maui] web media permission failed: ${(permissionRequestError as Error).message}`);
          try {
            event.request.deny();
          } catch {
          }
        }
      })
      // Multi-window (matrix #13): window.open asks for a new window. This slice is
      // single-window, so the target loads in this component instead of creating a second
      // ArkWeb; the programmatic marker lets the load through the navigation gateway, and the
      // page's controller handler is left unset (no new window is created).
      .multiWindowAccess(true)
      .onWindowNew((event) => {
        try {
          const targetUrl: string = event.targetUrl;
          if (targetUrl.length === 0 || targetUrl.length > this.navMaxUrlLength) {
            return;
          }
          this.navProgrammatic[slot] = { url: targetUrl, expires: Date.now() + this.navPendingTtlMs };
          this.slotController(slot).loadUrl(targetUrl);
        } catch (windowError) {
          this.logError(`[maui] window.open fallback failed: ${(windowError as Error).message}`);
        }
      })
  }

  private shellSearchHitTest(): HitTestMode {
    return this.shellSearchVisible ? HitTestMode.Default : HitTestMode.None;
  }

  // IME preview text normalization for onChange's optional second argument (P0c): the
  // declarative tree stays ternary-free; an absent preview text means "no composition".
  private previewTextValue(previewText?: PreviewText): string {
    return previewText !== undefined ? previewText.value : '';
  }

  private previewTextOffset(previewText?: PreviewText): number {
    return previewText !== undefined ? previewText.offset : 0;
  }

  build() {
    Stack() {
      // Text entry bridge: the managed Entry reads what is typed here. The input method's
      // composing (preview) text rides onChange's second argument and its own export so the
      // managed self-drawn editor can render the preedit at the caret (underline/highlight)
      // and replace it when the commit arrives as the plain text change. An empty preview value
      // means committed/cancelled.
      TextInput({ text: this.inputText, placeholder: 'type here', controller: this.controller })
        .id('ohos_dotnet_input')
        .height(56)
        .position({ x: 0, y: 0 })
        .onChange((value: string, previewText?: PreviewText) => {
          this.inputText = value;
          // Per-keystroke path: a mismatched host logs once, not once per character.
          this.hostCall('notifyTextInput', typeof host !== 'undefined' && typeof host.notifyTextInput === 'function', (): void => {
            host.notifyTextInput(value);
          });
          this.hostCall('notifyTextComposition', typeof host !== 'undefined' && typeof host.notifyTextComposition === 'function', (): void => {
            host.notifyTextComposition(this.previewTextValue(previewText), this.previewTextOffset(previewText));
          });
        })
        .onSubmit(() => {
          // The managed Entry/SearchBar raises Completed/SearchButtonPressed.
          this.hostCall('notifyTextSubmitted', typeof host !== 'undefined' && typeof host.notifyTextSubmitted === 'function', (): void => {
            host.notifyTextSubmitted(this.inputText);
          });
        })

      XComponent({
        id: 'ohos_dotnet_surface',
        type: XComponentType.SURFACE,
        libraryname: 'openharmonyhost',
      })
        .focusable(true)
        .onKeyEvent((event: KeyEvent): void => {
          // Hardware keys pressed while the .NET surface holds focus: forward the raw ArkUI key
          // code and the down/up type (KeyType.Down = 0, KeyType.Up = 1) to host.keyEvent ->
          // ohos_host_register_key_event. MAUI rc.1 exposes no key hook (no IKeyListener), so
          // the managed bridge keeps the callback as its documented internal surface.
          this.hostCall('keyEvent', typeof host !== 'undefined' && typeof host.keyEvent === 'function', (): void => {
            host.keyEvent(event.keyCode, event.type === KeyType.Down ? 0 : 1);
          });
        })
        .onLoad(() => {
          // Binds the native XComponent so libopenharmonyhost receives surface callbacks.
          // Guarded like every other host export: a host that failed to load (for example an
          // unresolved DT_NEEDED in the .so) leaves the surface unattached and logs the
          // unavailability once instead of throwing TypeError out of the XComponent callback.
          this.hostCall('registerXComponent', typeof host !== 'undefined' && typeof host.registerXComponent === 'function', (): void => {
            host.registerXComponent();
          });
          // Surface ready: publish the app context (payload dir + ability paths) so a
          // startApp without one can still be completed by the managed bridge.
          this.publishAppContext();
        })
        .width('100%')
        .height('100%')

      ContentSlot(this.content)

      // MULTI-OVL / SLOTS-DYNAMIC: the ArkWeb overlays, one per declared slot. The hot pair
      // [0, 1] is always declared (it composites bottom-up in declaration order until the
      // activation z-index moves one on top); dynamic slots are appended on demand up to
      // WEB_SLOT_MAX and removed again by "slot destroy". Every overlay stays hidden until a
      // managed control claims its slot and sends a frame. Replaces the single shared component
      // of FIX-WVP.
      if (this.webOverlaysMounted) {
        ForEach(this.webSlots, (slot: number) => {
          this.webOverlay(slot)
        }, (slot: number): string => `web-slot-${slot}`)
      }


      // Map overlay (R2-3): only mounted while the managed side created the overlay through the
      // Map sink (op 1) and the shell resolved the harmony-flavor overlay module. The
      // NodeContainer mounts the proxy's NodeController, whose makeNode builds the MapComponent;
      // show/hide is the visibility toggle (the component stays alive, so a later show does not
      // pay a map re-create). Under the overlay sit the XComponent/ContentSlot (managed surface);
      // above it stay the shell panel, menu handle and accessibility self-check.
      if (this.mapOverlayActive && this.hmsMapOverlay !== undefined) {
        NodeContainer(this.hmsMapOverlay.nodeController)
          .visibility(this.mapOverlayVisible ? Visibility.Visible : Visibility.None)
          .width('100%')
          .height('100%')
      }

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
                this.hostCall('notifyShellSearch', typeof host !== 'undefined' && typeof host.notifyShellSearch === 'function', (): void => {
                  host.notifyShellSearch(0, value);
                });
              })
              .onSubmit((): void => {
                this.hostCall('notifyShellSearch', typeof host !== 'undefined' && typeof host.notifyShellSearch === 'function', (): void => {
                  host.notifyShellSearch(1, this.shellSearchQuery);
                });
              })
            Row() {
              Button('Cancel')
                .height(28)
                .fontSize(12)
                .onClick(() => {
                  this.shellSearchQuery = '';
                  this.hostCall('notifyShellSearch', typeof host !== 'undefined' && typeof host.notifyShellSearch === 'function', (): void => {
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
        .margin({ top: 8 + this.avoidTop, left: 8 + this.avoidLeft })
        .hitTestBehavior(this.shellSearchHitTest())
      }

      // Menu handle: only present while the managed page publishes menu bars. A structured
      // table (T16) renders one MenuItemGroup per bar with nested submenus; a legacy flat table
      // keeps the MenuElement array. Choosing a leaf calls host.notifyMenuAction(index).
      if (this.hasStructuredMenu()) {
        Button('Menu')
          .align(Alignment.TopEnd)
          .margin({ top: 8 + this.avoidTop, right: 8 + this.avoidRight })
          .height(40)
          .fontSize(18)
          .bindMenu(this.structuredMenu)
      } else if (this.menuItems.length > 0) {
        Button('Menu')
          .align(Alignment.TopEnd)
          .margin({ top: 8 + this.avoidTop, right: 8 + this.avoidRight })
          .height(40)
          .fontSize(18)
          .bindMenu(this.buildMenuElements())
      }

      // Accessibility self-check (FIX-A11YBUTTON): a tiny overlay in the bottom-left corner.
      // The Stack overlays it, so it never takes layout space from the managed surface (the
      // XComponent and the ContentSlot keep their full size); tapping it shows the provider
      // state. A Stack child's .align() only aligns the component's own content - the Stack's
      // alignContent decides the child position - so the button is placed absolutely with an
      // Edges position instead. Its zIndex tracks the web overlays' activation counter + 1, so
      // an activated ArkWeb (which composites at its own positive zIndex) can never cover the
      // self-check: the button stays tappable with or without a live web control.
      Button('A11Y')
        .position({ bottom: 4 + this.overlayBottomInset(), left: 4 + this.avoidLeft })
        .zIndex(this.webZOrderSeq + 1)
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
