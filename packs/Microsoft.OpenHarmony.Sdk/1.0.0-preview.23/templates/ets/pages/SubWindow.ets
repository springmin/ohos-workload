// Shell content for the application subwindow: MULTIWINDOW-M drawn page + MULTIWINDOW-L M3
// managed surface + MULTIWINDOW-L2 child ArkWeb host.
//
// Loaded with Window.loadContentByName('ohos_dotnet_subwindow', storage) by pages/Index.ets
// after Window.createSubWindowWithOptions. Two modes:
//   * managed (M3): pages/Index.ets received a surfaceId from the managed OpenWindow command
//     and put it into the LocalStorage. The body mounts an XComponent with that id, bound to
//     libopenharmonyhost, and registers/unregisters it around its lifecycle. The managed side's
//     per-window renderer draws the second MAUI visual tree into that surface, and its input is
//     routed by the native host under the same window id.
//   * drawn (M, the degradation path): without a surfaceId (older managed side, no shell sink,
//     or a failed claim) the page draws its own content as before, so the subwindow keeps
//     working with its header, drag and touch counter.
//
// The window guard matters: window.getLastWindow() returns the top window of the application,
// which can be the main window while the child is not focused. The page may only move the window
// whose WindowProperties.name matches the name pages/Index.ets passed to
// createSubWindowWithOptions (the id pages/Index.ets also puts in the LocalStorage is the
// secondary check, when the runtime propagates it), so a wrong lookup degrades to "content still
// interactive, drag disabled" instead of moving the wrong window.
import { common } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { NodeContent } from '@kit.ArkUI';
import { fileIo as fs } from '@kit.CoreFileKit';
import { webview as web_webview } from '@kit.ArkWeb';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { util } from '@kit.ArkTS';
import host from 'libopenharmonyhost.so';

const DOMAIN = 0x0002;
const TAG = 'OHOS_MAUI_SUB';

// Shell -> managed event ops (mirror OpenHarmonySubWindowEventKind).
const SUB_EVENT_CLOSED: number = 5;
const SUB_EVENT_TOUCH: number = 6;
const SUB_EVENT_PAGE_READY: number = 8;
// MULTIWINDOW-L M4: the child page's own input. Text/key/back events travel on the existing
// subwindow event channel (host.notifySubWindowEvent), so no host export changes are needed.
const SUB_EVENT_TEXT: number = 13;
const SUB_EVENT_TEXT_COMPOSITION: number = 14;
const SUB_EVENT_TEXT_SUBMITTED: number = 15;
const SUB_EVENT_KEY: number = 16;
const SUB_EVENT_BACK: number = 17;
// The name pages/Index.ets hands to createSubWindowWithOptions; WindowProperties.name carries
// it back, and it is the drag guard's identity check (see aboutToAppear). MULTIWINDOW-L3 M2
// appends the session generation: '<SUB_WINDOW_NAME>__<surfaceId>.g<generation>'.
const SUB_WINDOW_NAME: string = 'ohos_dotnet_subwindow';
// M4: the AppStorage key the main page writes a focus/keyboard request to (the child's own
// LocalStorage is not propagated); the @StorageLink below watches it.
const SUB_WINDOW_FOCUS_REQUEST_KEY: string = 'ohos_dotnet_subwindow_focus_request';
// MULTIWINDOW-L3 M2 identity handshake. The shell publishes one claim per live child before the
// page loads (SUB_WINDOW_CLAIM_KEY) and confirms the managed ack through SUB_WINDOW_IDENTITY_KEY;
// the page mounts the managed surface only after the ack names its own surface id and generation.
const SUB_WINDOW_CLAIM_KEY: string = 'ohos_dotnet_subwindow_claim';
const SUB_WINDOW_IDENTITY_KEY: string = 'ohos_dotnet_subwindow_identity';
const SUB_WINDOW_GENERATION_SEPARATOR: string = '.g';

// One shell-published claim (pages/Index.ets SubWindowClaimRecord).
interface SubWindowClaimRecord {
  surfaceId: string;
  id: number;
  gen: number;
  name: string;
}

interface SubWindowClaimTable {
  claims: SubWindowClaimRecord[];
}

// The shell's identity confirmation (pages/Index.ets SubWindowIdentityAck).
interface SubWindowIdentityAck {
  surfaceId: string;
  id: number;
  gen: number;
  seq: number;
}

// The child page's ready report. status 0 = identity resolved (surfaceId/gen/name carry it),
// status 1 = identity rejected (rejectedSurfaceId names the claim the managed side must close).
interface SubWindowReadyPayload {
  id: number;
  status: number;
  surfaceId?: string;
  gen?: number;
  name?: string;
  reason?: string;
}

// MULTIWINDOW-L2: the subwindow's own ArkWeb host (the second web host). The pool is small and
// fully dynamic: a slot's ArkWeb is instantiated by the first tagged command that needs it and
// destroyed when the managed pool releases the slot, so a subwindow without web content never
// starts an ArkWeb engine (the AOT-STARTUP lesson from the main page). Commands arrive through
// the native child sink (host.registerChildWebSink) and use the same "s<slot>" wire the main
// page uses. Page events travel back through host.notifyWebEvent tagged with this window
// ("w:<surfaceId>|s<slot>|<state>"; capacity is "w:<surfaceId>|capacity|<n>") so the primary
// pool and this pool can never consume each other's events.
// MULTIWINDOW-L3: the hybrid/Blazor asset bridge runs here too. The managed registration
// (op "hybrid"/"blazor", already routed through the child command channel by the slice) is
// accepted per slot, the app origins are intercepted and served from the same payload
// directory, and the dotnetHost proxy + page bridge are installed per child controller, so a
// child-window HybridWebView or BlazorWebView gets its documents and JS -> .NET messages. The
// hybrid __hwvInvokeDotNet response channel completes through the child result sink
// (host.registerChildHybridInvokeResultSink) with the child-tagged request id.
const SUB_WEB_SLOT_MAX: number = 2;
const SUB_WEB_SLOT_PENDING_MAX: number = 32;
const SUB_WEB_STATE_PREFIX: string = 'w:';
// B6: the child navigation ask state ("s<slot>|navask|<id>" with the cancelled URL in the event
// URL slot) and the managed answer command ("nav": "s<slot>\n<id>\n<url>") — the child-window
// counterpart of the primary page's "__OHNAV" channel.
const SUB_WEB_NAV_ASK_PREFIX: string = 'navask|';

// The MAUI hybrid origin (mirrors OpenHarmonyHybridWebViewHandler.AppOrigin) and the default
// Blazor origin. Both always carry a trailing '/'.
const SUB_HYBRID_ORIGIN: string = 'https://0.0.0.1/';
const SUB_BLAZOR_ORIGIN_DEFAULT: string = 'https://0.0.0.0/';

// One deferred child-web command: replayed from onControllerAttached when the ArkWeb of its
// slot was still being created (mirrors the main page's WebPendingOp, without the eval case:
// a child eval is answered immediately when no page exists).
interface SubWebPendingOp {
  op: string;
  arg: string;
}

// B6: one child-window navigation this page cancelled and asked the managed handler to decide
// (the child counterpart of pages/Index.ets PendingNavigation). The URL stays with this page;
// the managed answer echoes the unguessable id and only that stored URL may reload.
interface SubWebPendingNavigation {
  url: string;
  expires: number;
  slot: number;
}

// B6: the one-shot marker that lets exactly one child load pass onLoadIntercept without another
// managed round trip (the approved reload, or a managed "load" command).
interface SubWebApprovedNavigation {
  url: string;
  expires: number;
}

// The hybrid registration payload (op "hybrid"): the managed handler names the payload
// directory (base), the hybrid root and default file, the per-registration document id it
// stamps into served documents, and the child slot that owns the registration. Mirrors
// HybridAssetsConfig in pages/Index.ets; the child host stores one per slot.
interface SubHybridAssetsConfig {
  base: string;
  root: string;
  defaultFile: string;
  id: string;
  slot?: number;
}

// The Blazor registration payload (op "blazor"): same layout plus the app origin and the
// "wasm" mode marker (a WASM site ships its own bootstrap and is not loaded by the shell).
interface SubBlazorAssetsConfig {
  origin: string;
  base: string;
  root: string;
  defaultFile: string;
  id: string;
  mode?: string;
  slot?: number;
}

// The stock hybridwebview.js __hwvInvokeDotNet body.
interface SubHybridInvokeRequest {
  MethodName?: string;
  ParamValues?: string[];
}

// The error payload completed into a delayed __hwvInvokeDotNet response.
interface SubHybridInvokeErrorResult {
  IsError: boolean;
  ErrorMessage: string;
}

// One held-open __hwvInvokeDotNet response, completed by the child result sink or the timeout.
interface SubHybridPendingInvoke {
  response: WebResourceResponse;
  timer: number;
}

// One typed-text report for the managed side.
interface SubWindowTextPayload {
  surfaceId?: string;
  text: string;
}

// One IME preview report (PreviewText.value/offset).
interface SubWindowCompositionPayload {
  surfaceId?: string;
  value: string;
  offset: number;
}

// One raw hardware key report (ArkUI key code + KeyType: 0 down, 1 up).
interface SubWindowKeyPayload {
  surfaceId?: string;
  code: number;
  type: number;
}

// The focus/keyboard request written by pages/Index.ets (mirrors its interface). M3: the
// generation names the session the request was issued for; a reopened surface id ignores a
// request that belongs to a retired generation.
interface SubWindowFocusRequest {
  surfaceId: string;
  show: number;
  caret: number;
  text?: string;
  seq: number;
  gen?: number;
}

@Entry({ routeName: 'ohos_dotnet_subwindow' })
@Component
struct SubWindow {
  // The child's own window id, stamped by pages/Index.ets through the LocalStorage of
  // loadContentByName; -1 when the runtime does not propagate it (the name check then carries
  // the guard).
  @LocalStorageProp('subWindowId') subWindowId: number = -1;
  // MULTIWINDOW-L M3: the managed surface id (the managed OpenWindow command's window id, used
  // as the XComponent component id and the host registry id). MULTIWINDOW-L3 M2: the page's own
  // window name (UIContext.getWindowName) is the authoritative source; the LocalStorage value is
  // the exact per-window fallback when the runtime propagates it.
  @LocalStorageProp('subWindowSurfaceId') storedSurfaceId: string = '';
  // MULTIWINDOW-L3 M2: the session generation, the LocalStorage fallback of the name suffix.
  @LocalStorageProp('subWindowGen') subWindowGen: number = 0;
  // State (not a plain field): the id is assigned in aboutToAppear, and the XComponent branch
  // must mount on the render that follows that assignment.
  @State surfaceId: string = '';
  @State touches: number = 0;
  @State drags: number = 0;
  @State resolvedId: number = -1;
  @State dragEnabled: boolean = false;
  // MULTIWINDOW-L3 M2: the identity handshake state. surfaceId resolves the page's own identity;
  // identityConfirmed flips only when the shell's ack names that identity, and the managed
  // XComponent/text input mount only then (a page whose name/LocalStorage/claim disagree stays
  // on the drawn fallback and never binds a managed surface). identityRejected marks a
  // fail-closed rejection (reported to the managed side, which closes the claimed session).
  @State identityConfirmed: boolean = false;
  @State identityRejected: boolean = false;
  private identityRejectReason: string = '';
  private rejectedSurfaceId: string = '';
  private parsedGeneration: number = 0;
  private ownName: string = '';
  private resolvedWindowName: string = '';
  private windowIsOwn: boolean = false;
  // True once the host confirmed the XComponent claim; the drawn fallback stays (and stays
  // interactive) until then, and hides once the managed surface owns the child.
  @State surfaceBound: boolean = false;
  // MULTIWINDOW-L M4: the managed focus/keyboard request channel from pages/Index.ets. The
  // @Watch runs on every change (the payload carries a sequence number, so a repeated request
  // still notifies).
  @StorageLink('ohos_dotnet_subwindow_focus_request') @Watch('onFocusRequest') focusRequest: string = '';
  // MULTIWINDOW-L3 M2: the shell's identity confirmation. The watch flips identityConfirmed only
  // for the ack that names this page's own surface id and generation.
  @StorageLink('ohos_dotnet_subwindow_identity') @Watch('onIdentityAck') identityAck: string = '';
  // The child's own hidden input (mirrors the main page's text-entry bridge): the managed
  // second window's Entry reads what is typed here and the IME follows this window.
  @State inputText: string = '';
  // MULTIWINDOW-L2: the child ArkWeb host. `subWebSlots` is the declared-slot list (empty until
  // the first claim, so no ArkWeb is instantiated before it is needed); every per-slot table is
  // preallocated to SUB_WEB_SLOT_MAX so an index stays valid while a slot is created/destroyed.
  @State subWebSlots: number[] = [];
  @State subWebVisible: boolean[] = [false, false];
  @State subWebZOrder: number[] = [0, 0];
  @State subWebFrameX: number[] = [0, 0];
  @State subWebFrameY: number[] = [0, 0];
  @State subWebFrameW: number[] = [0, 0];
  @State subWebFrameH: number[] = [0, 0];
  private subWebZOrderSeq: number = 0;
  private subWebCreated: boolean[] = [false, false];
  private subWebAttached: boolean[] = [false, false];
  private subWebControllers: (web_webview.WebviewController | null)[] = [null, null];
  private subWebPending: SubWebPendingOp[][] = [[], []];
  private subWebHostRegistered: boolean = false;
  private subWebCmdFrameLogged: boolean[] = [false, false];
  // B6 child navigation allow-list: the same bounded pending/one-shot shape as the primary page,
  // per child slot. Entries are time-bounded; a destroyed slot drops its pending decisions so a
  // late approval can never reload on the slot's next owner.
  private subNavPending: Map<string, SubWebPendingNavigation> = new Map();
  private subNavApproved: (SubWebApprovedNavigation | null)[] = [null, null];
  private subNavProgrammatic: (SubWebApprovedNavigation | null)[] = [null, null];
  private subNavPendingLimit: number = 8;
  private subNavPendingTtlMs: number = 5000;
  private subNavMaxUrlLength: number = 8192;
  // MULTIWINDOW-L3: per-slot hybrid registration (base/root/defaultFile/document id; the
  // managed handler registers one per child slot through the child command channel).
  private subHybridBase: string[] = ['', ''];
  private subHybridRoot: string[] = ['', ''];
  private subHybridDefaultFile: string[] = ['', ''];
  private subHybridDocId: string[] = ['', ''];
  private subHybridRegistered: boolean[] = [false, false];
  private subHybridServeLogs: number[] = [0, 0];
  // Blazor registration (one per child page, mirroring the main page's single registration).
  private subBlazorBase: string = '';
  private subBlazorRoot: string = '';
  private subBlazorDefaultFile: string = '';
  private subBlazorDocId: string = '';
  private subBlazorRegistered: boolean = false;
  private subBlazorOrigin: string = SUB_BLAZOR_ORIGIN_DEFAULT;
  private subBlazorWasmMode: boolean = false;
  private subBlazorBootstrapped: boolean[] = [false, false];
  private subBlazorServeLogs: number = 0;
  // The hybrid __hwvInvokeDotNet responses held open until the managed handler answers through
  // host.registerChildHybridInvokeResultSink (or the local timeout fires).
  private subHybridInvokeSeq: number = 0;
  private subHybridInvokes: Map<number, SubHybridPendingInvoke> = new Map();
  private subHybridEndpointLogs: number = 0;
  private subHybridInvokeTimeoutMs: number = 15000;
  private inputController: TextInputController = new TextInputController();
  // MULTIWINDOW-L3 M3: this window's own focus state for the IME contract. A show=1 request is
  // only applied while the window is active; one that arrives while it is inactive is
  // remembered and applied on the next WINDOW_ACTIVE (the focus-switch case), so the keyboard
  // can never open for a background window.
  private windowActive: boolean = true;
  private pendingInputFocus: boolean = false;
  // MULTIWINDOW-L2 a: the child's own accessibility content slot. The host creates a CUSTOM
  // node inside it and registers a per-instance ArkUI accessibility provider
  // (attachAccessibilityNodeFor), so the child's shadow tree is served by its own provider.
  private content: NodeContent = new NodeContent();
  private win: window.Window | null = null;
  private startLeft: number = 0;
  private startTop: number = 0;

  aboutToAppear(): void {
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    // MULTIWINDOW-L3 M2: the page's own window name is the deterministic identity source
    // (getLastWindow can return the main or the other child window while this page loads); it is
    // read synchronously and cross-checked against the LocalStorage value and the shell's claim
    // table. A disagreement rejects the identity: no managed surface is mounted.
    let ownName: string = '';
    try {
      const resolvedOwnName: string | undefined = this.getUIContext().getWindowName();
      ownName = resolvedOwnName !== undefined ? resolvedOwnName : '';
    } catch (ownNameError) {
      hilog.warn(DOMAIN, TAG, 'subwindow own window name unavailable: %{public}s', (ownNameError as Error).message);
    }
    this.ownName = ownName;
    window.getLastWindow(context).then((win: window.Window): void => {
      this.win = win;
      const props = win.getWindowProperties();
      this.resolvedId = props.id;
      const resolvedName: string = props.name !== undefined ? props.name : '';
      this.resolvedWindowName = resolvedName;
      const managedPrefix: string = `${SUB_WINDOW_NAME}__`;
      // The identity name: the page's own window name when the runtime exposes it, else the
      // name of the window getLastWindow resolved (the legacy fallback, hardened below).
      const identityName: string = this.ownName.length > 0 ? this.ownName : resolvedName;
      let nameSurfaceId: string = '';
      let nameGeneration: number = 0;
      if (identityName.startsWith(managedPrefix)) {
        const rest: string = identityName.substring(managedPrefix.length);
        const separatorIndex: number = rest.indexOf(SUB_WINDOW_GENERATION_SEPARATOR);
        if (separatorIndex > 0) {
          nameSurfaceId = rest.substring(0, separatorIndex);
          const parsed: number = Number.parseInt(
            rest.substring(separatorIndex + SUB_WINDOW_GENERATION_SEPARATOR.length), 10);
          nameGeneration = Number.isNaN(parsed) ? 0 : parsed;
        } else {
          nameSurfaceId = rest;
        }
      }
      const storedSurfaceId: string = this.storedSurfaceId;
      const storedGeneration: number = this.subWindowGen;
      let rejected: boolean = false;
      let reason: string = '';
      let candidateSurfaceId: string = nameSurfaceId.length > 0 ? nameSurfaceId : storedSurfaceId;
      let candidateGeneration: number = nameSurfaceId.length > 0 ? nameGeneration : storedGeneration;
      if (nameSurfaceId.length > 0 && storedSurfaceId.length > 0
        && (nameSurfaceId !== storedSurfaceId
          || (nameGeneration > 0 && storedGeneration > 0 && nameGeneration !== storedGeneration))) {
        rejected = true;
        reason = `window name and LocalStorage disagree: name=${nameSurfaceId}/${nameGeneration} stored=${storedSurfaceId}/${storedGeneration}`;
      } else if (candidateSurfaceId.length > 0 && this.ownName.length === 0 && storedSurfaceId.length === 0) {
        // Without the own-window-name API the page only has the getLastWindow name, which can be
        // the other child's window: require the exact LocalStorage identity or reject.
        rejected = true;
        reason = `no per-window LocalStorage identity for surface=${candidateSurfaceId}`;
      }
      if (!rejected && candidateSurfaceId.length > 0) {
        const claim: SubWindowClaimRecord | null = this.findSubWindowClaim(candidateSurfaceId, candidateGeneration, identityName);
        if (claim === null) {
          rejected = true;
          reason = `no matching shell claim for surface=${candidateSurfaceId}`;
        }
      }
      if (rejected) {
        this.identityRejected = true;
        this.identityRejectReason = reason;
        this.rejectedSurfaceId = candidateSurfaceId.length > 0 ? candidateSurfaceId : nameSurfaceId;
        this.surfaceId = '';
        hilog.warn(DOMAIN, TAG, 'subwindow identity rejected: %{public}s', reason);
      } else if (candidateSurfaceId.length > 0) {
        this.surfaceId = candidateSurfaceId;
        this.parsedGeneration = candidateGeneration;
      }
      // Only the subwindow page may move/close a window: window.getLastWindow can return the
      // main or the other child window. With an own window name the resolved window must be
      // exactly it; without one the M1 name/LocalStorage guard is the fallback. A mismatch
      // disables dragging and closing instead of driving the wrong window.
      this.windowIsOwn = this.ownName.length > 0
        ? resolvedName === this.ownName
        : (resolvedName === SUB_WINDOW_NAME || resolvedName.startsWith(managedPrefix) ||
           (this.subWindowId >= 0 && props.id === this.subWindowId));
      this.dragEnabled = this.windowIsOwn;
      hilog.info(DOMAIN, TAG, 'subwindow page ready: expected=%{public}d resolved=%{public}d name=%{public}s own=%{public}s surface=%{public}s gen=%{public}d rejected=%{public}s drag=%{public}s',
        this.subWindowId, this.resolvedId, resolvedName, identityName, this.surfaceId,
        this.parsedGeneration, this.identityRejected ? 'yes' : 'no', this.dragEnabled ? 'on' : 'off');
      // M4: when this window loses focus, drop the IME with it (the keyboard follows the
      // focused window; the managed side re-focuses the child input when an Entry focuses).
      // M3: the focus state also gates an incoming show=1 request (a background window never
      // opens the keyboard; the pending request fires when this window becomes active).
      if (this.windowIsOwn) {
        try {
          win.on('windowEvent', (evt: window.WindowEventType): void => {
            if (evt === window.WindowEventType.WINDOW_INACTIVE) {
              this.windowActive = false;
              this.blurInput();
            } else if (evt === window.WindowEventType.WINDOW_ACTIVE) {
              this.windowActive = true;
              if (this.pendingInputFocus) {
                this.pendingInputFocus = false;
                this.onFocusRequest();
              }
            }
          });
        } catch (eventError) {
          hilog.error(DOMAIN, TAG, 'subwindow window events unavailable: %{public}s', (eventError as Error).message);
        }
      }
      this.notifyHost(SUB_EVENT_PAGE_READY, this.readyPayload());
      // The shell's ack may have arrived while this page's promise was still resolving: re-read
      // it now that the surface id is known.
      this.onIdentityAck();
      // A request may have arrived while the page was loading (the main page writes AppStorage
      // before the child exists); apply the current value once the surface id is known.
      this.onFocusRequest();
      // MULTIWINDOW-L2 a: the ContentSlot exists once build() has mounted the page (this
      // promise resolves after that), so the per-instance accessibility provider can attach now.
      this.attachAccessibility();
      // MULTIWINDOW-L2: the managed child pool may already have commands queued; registering
      // the child sink and advertising the capacity flushes them (see registerChildWebHost).
      this.registerChildWebHost();
    }).catch((readyError: Error): void => {
      hilog.error(DOMAIN, TAG, 'subwindow window lookup failed: %{public}s', readyError.message);
    });
  }

  // One event to the managed side. A shell whose host library lacks the export logs once and
  // the feature degrades to shell-local interaction (the content still works).
  private notifyHost(op: number, payload: string): void {
    try {
      if (typeof host !== 'undefined' && typeof host.notifySubWindowEvent === 'function') {
        host.notifySubWindowEvent(op, payload);
      } else {
        hilog.warn(DOMAIN, TAG, 'host.notifySubWindowEvent unavailable; subwindow event %{public}d dropped', op);
      }
    } catch (notifyError) {
      hilog.error(DOMAIN, TAG, 'subwindow event %{public}d failed: %{public}s', op, (notifyError as Error).message);
    }
  }

  private readyPayload(): string {
    const payload: SubWindowReadyPayload = {
      id: this.resolvedId,
      status: this.identityRejected ? 1 : 0,
    };
    if (this.identityRejected && this.rejectedSurfaceId.length > 0) {
      payload.surfaceId = this.rejectedSurfaceId;
    } else if (this.surfaceId.length > 0) {
      payload.surfaceId = this.surfaceId;
    }
    if (this.parsedGeneration > 0) {
      payload.gen = this.parsedGeneration;
    }
    if (this.ownName.length > 0) {
      payload.name = this.ownName;
    } else if (this.resolvedWindowName.length > 0) {
      payload.name = this.resolvedWindowName;
    }
    if (this.identityRejected && this.identityRejectReason.length > 0) {
      payload.reason = this.identityRejectReason;
    }
    return JSON.stringify(payload);
  }

  // MULTIWINDOW-L3 M2: validates an identity against the shell's per-child claim table. A
  // missing table/entry, a generation mismatch or a name mismatch returns null (fail-closed).
  private findSubWindowClaim(surfaceId: string, generation: number, name: string): SubWindowClaimRecord | null {
    const raw: string | undefined = AppStorage.get<string>(SUB_WINDOW_CLAIM_KEY);
    if (raw === undefined || raw.length === 0) {
      return null;
    }
    try {
      const table = JSON.parse(raw) as SubWindowClaimTable;
      const claims: SubWindowClaimRecord[] = table.claims;
      for (let i = 0; i < claims.length; i++) {
        const claim: SubWindowClaimRecord = claims[i];
        if (claim.surfaceId === surfaceId && claim.gen === generation && claim.name === name) {
          return claim;
        }
      }
    } catch (claimError) {
      hilog.error(DOMAIN, TAG, 'subwindow claim table parse failed: %{public}s', (claimError as Error).message);
    }
    return null;
  }

  // MULTIWINDOW-L3 M2: the shell's identity confirmation (written after the managed op 7 was
  // validated). Only the ack naming this page's own surface id and generation confirms the
  // identity; anything else is ignored, so a stale ack from a retired generation cannot mount
  // the wrong surface.
  private onIdentityAck(): void {
    if (this.surfaceId.length === 0 || this.identityRejected || this.identityAck.length === 0) {
      return;
    }
    try {
      const ack = JSON.parse(this.identityAck) as SubWindowIdentityAck;
      if (ack.surfaceId !== this.surfaceId || (ack.gen > 0 && ack.gen !== this.parsedGeneration)) {
        return;
      }
      if (this.identityConfirmed) {
        return;
      }
      this.identityConfirmed = true;
      hilog.info(DOMAIN, TAG, 'subwindow identity confirmed: surface=%{public}s gen=%{public}d id=%{public}d',
        this.surfaceId, this.parsedGeneration, ack.id);
      // A focus request that arrived while the identity was unconfirmed is applied now (the
      // input/XComponent mount with the confirmation).
      this.onFocusRequest();
    } catch (ackError) {
      hilog.error(DOMAIN, TAG, 'subwindow identity ack parse failed: %{public}s', (ackError as Error).message);
    }
  }

  // MULTIWINDOW-L2 a: hands the child's ContentSlot to the host, which creates the per-instance
  // CUSTOM node and registers the WithInstance accessibility provider (1 = attached, 3/4 =
  // refused, no export = silent degrade). Idempotent on the host side (same instance + same
  // content is a no-op), so both the surface-id resolution and every page show can call it.
  private attachAccessibility(): void {
    if (this.surfaceId.length === 0) {
      return;
    }
    try {
      if (typeof host !== 'undefined' && typeof host.attachAccessibilityNodeFor === 'function') {
        const status: number = host.attachAccessibilityNodeFor(this.surfaceId, this.content);
        hilog.info(DOMAIN, TAG, 'subwindow a11y provider status=%{public}d instance=%{public}s',
          status, this.surfaceId);
        // MULTIWINDOW-L2 a W2: the per-instance self-check. The managed frame reaches the
        // provider on the next render tick, so the attach status and the published node count
        // are read back after a short delay (the no-screen-reader evidence for provider+count).
        if (status === 1 && typeof host.accessibilityStatusFor === 'function') {
          setTimeout((): void => {
            try {
              const attached: number = host.accessibilityStatusFor(this.surfaceId);
              const nodes: number = host.accessibilityNodeCountFor(this.surfaceId);
              hilog.info(DOMAIN, TAG, 'subwindow a11y selfcheck status=%{public}d nodes=%{public}d instance=%{public}s',
                attached, nodes, this.surfaceId);
            } catch (checkError) {
              hilog.error(DOMAIN, TAG, 'subwindow a11y selfcheck failed: %{public}s', (checkError as Error).message);
            }
          }, 3000);
        }
      }
    } catch (a11yError) {
      hilog.error(DOMAIN, TAG, 'subwindow a11y attach failed: %{public}s', (a11yError as Error).message);
    }
  }

  // The ContentSlot is mounted with the page; a page re-show re-publishes the same content, which
  // the host treats as already attached, so this is a safe second call site (the first is after
  // the surface id resolves in aboutToAppear).
  onPageShow(): void {
    this.attachAccessibility();
  }

  // MULTIWINDOW-L M3: the surface lifecycle. registerXComponent returns 1 when the host has the
  // window registered after the call; a 0 keeps the drawn fallback (no managed surface), so a
  // shell whose host cannot bind the XComponent never shows a black hole.
  private bindSurface(): void {
    hilog.info(DOMAIN, TAG, 'subwindow xcomponent onLoad id=%{public}s', this.surfaceId);
    if (this.surfaceId.length === 0) {
      return;
    }
    try {
      if (typeof host !== 'undefined' && typeof host.registerXComponent === 'function') {
        const registered: number = host.registerXComponent(this.surfaceId);
        this.surfaceBound = registered === 1;
        hilog.info(DOMAIN, TAG, 'subwindow surface %{public}s registered=%{public}d', this.surfaceId, registered);
      } else {
        hilog.warn(DOMAIN, TAG, 'host.registerXComponent unavailable; the drawn fallback stays');
      }
    } catch (bindError) {
      hilog.error(DOMAIN, TAG, 'subwindow surface %{public}s registration failed: %{public}s',
        this.surfaceId, (bindError as Error).message);
    }
  }

  private unbindSurface(): void {
    hilog.info(DOMAIN, TAG, 'subwindow xcomponent onDestroy id=%{public}s', this.surfaceId);
    if (this.surfaceId.length === 0) {
      return;
    }
    try {
      if (typeof host !== 'undefined' && typeof host.unregisterXComponent === 'function') {
        const released: number = host.unregisterXComponent(this.surfaceId);
        hilog.info(DOMAIN, TAG, 'subwindow surface %{public}s unregistered=%{public}d', this.surfaceId, released);
      }
    } catch (unbindError) {
      hilog.error(DOMAIN, TAG, 'subwindow surface %{public}s unregistration failed: %{public}s',
        this.surfaceId, (unbindError as Error).message);
    }
    this.surfaceBound = false;
  }

  private closeSelf(): void {
    const win = this.win;
    if (win === null) {
      hilog.warn(DOMAIN, TAG, 'close requested before the window resolved');
      return;
    }
    if (!this.windowIsOwn) {
      // MULTIWINDOW-L3 M2: getLastWindow may have resolved the main or the other child window;
      // only the window this page proved to own may be destroyed.
      hilog.warn(DOMAIN, TAG, 'close ignored: the resolved window is not this page\'s own window');
      return;
    }
    win.destroyWindow().then((): void => {
      hilog.info(DOMAIN, TAG, 'subwindow destroyed by its close button');
    }).catch((closeError: Error): void => {
      hilog.error(DOMAIN, TAG, 'subwindow destroy failed: %{public}s', closeError.message);
    });
  }

  private beginDrag(): void {
    const win = this.win;
    if (win === null || !this.dragEnabled) {
      return;
    }
    try {
      const rect = win.getWindowProperties().windowRect;
      this.startLeft = rect.left;
      this.startTop = rect.top;
    } catch (dragError) {
      hilog.error(DOMAIN, TAG, 'subwindow drag baseline failed: %{public}s', (dragError as Error).message);
    }
  }

  private updateDrag(offsetX: number, offsetY: number): void {
    const win = this.win;
    if (win === null || !this.dragEnabled) {
      return;
    }
    this.drags++;
    const x = this.startLeft + vp2px(offsetX);
    const y = this.startTop + vp2px(offsetY);
    hilog.info(DOMAIN, TAG, 'subwindow drag #%{public}d -> %{public}d,%{public}d', this.drags, Math.round(x), Math.round(y));
    // PanGesture offsets are vp; moveWindowTo takes pixels.
    win.moveWindowTo(x, y).catch((moveError: Error): void => {
      hilog.error(DOMAIN, TAG, 'subwindow drag move failed: %{public}s', moveError.message);
    });
  }

  private reportTouch(event: TouchEvent): void {
    this.touches++;
    if (event.touches.length > 0) {
      const payload = `{"action":${event.type},"x":${Math.round(event.touches[0].x)},"y":${Math.round(event.touches[0].y)},"count":${event.touches.length}}`;
      // Device evidence: touch routing into this page is visible in hilog under OHOS_MAUI_SUB
      // even when the managed status file is not polled.
      hilog.info(DOMAIN, TAG, 'subwindow touch #%{public}d action=%{public}d at %{public}s',
        this.touches, event.type, payload);
      this.notifyHost(SUB_EVENT_TOUCH, payload);
    }
  }

  // The child's hidden input id (unique per managed surface so two shell revisions never
  // collide on the same ArkUI id).
  private inputControlId(): string {
    return this.surfaceId.length > 0 ? `${this.surfaceId}__input` : 'ohos_dotnet_subwindow_input';
  }

  // M4: focus leaves the child window -> hand ArkUI focus back to the child surface so the
  // soft keyboard hides with the window (window-level focus is the only reliable signal; see
  // the Home-note in pages/Index.ets). M2: only after the identity handshake mounted the surface.
  private blurInput(): void {
    if (this.surfaceId.length === 0 || !this.identityConfirmed) {
      return;
    }
    try {
      this.getUIContext().getFocusController().requestFocus(this.surfaceId);
    } catch (blurError) {
      hilog.error(DOMAIN, TAG, 'subwindow blur failed: %{public}s', (blurError as Error).message);
    }
  }

  // Applies one managed focus/keyboard request: show=1 focuses the hidden input (the IME opens
  // for this window) and seeds it with the managed text/caret; show=0 returns focus to the
  // child XComponent (typing/keys, keyboard closed). M2: only a confirmed identity may focus.
  // M3: only the request's own generation may focus, and only while this window is active (an
  // inactive window remembers the request until WINDOW_ACTIVE).
  private onFocusRequest(): void {
    if (this.surfaceId.length === 0 || !this.identityConfirmed || this.focusRequest.length === 0) {
      return;
    }
    try {
      const request = JSON.parse(this.focusRequest) as SubWindowFocusRequest;
      if (request.surfaceId !== this.surfaceId) {
        return;
      }
      if (request.gen !== undefined && request.gen > 0 && this.parsedGeneration > 0
        && request.gen !== this.parsedGeneration) {
        return;
      }
      if (request.show === 1) {
        if (!this.windowActive) {
          this.pendingInputFocus = true;
          return;
        }
        this.pendingInputFocus = false;
        if (request.text !== undefined && request.text.length > 0) {
          this.inputText = request.text;
        }
        this.inputController.caretPosition(request.caret >= 0 ? request.caret : 0);
        this.getUIContext().getFocusController().requestFocus(this.inputControlId());
        hilog.info(DOMAIN, TAG, 'subwindow text input focused: caret=%{public}d textLen=%{public}d',
          request.caret, this.inputText.length);
      } else {
        this.pendingInputFocus = false;
        this.getUIContext().getFocusController().requestFocus(this.surfaceId);
      }
    } catch (requestError) {
      hilog.error(DOMAIN, TAG, 'subwindow focus request failed: %{public}s', (requestError as Error).message);
    }
  }

  // IME preview normalization (same contract as the main page's helpers).
  private previewTextValue(previewText?: PreviewText): string {
    return previewText !== undefined ? previewText.value : '';
  }

  private previewTextOffset(previewText?: PreviewText): number {
    return previewText !== undefined ? previewText.offset : 0;
  }

  private textPayload(value: string): string {
    const payload: SubWindowTextPayload = this.surfaceId.length > 0
      ? { surfaceId: this.surfaceId, text: value }
      : { text: value };
    return JSON.stringify(payload);
  }

  // ---------------------------------------------------------------------------------------------
  // MULTIWINDOW-L2: the child ArkWeb host. The managed subwindow pool (OpenHarmonyChildWeb)
  // claims slots and sends tagged commands through the native child sink; this page runs them on
  // its own controllers and reports page events back tagged with this window's surface id. The
  // primary page's sink and slot tables are never touched.
  // ---------------------------------------------------------------------------------------------

  // Registers this page as the subwindow's ArkWeb host. The dedicated registration probes are
  // what keeps a host library that predates the child host on the single-primary-host path:
  // registerChildWebSink/registerChildWebEvalSink are missing there, the probe fails, no sink
  // is registered and the managed pool never receives the capacity advertisement (its queued
  // commands are dropped - exactly the pre-L2 behavior). A capacity that arrives before the
  // managed pool exists is harmless: the pool clamps to the advertised count on its own.
  // MULTIWINDOW-L3 M4: every sink is registered with this page's surface id, so the native
  // module routes each child window's commands/eval/results to its own page (two concurrent
  // subwindows never consume each other's traffic). The page unregisters them on disappear.
  private registerChildWebHost(): void {
    if (this.surfaceId.length === 0) {
      // The drawn (non-managed) subwindow has no managed tree, so no web control can exist.
      return;
    }
    try {
      if (typeof host === 'undefined' || typeof host.registerChildWebSink !== 'function') {
        hilog.info(DOMAIN, TAG, 'child web host unavailable (registerChildWebSink missing); subwindow web stays unmounted');
        return;
      }
      host.registerChildWebSink((op: string, arg: string): void => {
        this.logChildWebCommand(op, arg);
        this.onChildWebCommand(op, arg);
      }, this.surfaceId);
      if (typeof host.registerChildWebEvalSink === 'function') {
        host.registerChildWebEvalSink((script: string, requestId: number): void => {
          this.onChildWebEval(script, requestId);
        }, this.surfaceId);
      }
      // MULTIWINDOW-L3: the hybrid __hwvInvokeDotNet results for this page. The native module
      // routes a result here only when its request id carries the child-window tag AND this
      // window's index, so neither the main page's sink nor the other subwindow's is consumed.
      if (typeof host.registerChildHybridInvokeResultSink === 'function') {
        host.registerChildHybridInvokeResultSink((requestId: number, payload: string): void => {
          this.completeChildHybridInvoke(requestId, payload);
        }, this.surfaceId);
      }
      this.subWebHostRegistered = true;
      this.advertiseChildWebCapacity();
      // The managed pool subscribes after the app host is up; a lost advertisement only delays
      // the flush, so two bounded retries cover the startup ordering (the main page pattern).
      setTimeout((): void => {
        this.advertiseChildWebCapacity();
      }, 1500);
      hilog.info(DOMAIN, TAG, 'child web host registered: max=%{public}d surface=%{public}s', SUB_WEB_SLOT_MAX, this.surfaceId);
    } catch (registerError) {
      hilog.error(DOMAIN, TAG, 'child web registration failed: %{public}s', (registerError as Error).message);
    }
  }

  // MULTIWINDOW-L3 M4: drops this page's per-window sinks when the window's page goes away, so
  // a later command for the closed window is dropped (fail closed) instead of being delivered
  // to a dead page, and its callback reference cannot outlive the window (churn stability).
  private unregisterChildWebHost(): void {
    if (!this.subWebHostRegistered || this.surfaceId.length === 0) {
      return;
    }
    this.subWebHostRegistered = false;
    try {
      if (typeof host !== 'undefined' && typeof host.unregisterChildWebSink === 'function') {
        host.unregisterChildWebSink(this.surfaceId);
      }
    } catch (unregisterError) {
      hilog.warn(DOMAIN, TAG, 'child web unregister failed: %{public}s', (unregisterError as Error).message);
    }
  }

  // MULTIWINDOW-L3 M4: the 0-based index of this page's child window ("sub-1" -> 0, "sub-2" -> 1),
  // mirrored by the hybrid invoke window bit (bit 29) and the native registration map.
  private childWindowIndex(): number {
    const separator: number = this.surfaceId.lastIndexOf('-');
    if (separator < 0 || separator + 1 >= this.surfaceId.length) {
      return 0;
    }
    const parsed: number = Number.parseInt(this.surfaceId.substring(separator + 1), 10);
    if (Number.isNaN(parsed) || parsed <= 1) {
      return 0;
    }
    return parsed - 1;
  }

  // "w:<surfaceId>|capacity|<n>": marks the managed child pool ready and flushes its queue.
  private advertiseChildWebCapacity(): void {
    if (!this.subWebHostRegistered) {
      return;
    }
    hilog.info(DOMAIN, TAG, 'child web capacity advertised: max=%{public}d surface=%{public}s', SUB_WEB_SLOT_MAX, this.surfaceId);
    // The count travels inside the state ("w:<win>|capacity|<n>"), matching the managed
    // parser; the event URL stays empty.
    this.notifyWebHostState(`capacity|${SUB_WEB_SLOT_MAX}`, '');
  }

  // One host -> managed web event, prefixed with this window; per-slot states carry the slot.
  private notifyWebHostState(slotState: string, url: string): void {
    if (this.surfaceId.length === 0) {
      return;
    }
    const tagged: string = `${SUB_WEB_STATE_PREFIX}${this.surfaceId}|${slotState}`;
    try {
      if (typeof host !== 'undefined' && typeof host.notifyWebEvent === 'function') {
        host.notifyWebEvent(tagged, url);
      } else {
        hilog.warn(DOMAIN, TAG, 'host.notifyWebEvent unavailable; child web event %{public}s dropped', slotState);
      }
    } catch (notifyError) {
      hilog.error(DOMAIN, TAG, 'child web event failed: %{public}s', (notifyError as Error).message);
    }
  }

  private childWebEventState(slot: number, state: string): string {
    return `s${slot}|${state}`;
  }

  // One line per command the managed side sends through the child sink (frames only once per
  // slot, so an arrange loop cannot flood the log); the device round's command-chain record.
  private logChildWebCommand(op: string, arg: string): void {
    if (op === 'frame') {
      const slot: number = this.childWebSlotDigit(arg);
      if (slot >= 0 && !this.subWebCmdFrameLogged[slot]) {
        this.subWebCmdFrameLogged[slot] = true;
        hilog.info(DOMAIN, TAG, 'child web cmd: frame %{public}s', arg.replace('\n', '/'));
      }
      return;
    }
    hilog.info(DOMAIN, TAG, 'child web cmd: %{public}s %{public}s', op, arg);
  }

  private onChildWebCommand(op: string, arg: string): void {
    try {
      this.runChildWebCommand(op, arg);
    } catch (commandError) {
      // A web command must never take the page down.
      hilog.error(DOMAIN, TAG, 'child web command failed: %{public}s', (commandError as Error).message);
    }
  }

  private onChildWebEval(script: string, requestId: number): void {
    try {
      const slot: number = this.childWebSlotOf(script);
      if (slot < 0 || !this.childWebSlotReady(slot)) {
        // No page to run on (an engine still being created): answer immediately so the managed
        // caller never waits out its eval timeout.
        this.completeChildWebEval(requestId, '', 1);
        return;
      }
      this.childWebController(slot).runJavaScript(this.childWebSlotPayload(script), (err, result) => {
        this.completeChildWebEval(requestId, result || '', err ? 1 : 0);
      });
    } catch (evalError) {
      hilog.error(DOMAIN, TAG, 'child web eval failed: %{public}s', (evalError as Error).message);
      this.completeChildWebEval(requestId, '', 1);
    }
  }

  private completeChildWebEval(requestId: number, result: string, error: number): void {
    try {
      if (typeof host !== 'undefined' && typeof host.notifyWebEvalResult === 'function') {
        host.notifyWebEvalResult(requestId, result, error);
      }
    } catch (completeError) {
      hilog.error(DOMAIN, TAG, 'child web eval result failed: %{public}s', (completeError as Error).message);
    }
  }

  private runChildWebCommand(op: string, arg: string): void {
    if (op === 'slot') {
      this.applyChildSlotCommand(arg);
      return;
    }
    if (op === 'cookie') {
      // The cookie store is process-wide: setting a cookie here is the same store the main
      // page configures. Only absolute http(s) URLs are accepted (the managed side validates
      // its half too).
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
      // "<requestId>\n<url>"; the value travels back through the eval-result channel.
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
      this.completeChildWebEval(requestId, cookieValue, cookieFailed);
      return;
    }
    if (op === 'hybrid') {
      // MULTIWINDOW-L3: accept the HybridWebView asset registration for this child slot and
      // serve the MAUI hybrid origin from the registered payload directory.
      this.registerChildHybridAssets(arg);
      return;
    }
    if (op === 'blazor') {
      // MULTIWINDOW-L3: accept the BlazorWebView asset registration (hybrid and wasm modes).
      this.registerChildBlazorAssets(arg);
      return;
    }
    if (op === 'hide' && !this.childWebSlotTagged(arg)) {
      // A legacy untagged hide still clears every child overlay; the managed child pool always
      // tags its per-slot commands.
      this.subWebVisible = [false, false];
      return;
    }
    const slot: number = this.childWebSlotOf(arg);
    if (slot < 0 || slot >= SUB_WEB_SLOT_MAX) {
      hilog.warn(DOMAIN, TAG, 'child web command rejected: %{public}s', op);
      return;
    }
    if (!this.childWebSlotReady(slot)) {
      this.deferChildWebOp(slot, op, arg);
      return;
    }
    if (op === 'show') {
      this.subWebVisible[slot] = true;
      this.noteChildWebActivation(slot);
    } else if (op === 'hide') {
      this.subWebVisible[slot] = false;
    } else if (op === 'load') {
      const loadUrl: string = this.childWebSlotPayload(arg);
      this.subWebVisible[slot] = true;
      this.noteChildWebActivation(slot);
      // B6: the managed side asked for this URL; let this one load pass without a round trip.
      this.subNavProgrammatic[slot] = { url: loadUrl, expires: Date.now() + this.subNavPendingTtlMs };
      this.childWebController(slot).loadUrl(loadUrl);
      hilog.info(DOMAIN, TAG, 'child web load (slot %{public}d): %{public}s', slot, loadUrl);
    } else if (op === 'nav') {
      // B6: the managed handler's answer to an intercepted child navigation.
      this.approveChildNavigation(arg);
    } else if (op === 'data') {
      this.subWebVisible[slot] = true;
      this.noteChildWebActivation(slot);
      this.childWebController(slot).loadData(this.childWebSlotPayload(arg), 'text/html', 'UTF-8');
    } else if (op === 'back') {
      const backController: web_webview.WebviewController = this.childWebController(slot);
      if (backController.accessBackward()) {
        backController.backward();
      }
      this.reportChildWebHistory(slot);
    } else if (op === 'forward') {
      const forwardController: web_webview.WebviewController = this.childWebController(slot);
      if (forwardController.accessForward()) {
        forwardController.forward();
      }
      this.reportChildWebHistory(slot);
    } else if (op === 'refresh') {
      this.childWebController(slot).refresh();
      this.reportChildWebHistory(slot);
    } else if (op === 'frame') {
      this.applyChildWebFrame(arg);
    }
  }

  // "ensure\n<slot>" / "destroy\n<slot>" from the managed child pool (mirrors the main page's
  // SLOTS-DYNAMIC lifecycle; every child slot is dynamic, so destroy is always allowed).
  private applyChildSlotCommand(arg: string): void {
    const separator: number = arg.indexOf('\n');
    const action: string = separator > 0 ? arg.substring(0, separator) : arg;
    const slot: number = separator > 0 ? Number.parseInt(arg.substring(separator + 1), 10) : -1;
    if (slot < 0 || slot >= SUB_WEB_SLOT_MAX) {
      hilog.warn(DOMAIN, TAG, 'child web slot rejected: %{public}s', arg);
      return;
    }
    if (action === 'ensure') {
      this.ensureChildWebSlot(slot);
    } else if (action === 'destroy') {
      this.destroyChildWebSlot(slot);
    }
  }

  private ensureChildWebSlot(slot: number): void {
    if (slot < 0 || slot >= SUB_WEB_SLOT_MAX) {
      return;
    }
    if (this.subWebCreated[slot]) {
      return;
    }
    this.subWebCreated[slot] = true;
    if (this.subWebControllers[slot] === null) {
      this.subWebControllers[slot] = new web_webview.WebviewController();
    }
    this.rebuildChildWebSlots(slot, -1);
    hilog.info(DOMAIN, TAG, 'child web slot create: %{public}d', slot);
  }

  private destroyChildWebSlot(slot: number): void {
    if (slot < 0 || slot >= SUB_WEB_SLOT_MAX) {
      return;
    }
    if (!this.subWebCreated[slot]) {
      return;
    }
    this.subWebCreated[slot] = false;
    this.subWebAttached[slot] = false;
    try {
      const controller: web_webview.WebviewController | null = this.subWebControllers[slot];
      if (controller !== null) {
        controller.stop();
      }
    } catch {
      // Stopping a controller with no active load must not fail the removal.
    }
    this.subWebControllers[slot] = null;
    this.rebuildChildWebSlots(-1, slot);
    this.resetChildWebSlotState(slot);
    const emptyPending: SubWebPendingOp[] = [];
    this.subWebPending[slot] = emptyPending;
    hilog.info(DOMAIN, TAG, 'child web slot destroy: %{public}d', slot);
  }

  private rebuildChildWebSlots(addSlot: number, removeSlot: number): void {
    const next: number[] = [];
    for (let i = 0; i < this.subWebSlots.length; i++) {
      const current: number = this.subWebSlots[i];
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
    this.subWebSlots = next;
  }

  private resetChildWebSlotState(slot: number): void {
    this.subWebVisible[slot] = false;
    this.subWebZOrder[slot] = 0;
    this.subWebFrameX[slot] = 0;
    this.subWebFrameY[slot] = 0;
    this.subWebFrameW[slot] = 0;
    this.subWebFrameH[slot] = 0;
    // MULTIWINDOW-L3: the destroyed slot's asset bridge goes with its ArkWeb; the next claim
    // starts with no registration and re-registers from the managed handler.
    this.subHybridBase[slot] = '';
    this.subHybridRoot[slot] = '';
    this.subHybridDefaultFile[slot] = '';
    this.subHybridDocId[slot] = '';
    this.subHybridRegistered[slot] = false;
    this.subHybridServeLogs[slot] = 0;
    this.subBlazorBootstrapped[slot] = false;
    // B6: the destroyed slot's navigation markers/pending decisions go with its ArkWeb, so a
    // delayed approval for the old owner can never reload on the slot's next claim.
    this.subNavProgrammatic[slot] = null;
    this.subNavApproved[slot] = null;
    this.dropPendingChildNavigations(slot);
  }

  // ---------------------------------------------------------------------------------------------
  // MULTIWINDOW-L3: the child hybrid/Blazor asset bridge. The managed slice already routes the
  // "hybrid"/"blazor" registrations and every web command through the child command channel
  // (OpenHarmonyHybridWebViewHandler/OpenHarmonyBlazorWebViewHandler -> OpenHarmonyChildWeb),
  // so this page only has to serve the registrations: intercept the app origins, read the
  // payload files, install the dotnetHost proxy + window.external shim + Blazor bootstrap, and
  // complete the hybrid __hwvInvokeDotNet responses through the child-tagged result sink.
  // ---------------------------------------------------------------------------------------------

  // Registration-time layout guard (mirrors the main page's isSafeLayoutPart): every root /
  // defaultFile segment must be an ordinary relative path, so the <base>/<root>/<path> join can
  // never leave the payload directory.
  private childIsSafeLayoutPart(part: string): boolean {
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

  // Accepts the HybridWebView assets registration for its child slot. Mirrors the main page's
  // registerHybridAssets: the layout is validated and stored, then the hybrid origin is loaded
  // on the slot's controller (deferred until the ArkWeb attaches, like every child command).
  private registerChildHybridAssets(arg: string): void {
    const slot: number = this.childWebRegistrationSlot(arg);
    try {
      const config = JSON.parse(arg) as SubHybridAssetsConfig;
      this.subHybridBase[slot] = config.base.length > 0 ? config.base : '';
      this.subHybridRoot[slot] = config.root.length > 0 ? config.root : '';
      this.subHybridDefaultFile[slot] = config.defaultFile.length > 0 ? config.defaultFile : '';
      this.subHybridDocId[slot] = config.id !== undefined && config.id.length > 0 ? config.id : '';
      const safeLayout: boolean = this.childIsSafeLayoutPart(this.subHybridRoot[slot])
        && this.childIsSafeLayoutPart(this.subHybridDefaultFile[slot]);
      if (!safeLayout) {
        hilog.error(DOMAIN, TAG, 'child hybrid assets rejected: root/defaultFile are not safe relative paths');
      }
      this.subHybridRegistered[slot] = safeLayout && this.subHybridBase[slot].length > 0
        && this.subHybridRoot[slot].length > 0 && this.subHybridDefaultFile[slot].length > 0;
      if (this.subHybridRegistered[slot]) {
        this.subHybridServeLogs[slot] = 0;
        hilog.info(DOMAIN, TAG, 'child hybrid assets: origin=%{public}s root=%{public}s slot=%{public}d',
          SUB_HYBRID_ORIGIN, this.subHybridRoot[slot], slot);
        this.loadChildWebOrigin(slot, SUB_HYBRID_ORIGIN);
      }
    } catch (hybridError) {
      hilog.error(DOMAIN, TAG, 'child hybrid assets registration failed: %{public}s', (hybridError as Error).message);
      this.subHybridRegistered[slot] = false;
    }
  }

  // Accepts the BlazorWebView assets registration (both the Blazor Hybrid mode, which loads the
  // origin, and the "wasm" mode, where the WebView's own Source drives the load).
  private registerChildBlazorAssets(arg: string): void {
    try {
      const config = JSON.parse(arg) as SubBlazorAssetsConfig;
      this.subBlazorBase = config.base.length > 0 ? config.base : '';
      this.subBlazorRoot = config.root.length > 0 ? config.root : '';
      this.subBlazorDefaultFile = config.defaultFile.length > 0 ? config.defaultFile : '';
      this.subBlazorDocId = config.id !== undefined && config.id.length > 0 ? config.id : '';
      this.subBlazorOrigin = config.origin !== undefined && config.origin.length > 0
        ? config.origin
        : SUB_BLAZOR_ORIGIN_DEFAULT;
      if (!this.subBlazorOrigin.endsWith('/')) {
        this.subBlazorOrigin = `${this.subBlazorOrigin}/`;
      }
      this.subBlazorWasmMode = config.mode === 'wasm';
      this.subBlazorServeLogs = 0;
      const safeLayout: boolean = this.childIsSafeLayoutPart(this.subBlazorRoot)
        && this.childIsSafeLayoutPart(this.subBlazorDefaultFile);
      if (!safeLayout) {
        hilog.error(DOMAIN, TAG, 'child blazor assets rejected: root/defaultFile are not safe relative paths');
      }
      this.subBlazorRegistered = safeLayout && this.subBlazorBase.length > 0
        && this.subBlazorRoot.length > 0 && this.subBlazorDefaultFile.length > 0;
      if (this.subBlazorRegistered) {
        hilog.info(DOMAIN, TAG, 'child blazor assets: origin=%{public}s root=%{public}s mode=%{public}s',
          this.subBlazorOrigin, this.subBlazorRoot, this.subBlazorWasmMode ? 'wasm' : 'hybrid');
        if (!this.subBlazorWasmMode) {
          this.loadChildWebOrigin(this.childWebRegistrationSlot(arg), this.subBlazorOrigin);
        }
      }
    } catch (blazorError) {
      hilog.error(DOMAIN, TAG, 'child blazor assets registration failed: %{public}s', (blazorError as Error).message);
      this.subBlazorRegistered = false;
    }
  }

  // Shows the slot and loads the origin: directly when its ArkWeb is attached, otherwise as a
  // deferred "load" command replayed from onControllerAttached.
  private loadChildWebOrigin(slot: number, url: string): void {
    if (slot < 0 || slot >= SUB_WEB_SLOT_MAX) {
      return;
    }
    this.subWebVisible[slot] = true;
    this.noteChildWebActivation(slot);
    if (this.childWebSlotReady(slot)) {
      this.childWebController(slot).loadUrl(url);
      return;
    }
    this.deferChildWebOp(slot, 'load', `s${slot}\n${url}`);
  }

  // Resolves an app-origin URL to an absolute file below the payload directory (mirrors the
  // main page's hybridFilePath). Unknown/malformed paths (including traversal attempts) return
  // '' and are answered with 404; the hybrid bootstrap script is served next to the payload.
  private childHybridFilePath(url: string, slot: number): string {
    let path: string = this.childUrlPath(url);
    if (path === '$bad') {
      return '';
    }
    if (path.length === 0) {
      path = this.subHybridDefaultFile[slot];
    }
    if (path === '_framework/hybridwebview.js') {
      return `${this.subHybridBase[slot]}/${path}`;
    }
    return `${this.subHybridBase[slot]}/${this.subHybridRoot[slot]}/${path}`;
  }

  // Resolves a Blazor app-origin URL to <base>/<root>/<path> (every file, blazor.webview.js
  // included, lives below the content root).
  private childBlazorFilePath(url: string): string {
    let path: string = this.childUrlPath(url);
    if (path === '$bad') {
      return '';
    }
    if (path.length === 0) {
      path = this.subBlazorDefaultFile;
    }
    return `${this.subBlazorBase}/${this.subBlazorRoot}/${path}`;
  }

  // The validated path part of an app-origin URL, or the '' marker when it is malformed. The
  // '$bad' sentinel distinguishes rejection from the legitimate empty path (the default file).
  private childUrlPath(url: string): string {
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
      return '$bad';
    }
    while (path.startsWith('/')) {
      path = path.substring(1);
    }
    if (path.indexOf('..') >= 0 || path.indexOf('\\') >= 0) {
      return '$bad';
    }
    return path;
  }

  private childHybridMimeType(filePath: string): string {
    const lower: string = filePath.toLowerCase();
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

  private childHybridErrorResponse(code: number): WebResourceResponse {
    const response: WebResourceResponse = new WebResourceResponse();
    response.setResponseCode(code);
    response.setResponseMimeType('text/plain');
    response.setResponseEncoding('utf-8');
    if (code !== 204) {
      response.setResponseData(code === 404 ? 'Not Found' : 'Bad Request');
    }
    return response;
  }

  // .NET static-web-asset fingerprint mapping (W10, same conservative grammar as the main
  // page): the boot scripts request the base name while the publish carries the fingerprinted
  // one, and vice versa.
  private childStaticFingerprintBase(filePath: string): string {
    const slash: number = filePath.lastIndexOf('/');
    const nameStart: number = slash + 1;
    const dot: number = filePath.lastIndexOf('.');
    if (dot <= nameStart) {
      return filePath;
    }
    const stem: string = filePath.substring(nameStart, dot);
    const extension: string = filePath.substring(dot);
    const match = new RegExp('^(.+)\\.[0-9a-z]{10}$').exec(stem);
    if (match === null) {
      return filePath;
    }
    return `${filePath.substring(0, nameStart)}${match[1]}${extension}`;
  }

  private childStaticFingerprintFile(filePath: string): string | undefined {
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

  private childPayloadCacheHeaders(fingerprinted: boolean): Header[] {
    const headers: Header[] = [{
      headerKey: 'Cache-Control',
      headerValue: fingerprinted ? 'public, max-age=31536000, immutable' : 'no-cache',
    }];
    return headers;
  }

  private childReadPayloadFile(filePath: string, fingerprinted: boolean): WebResourceResponse | undefined {
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
      response.setResponseMimeType(this.childHybridMimeType(filePath));
      response.setResponseEncoding('utf-8');
      response.setResponseData(buffer);
      response.setResponseHeader(this.childPayloadCacheHeaders(fingerprinted));
      return response;
    } catch {
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

  private childServePayloadFile(filePath: string): WebResourceResponse {
    if (filePath.length === 0) {
      return this.childHybridErrorResponse(404);
    }
    const baseFile: string = this.childStaticFingerprintBase(filePath);
    const fingerprinted: boolean = baseFile !== filePath;
    const exact: WebResourceResponse | undefined = this.childReadPayloadFile(filePath, fingerprinted);
    if (exact !== undefined) {
      return exact;
    }
    if (fingerprinted) {
      const fallback: WebResourceResponse | undefined = this.childReadPayloadFile(baseFile, true);
      if (fallback !== undefined) {
        return fallback;
      }
    } else {
      const resolved: string | undefined = this.childStaticFingerprintFile(filePath);
      if (resolved !== undefined) {
        const mapped: WebResourceResponse | undefined = this.childReadPayloadFile(resolved, true);
        if (mapped !== undefined) {
          return mapped;
        }
      }
    }
    return this.childHybridErrorResponse(404);
  }

  private childServeHybridFile(url: string, slot: number): WebResourceResponse {
    return this.childServePayloadFile(this.childHybridFilePath(url, slot));
  }

  private childServeBlazorFile(url: string): WebResourceResponse {
    return this.childServePayloadFile(this.childBlazorFilePath(url));
  }

  // Installs the dotnetHost proxy on the slot's controller (the page scripts' JS -> .NET
  // channel) and forwards its payloads with the document-origin envelope the managed handlers
  // validate by document id - the child window needs no dedicated message export.
  private registerChildDotNetHost(slot: number): void {
    try {
      this.childWebController(slot).registerJavaScriptProxy({
        postMessage: (payload: string): void => {
          // Same frame guard as the main page: ArkWeb registers the proxy into every frame, so
          // a known non-empty caller URL that is not the main document's is dropped (empty/
          // unknown values fail open, matching the main page's documented semantics).
          let callerUrl: string = '';
          try {
            if (typeof this.childWebController(slot).getLastJavascriptProxyCallingFrameUrl === 'function') {
              callerUrl = this.childWebController(slot).getLastJavascriptProxyCallingFrameUrl();
            }
          } catch {
            callerUrl = '';
          }
          if (typeof callerUrl === 'string' && callerUrl.length > 0) {
            let mainUrl: string = '';
            try {
              mainUrl = this.childWebController(slot).getUrl();
            } catch {
              mainUrl = '';
            }
            if (callerUrl !== mainUrl) {
              return;
            }
          }
          this.notifyChildJsMessage(payload, slot);
        }
      }, 'dotnetHost', ['postMessage']);
    } catch (proxyError) {
      hilog.error(DOMAIN, TAG, 'child dotnetHost proxy registration failed (slot %{public}d): %{public}s',
        slot, (proxyError as Error).message);
    }
  }

  private notifyChildJsMessage(payload: string, slot: number): void {
    try {
      if (typeof host !== 'undefined' && typeof host.notifyJsMessage === 'function') {
        host.notifyJsMessage(this.childOriginEnvelope(payload, slot));
      }
    } catch (messageError) {
      hilog.error(DOMAIN, TAG, 'child js message failed: %{public}s', (messageError as Error).message);
    }
  }

  private childOriginEnvelope(payload: string, slot: number): string {
    let url: string = '';
    try {
      url = this.childWebController(slot).getUrl();
    } catch {
      url = '';
    }
    let documentId: string = '';
    if (this.subHybridRegistered[slot] && this.subHybridDocId[slot].length > 0
        && url.startsWith(SUB_HYBRID_ORIGIN)) {
      documentId = this.subHybridDocId[slot];
    } else if (this.subBlazorRegistered && this.subBlazorDocId.length > 0 && url.startsWith(this.subBlazorOrigin)) {
      documentId = this.subBlazorDocId;
    }
    return `__OHORIGIN|${url}|${documentId}\n${payload}`;
  }

  // Per-document marker + window.external shim (mirrors the main page's injectPageBridge): the
  // managed handlers only accept messages from a document carrying the id the shell stamped.
  private injectChildPageBridge(slot: number, pageUrl: string): void {
    let markers: string = '';
    if (this.subHybridRegistered[slot] && this.subHybridDocId[slot].length > 0
        && pageUrl.startsWith(SUB_HYBRID_ORIGIN)) {
      markers += `window.__ohHybridId = ${JSON.stringify(this.subHybridDocId[slot])};`;
    }
    if (this.subBlazorRegistered && this.subBlazorDocId.length > 0 && pageUrl.startsWith(this.subBlazorOrigin)) {
      markers += `window.__ohBlazorId = ${JSON.stringify(this.subBlazorDocId)};`;
    }
    try {
      this.childWebController(slot).runJavaScript(
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
              }
            };
          }
          if (typeof external.receiveMessage !== 'function') {
            external.receiveMessage = function (payload) {
              try {
                window.dispatchEvent(new CustomEvent('HybridWebViewMessageReceived', { detail: { message: payload } }));
              } catch (receiveError) {
              }
            };
          }
        })();`,
        () => {
          // The bridge is best-effort; a page that cannot run it keeps dotnetHost only.
        });
    } catch (bridgeError) {
      hilog.error(DOMAIN, TAG, 'child page bridge failed (slot %{public}d): %{public}s',
        slot, (bridgeError as Error).message);
    }
  }

  private childIsBlazorRootDocument(pageUrl: string): boolean {
    let url: string = pageUrl;
    const query: number = url.indexOf('?');
    if (query >= 0) {
      url = url.substring(0, query);
    }
    const fragment: number = url.indexOf('#');
    if (fragment >= 0) {
      url = url.substring(0, fragment);
    }
    return url === this.subBlazorOrigin || url === `${this.subBlazorOrigin}${this.subBlazorDefaultFile}`;
  }

  // Blazor bootstrap (callback-form window.external.receiveMessage + __dispatchMessageCallback
  // + Blazor.start()), mirroring the main page. A "wasm" registration is skipped: that site
  // ships its own bootstrap.
  private injectChildBlazorBootstrap(slot: number, pageUrl: string): void {
    if (!this.subBlazorRegistered || this.subBlazorWasmMode || this.subBlazorBootstrapped[slot]
        || !this.childIsBlazorRootDocument(pageUrl)) {
      return;
    }
    this.subBlazorBootstrapped[slot] = true;
    const scriptUrl: string = `${this.subBlazorOrigin}_framework/blazor.webview.js`;
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
      this.childWebController(slot).runJavaScript(bootstrap, () => {
        // Best effort; a page without Blazor keeps running.
      });
    } catch (bootError) {
      hilog.error(DOMAIN, TAG, 'child blazor bootstrap failed (slot %{public}d): %{public}s',
        slot, (bootError as Error).message);
    }
  }

  // The hybrid endpoints are POSTed by the served document (stock hybridwebview.js transport);
  // the same same-origin check as the main page guards them (a cross-site iframe carries its
  // own Origin and stays refused).
  private childHybridEndpointAllowed(event: OnInterceptRequestEvent): boolean {
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
      const originName: string = SUB_HYBRID_ORIGIN.endsWith('/')
        ? SUB_HYBRID_ORIGIN.substring(0, SUB_HYBRID_ORIGIN.length - 1)
        : SUB_HYBRID_ORIGIN;
      if (origin === originName && (fetchSite.length === 0 || fetchSite === 'same-origin')) {
        return true;
      }
      return referer.startsWith(SUB_HYBRID_ORIGIN);
    } catch {
      return false;
    }
  }

  private childHybridInvokeErrorPayload(message: string): string {
    const payload: SubHybridInvokeErrorResult = { IsError: true, ErrorMessage: message };
    return JSON.stringify(payload);
  }

  // A completed 200 response carrying the invoke error payload: the page's fetch resolves and
  // the stock invokeDotNet code rejects with ErrorMessage (the same shape as a managed error).
  private childHybridInvokeReadyError(message: string): WebResourceResponse {
    const response: WebResourceResponse = new WebResourceResponse();
    response.setResponseCode(200);
    response.setResponseMimeType('application/json');
    response.setResponseEncoding('utf-8');
    response.setResponseData(this.childHybridInvokeErrorPayload(message));
    return response;
  }

  // Defers to the next tick on the UI thread (the main page's runOnUiThread): the intercepted
  // response must be returned first; its data is only written after onInterceptRequest returned.
  private runChildOnUiThread(task: () => void): void {
    setTimeout(() => {
      this.getUIContext().runScopedTask(task);
    }, 0);
  }

  // Completes a held-open __hwvInvokeDotNet response once (setResponseIsReady(false) ->
  // setResponseData -> setResponseIsReady(true), always on the next tick through runOnUiThread).
  private completeChildHybridInvoke(requestId: number, payload: string): void {
    const pending: SubHybridPendingInvoke | undefined = this.subHybridInvokes.get(requestId);
    if (pending === undefined) {
      return;
    }
    this.subHybridInvokes.delete(requestId);
    clearTimeout(pending.timer);
    this.runChildOnUiThread(() => {
      try {
        pending.response.setResponseData(payload);
        pending.response.setResponseCode(200);
        pending.response.setReasonMessage('OK');
        pending.response.setResponseIsReady(true);
      } catch (completeError) {
        hilog.error(DOMAIN, TAG, 'child hybrid invoke response failed: %{public}s', (completeError as Error).message);
      }
    });
  }

  // JS -> .NET invocation endpoint: { MethodName, ParamValues } POSTed to the hybrid origin.
  // The request id carries the child-window tag (bit 30) so the managed slice routes it to this
  // window's HybridWebView and the native module returns the result to this page's sink.
  private childHybridInvokeResponse(event: OnInterceptRequestEvent, slot: number): WebResourceResponse {
    if (!this.childHybridEndpointAllowed(event)) {
      if (this.subHybridEndpointLogs < 3) {
        this.subHybridEndpointLogs++;
        hilog.error(DOMAIN, TAG, 'child hybrid invoke request refused (slot %{public}d)', slot);
      }
      return this.childHybridErrorResponse(400);
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
      return this.childHybridErrorResponse(400);
    }
    let method: string = '';
    let argsJson: string = '[]';
    try {
      const data = JSON.parse(body) as SubHybridInvokeRequest;
      if (data.MethodName !== undefined) {
        method = data.MethodName;
      }
      if (data.ParamValues !== undefined) {
        argsJson = JSON.stringify(data.ParamValues);
      }
    } catch {
      return this.childHybridErrorResponse(400);
    }
    if (method.length === 0) {
      return this.childHybridErrorResponse(400);
    }
    // A host library without the child result sink cannot route this page's result (the primary
    // sink belongs to pages/Index.ets): answer an immediate error payload instead of tagging an
    // invocation the managed side would fall back to its last primary handler for.
    if (typeof host === 'undefined' || typeof host.registerChildHybridInvokeResultSink !== 'function') {
      return this.childHybridInvokeReadyError('the .NET host does not expose the child hybrid invocation bridge');
    }
    const response: WebResourceResponse = new WebResourceResponse();
    response.setResponseCode(200);
    response.setResponseMimeType('application/json');
    response.setResponseEncoding('utf-8');
    response.setResponseIsReady(false);
    // Child-tagged request id: bit 30 | window bit 29 for the second subwindow | ((slot + 1) << 24)
    // | (sequence & 0xFFFFFF). Bit 30 is the OpenHarmonyOverlays.ChildInvokeFlag contract; bit 29
    // (M4) marks the second child window so the managed dispatch picks the right window's handler
    // even when both windows own the same child slot, and the native module routes the result back
    // to this page's own sink.
    this.subHybridInvokeSeq = (this.subHybridInvokeSeq + 1) & 0xFFFFFF;
    const windowBit: number = this.childWindowIndex() > 0 ? 0x20000000 : 0;
    const requestId: number = 0x40000000 | windowBit | ((slot + 1) << 24) | this.subHybridInvokeSeq;
    const timer: number = setTimeout(() => {
      this.completeChildHybridInvoke(requestId,
        this.childHybridInvokeErrorPayload('the .NET invocation timed out'));
    }, this.subHybridInvokeTimeoutMs);
    this.subHybridInvokes.set(requestId, { response: response, timer: timer });
    try {
      const rc: number = host.notifyHybridInvoke(requestId, method, argsJson) as number;
      if (rc !== 0) {
        this.completeChildHybridInvoke(requestId,
          this.childHybridInvokeErrorPayload('the .NET host is not listening for hybrid invocations'));
      }
    } catch (invokeError) {
      hilog.error(DOMAIN, TAG, 'child hybrid invoke failed: %{public}s', (invokeError as Error).message);
      this.completeChildHybridInvoke(requestId,
        this.childHybridInvokeErrorPayload('the .NET host does not expose the hybrid invocation bridge'));
    }
    return response;
  }

  // __hwvSendMessage transport: the payload header is handed to the JS message sink with this
  // page's origin envelope, so SendRawMessage reaches the managed handler like the main page.
  private childHybridMessageResponse(event: OnInterceptRequestEvent, slot: number): WebResourceResponse {
    if (!this.childHybridEndpointAllowed(event)) {
      return this.childHybridErrorResponse(400);
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
      return this.childHybridErrorResponse(400);
    }
    let delivered: boolean = false;
    try {
      if (typeof host !== 'undefined' && typeof host.notifyJsMessage === 'function') {
        host.notifyJsMessage(this.childOriginEnvelope(body, slot));
        delivered = true;
      }
    } catch {
      delivered = false;
    }
    return this.childHybridErrorResponse(delivered ? 204 : 400);
  }

  private deferChildWebOp(slot: number, op: string, arg: string): void {
    const pending: SubWebPendingOp[] = this.subWebPending[slot];
    if (pending.length >= SUB_WEB_SLOT_PENDING_MAX) {
      hilog.error(DOMAIN, TAG, 'child web defer overflow: %{public}d %{public}s', slot, op);
      return;
    }
    pending.push({ op: op, arg: arg });
    hilog.info(DOMAIN, TAG, 'child web defer: %{public}d %{public}s', slot, op);
    this.ensureChildWebSlot(slot);
  }

  private flushChildWebOps(slot: number): void {
    const pending: SubWebPendingOp[] = this.subWebPending[slot];
    if (pending.length === 0) {
      return;
    }
    const emptyPending: SubWebPendingOp[] = [];
    this.subWebPending[slot] = emptyPending;
    for (const item of pending) {
      this.runChildWebCommand(item.op, item.arg);
    }
  }

  private childWebController(slot: number): web_webview.WebviewController {
    let controller: web_webview.WebviewController | null = this.subWebControllers[slot];
    if (controller === null) {
      controller = new web_webview.WebviewController();
      this.subWebControllers[slot] = controller;
    }
    return controller;
  }

  private childWebSlotReady(slot: number): boolean {
    return slot >= 0 && slot < SUB_WEB_SLOT_MAX && this.subWebCreated[slot] && this.subWebAttached[slot];
  }

  // The child wire keeps the main page's "s<slot>" / "s<slot>\n<payload>" codec; an untagged
  // argument answers -1 (rejected) instead of falling back to slot 0, so a malformed command
  // cannot land on the first child overlay.
  private childWebSlotDigit(arg: string): number {
    if (arg.length >= 2 && arg.charAt(0) === 's') {
      const slot: number = arg.charCodeAt(1) - 0x30;
      if (slot >= 0 && slot < SUB_WEB_SLOT_MAX && (arg.length === 2 || arg.charAt(2) === '\n')) {
        return slot;
      }
    }
    return -1;
  }

  private childWebSlotOf(arg: string): number {
    return this.childWebSlotDigit(arg);
  }

  private childWebSlotTagged(arg: string): boolean {
    return this.childWebSlotDigit(arg) >= 0;
  }

  private childWebSlotPayload(arg: string): string {
    const slot: number = this.childWebSlotDigit(arg);
    return slot >= 0 && arg.length > 2 ? arg.substring(3) : arg;
  }

  // The slot named by a hybrid/blazor registration JSON; a missing/malformed slot falls back to
  // 0 exactly like the main page (the registration still has to name a safe layout).
  private childWebRegistrationSlot(arg: string): number {
    try {
      const config = JSON.parse(arg) as SubHybridAssetsConfig;
      if (config.slot !== undefined && config.slot >= 0 && config.slot < SUB_WEB_SLOT_MAX) {
        return config.slot;
      }
    } catch {
      // A malformed registration falls back to slot 0.
    }
    return 0;
  }

  // WebView PlatformArrange: "s<slot>\nx\ny\nw\nh" in device pixels, converted to vp like the
  // main page (a degenerate frame is ignored). A frame also shows the overlay.
  private applyChildWebFrame(arg: string): void {
    const slot: number = this.childWebSlotDigit(arg);
    if (slot < 0) {
      return;
    }
    const payload: string = this.childWebSlotPayload(arg);
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
    this.subWebFrameX[slot] = xVp;
    this.subWebFrameY[slot] = yVp;
    this.subWebFrameW[slot] = wVp;
    this.subWebFrameH[slot] = hVp;
    this.subWebVisible[slot] = true;
    this.noteChildWebActivation(slot);
  }

  private noteChildWebActivation(slot: number): void {
    this.subWebZOrderSeq++;
    this.subWebZOrder[slot] = this.subWebZOrderSeq;
  }

  private reportChildWebHistory(slot: number): void {
    let canBack: boolean = false;
    let canForward: boolean = false;
    try {
      const controller: web_webview.WebviewController = this.childWebController(slot);
      canBack = controller.accessBackward();
      canForward = controller.accessForward();
    } catch {
      return;
    }
    this.notifyWebHostState(this.childWebEventState(slot, `history|${canBack ? 1 : 0}|${canForward ? 1 : 0}`), '');
  }

  // ---------------------------------------------------------------------------------------------
  // MULTIWINDOW-L3 B6: the child navigation allow-list (the child counterpart of the primary
  // page's onLoadIntercept gateway). A main-frame load this page did not originate is cancelled
  // and handed to the managed handler for a Navigating decision; the URL stays here under an
  // unguessable id and only the managed "nav" answer (same id, same slot, same URL) may reload
  // it. The ask travels on the child web-event channel ("w:<surface>|s<slot>|navask|<id>", URL
  // in the event URL slot) because a subwindow cannot reach the primary __OHNAV channel; the
  // answer arrives as a child command ("nav") through this window's own sink.
  // ---------------------------------------------------------------------------------------------

  // True when a child load is app-internal: the same fast paths as the primary page (H-C2 first,
  // so "//host" never counts) plus this slot's own registered hybrid/Blazor origins.
  private isChildAppNavigation(slot: number, url: string): boolean {
    if (url.length === 0) {
      return true;
    }
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
    if (this.subHybridRegistered[slot] && url.startsWith(SUB_HYBRID_ORIGIN)) {
      return true;
    }
    if (this.subBlazorRegistered && url.startsWith(this.subBlazorOrigin)) {
      return true;
    }
    return false;
  }

  // B6: consumes the one-shot marker for a load this page itself requested (managed "load") or
  // the managed handler approved. Exactly that reload passes onLoadIntercept once.
  private consumeChildApprovedNavigation(slot: number, url: string): boolean {
    const now: number = Date.now();
    const programmatic: SubWebApprovedNavigation | null = this.subNavProgrammatic[slot];
    if (programmatic !== null && programmatic.expires >= now && programmatic.url === url) {
      this.subNavProgrammatic[slot] = null;
      return true;
    }
    const approved: SubWebApprovedNavigation | null = this.subNavApproved[slot];
    if (approved !== null && approved.expires >= now && approved.url === url) {
      this.subNavApproved[slot] = null;
      return true;
    }
    return false;
  }

  // B6: retires a marker once the approved/requested load actually started, so a later
  // page-initiated navigation to the same URL is asked about again.
  private retireChildNavigationMarker(url: string, slot: number): void {
    const programmatic: SubWebApprovedNavigation | null = this.subNavProgrammatic[slot];
    if (programmatic !== null && programmatic.url === url) {
      this.subNavProgrammatic[slot] = null;
    }
    const approved: SubWebApprovedNavigation | null = this.subNavApproved[slot];
    if (approved !== null && approved.url === url) {
      this.subNavApproved[slot] = null;
    }
  }

  private dropPendingChildNavigations(slot: number): void {
    const stale: string[] = [];
    this.subNavPending.forEach((pending: SubWebPendingNavigation, id: string): void => {
      if (pending.slot === slot) {
        stale.push(id);
      }
    });
    for (const id of stale) {
      this.subNavPending.delete(id);
    }
  }

  // B6: asks the managed handler for a decision on a cancelled child load. The pending table is
  // bounded (oldest dropped when full) and every entry expires; without a host channel nothing
  // can approve the load, so it stays cancelled (fail closed).
  private askManagedAboutChildNavigation(slot: number, url: string): void {
    const now: number = Date.now();
    this.subNavPending.forEach((pending: SubWebPendingNavigation, id: string): void => {
      if (pending.expires < now) {
        this.subNavPending.delete(id);
      }
    });
    while (this.subNavPending.size >= this.subNavPendingLimit) {
      const oldest: string | undefined = this.subNavPending.keys().next().value;
      if (oldest === undefined) {
        break;
      }
      this.subNavPending.delete(oldest);
    }
    let id: string = '';
    try {
      id = util.generateRandomUUID(true);
    } catch {
      id = `${now.toString(16)}-${Math.random().toString(16).substring(2)}`;
    }
    this.subNavPending.set(id, { url: url, expires: now + this.subNavPendingTtlMs, slot: slot });
    hilog.info(DOMAIN, TAG, 'child web nav ask (slot %{public}d): %{public}s', slot, url);
    this.notifyWebHostState(this.childWebEventState(slot, `${SUB_WEB_NAV_ASK_PREFIX}${id}`), url);
  }

  // B6: the managed answer ("nav", "s<slot>\n<id>\n<url>"). The URL must be the exact one this
  // page cancelled for that id on that slot, and the approval is one-shot: only the reload that
  // follows may pass onLoadIntercept.
  private approveChildNavigation(arg: string): void {
    const slot: number = this.childWebSlotOf(arg);
    if (slot < 0) {
      return;
    }
    const tagged: string = this.childWebSlotPayload(arg);
    const separator: number = tagged.indexOf('\n');
    const id: string = separator >= 0 ? tagged.substring(0, separator) : tagged;
    const url: string = separator >= 0 ? tagged.substring(separator + 1) : '';
    const pending: SubWebPendingNavigation | undefined = this.subNavPending.get(id);
    if (pending === undefined) {
      return;
    }
    this.subNavPending.delete(id);
    if (pending.expires < Date.now() || pending.url !== url || pending.slot !== slot) {
      return;
    }
    this.subNavApproved[slot] = { url: pending.url, expires: Date.now() + this.subNavPendingTtlMs };
    hilog.info(DOMAIN, TAG, 'child web nav approved (slot %{public}d): %{public}s', slot, pending.url);
    try {
      this.childWebController(slot).loadUrl(pending.url);
    } catch {
      // The reload failed (e.g., the controller detached); the navigation stays cancelled.
    }
  }

  // The child ArkWeb declaration, instantiated once per declared slot (created on demand by
  // ensureChildWebSlot and removed by destroyChildWebSlot). Declared after the managed
  // XComponent so the web content composites above the second MAUI tree.
  @Builder
  subWebOverlay(slot: number): void {
    Web({ src: '', controller: this.childWebController(slot) })
      .domStorageAccess(true)
      .visibility(this.subWebVisible[slot] ? Visibility.Visible : Visibility.None)
      .zIndex(this.subWebZOrder[slot])
      .width(this.subWebFrameW[slot] > 0 ? `${this.subWebFrameW[slot]}vp` : '100%')
      .height(this.subWebFrameH[slot] > 0 ? `${this.subWebFrameH[slot]}vp` : '100%')
      .position({ x: this.subWebFrameX[slot], y: this.subWebFrameY[slot] })
      .onControllerAttached(() => {
        this.subWebAttached[slot] = true;
        hilog.info(DOMAIN, TAG, 'child web attached: slot %{public}d', slot);
        // MULTIWINDOW-L3: the page scripts' dotnetHost proxy; registering any earlier fails
        // with BusinessError 17100001 (controller not associated with a Web component).
        this.registerChildDotNetHost(slot);
        this.flushChildWebOps(slot);
      })
      .onLoadIntercept((event) => {
        // B6 navigation allow-list (child counterpart of the primary page): a top-level load
        // this page did not originate is cancelled and decided by the managed handler's
        // Navigating event. Frames/subresources, the app's own origins and the one-shot
        // approved/requested reloads keep loading unchanged.
        try {
          if (!event.data.isMainFrame()) {
            return false;
          }
          const url: string = event.data.getRequestUrl();
          if (this.isChildAppNavigation(slot, url)) {
            return false;
          }
          if (this.consumeChildApprovedNavigation(slot, url)) {
            return false;
          }
          if (url.length === 0 || url.length > this.subNavMaxUrlLength) {
            // Nothing to hand over (or too large to copy): the load stays blocked.
            return true;
          }
          this.askManagedAboutChildNavigation(slot, url);
          return true;
        } catch {
          // An unexpected event shape must not take the page down; allow the load.
          return false;
        }
      })
      .onPageBegin((event) => {
        // MULTIWINDOW-L3: a new main-frame document gets its own Blazor bootstrap.
        this.subBlazorBootstrapped[slot] = false;
        const startedUrl: string = event ? event.url : '';
        // B6: the approved/app-requested load started; its one-shot marker is used up.
        this.retireChildNavigationMarker(startedUrl, slot);
        this.notifyWebHostState(this.childWebEventState(slot, 'started'), startedUrl);
      })
      .onPageEnd((event) => {
        const pageUrl: string = event ? event.url : '';
        hilog.info(DOMAIN, TAG, 'child web page (slot %{public}d): %{public}s', slot, pageUrl);
        this.notifyWebHostState(this.childWebEventState(slot, 'finished'), pageUrl);
        // MULTIWINDOW-L3: stamp this document's registration id and install the bridge/bootstrap
        // (the managed handlers only accept messages from a document carrying their id).
        this.injectChildPageBridge(slot, pageUrl);
        this.injectChildBlazorBootstrap(slot, pageUrl);
        this.reportChildWebHistory(slot);
      })
      .onInterceptRequest((event) => {
        // MULTIWINDOW-L3: serve the registered app origins from the payload directory. The
        // hybrid endpoints (__hwvInvokeDotNet/__hwvSendMessage) complete through the managed
        // handler; every other URL is left to the engine.
        try {
          const url: string = event.request.getRequestUrl();
          if (this.subBlazorRegistered && url.startsWith(this.subBlazorOrigin)) {
            if (this.subBlazorServeLogs < 3) {
              this.subBlazorServeLogs++;
              hilog.info(DOMAIN, TAG, 'child web serve blazor: %{public}s', url);
            }
            return this.childServeBlazorFile(url);
          }
          if (!this.subHybridRegistered[slot] || !url.startsWith(SUB_HYBRID_ORIGIN)) {
            return null;
          }
          if (this.subHybridServeLogs[slot] < 3) {
            this.subHybridServeLogs[slot]++;
            hilog.info(DOMAIN, TAG, 'child web serve hybrid (slot %{public}d): %{public}s', slot, url);
          }
          if (url.startsWith(`${SUB_HYBRID_ORIGIN}__hwvInvokeDotNet`)) {
            return this.childHybridInvokeResponse(event, slot);
          }
          if (url.startsWith(`${SUB_HYBRID_ORIGIN}__hwvSendMessage`)) {
            return this.childHybridMessageResponse(event, slot);
          }
          return this.childServeHybridFile(url, slot);
        } catch {
          return null;
        }
      })
      .onErrorReceive((event) => {
        try {
          if (event && event.request && !event.request.isMainFrame()) {
            return;
          }
          const errorUrl: string = event && event.request ? event.request.getRequestUrl() : '';
          hilog.error(DOMAIN, TAG, 'child web error (slot %{public}d): %{public}s', slot, errorUrl);
          this.notifyWebHostState(this.childWebEventState(slot, 'error'), errorUrl);
        } catch {
          // An unexpected event shape must not take the page down.
        }
      })
      .onTouch((event: TouchEvent) => {
        // A user touch activates the overlay (z-order); the event is not consumed.
        if (event.type === TouchType.Down) {
          this.noteChildWebActivation(slot);
          this.notifyWebHostState(this.childWebEventState(slot, 'activate'), '');
        }
      })
  }

  aboutToDisappear(): void {
    // MULTIWINDOW-L3 M4: this page's child web sinks die with the page (the window may be
    // closed while another stays open; the native already drops commands for a closed window).
    this.unregisterChildWebHost();
    // The child dies with the page; report the state so the managed side does not keep an open
    // subwindow (the main page's windowEvent observer usually reports first).
    this.notifyHost(SUB_EVENT_CLOSED, this.readyPayload());
  }

  // M4: the system Back on the child page. The event channel is one-way (no synchronous
  // consume answer), so the notification is advisory and the platform default still runs; a
  // per-window consumer receives it through OpenHarmonyWindowInputRouter.Back.
  onBackPress(): boolean {
    this.notifyHost(SUB_EVENT_BACK, this.readyPayload());
    return false;
  }

  build() {
    Stack() {
      // MULTIWINDOW-L M4: the child's own hidden text input (declared before the XComponent so
      // the managed surface composites above it). The managed second window focuses it through
      // the AppStorage request channel; its text/keys travel to the managed side tagged with
      // this window's surface id, so the two windows never share keyboard state. M2: mounted
      // only after the shell confirmed this page's identity.
      if (this.surfaceId.length > 0 && this.identityConfirmed) {
        TextInput({ text: this.inputText, controller: this.inputController })
          .id(this.inputControlId())
          .height(56)
          .position({ x: 0, y: 0 })
          .onChange((value: string, previewText?: PreviewText): void => {
            this.inputText = value;
            this.notifyHost(SUB_EVENT_TEXT, this.textPayload(value));
            const composition: SubWindowCompositionPayload = {
              surfaceId: this.surfaceId,
              value: this.previewTextValue(previewText),
              offset: this.previewTextOffset(previewText),
            };
            this.notifyHost(SUB_EVENT_TEXT_COMPOSITION, JSON.stringify(composition));
          })
          .onSubmit((): void => {
            this.notifyHost(SUB_EVENT_TEXT_SUBMITTED, this.textPayload(this.inputText));
          })
      }

      // MULTIWINDOW-L M3 managed surface: the XComponent fills the child and the managed second
      // MAUI tree draws into it; the native host routes its input under the same window id. M4
      // adds the focusable/onKeyEvent half: hardware keys pressed while the child surface has
      // focus are forwarded tagged with this window's id. M2: mounted only after the shell
      // confirmed this page's identity handshake (fail-closed otherwise).
      if (this.surfaceId.length > 0 && this.identityConfirmed) {
        XComponent({
          id: this.surfaceId,
          type: XComponentType.SURFACE,
          libraryname: 'openharmonyhost',
        })
          .focusable(true)
          .onKeyEvent((event: KeyEvent): void => {
            const keyPayload: SubWindowKeyPayload = {
              surfaceId: this.surfaceId,
              code: event.keyCode,
              type: event.type === KeyType.Down ? 0 : 1,
            };
            this.notifyHost(SUB_EVENT_KEY, JSON.stringify(keyPayload));
          })
          .onLoad((): void => {
            this.bindSurface();
          })
          .onDestroy((): void => {
            this.unbindSurface();
          })
          .width('100%')
          .height('100%')
      }

      // MULTIWINDOW-L2 a: the child's accessibility ContentSlot (the host adds the per-instance
      // CUSTOM node to it), declared after the XComponent like the main page. The CUSTOM node is
      // non-visual, so it never intercepts the managed surface's input.
      ContentSlot(this.content)

      // MULTIWINDOW-L2 child ArkWeb host: instantiated per declared slot from the @State list,
      // so a claim creates its ArkWeb on demand (ensureChildWebSlot) and "slot destroy" tears it
      // down. Declared after the managed XComponent: a Stack composites later children above
      // earlier ones, so the child web content really shows over the second MAUI tree.
      if (this.subWebSlots.length > 0) {
        ForEach(this.subWebSlots, (slot: number) => {
          this.subWebOverlay(slot)
        }, (slot: number): string => `sub-web-slot-${slot}`)
      }

      // MULTIWINDOW-M drawn content, kept as the degradation path: shown until the managed
      // surface is confirmed (or forever without a surface id), and hidden afterwards so the
      // two content paths never fight for input.
      if (!this.surfaceBound) {
        Column() {
          Row() {
            Text('MAUI subwindow')
              .fontSize(14)
              .fontColor('#FFE8F1FA')
              .fontWeight(FontWeight.Bold)
            Blank()
            Button('x')
              .width(34)
              .height(28)
              .fontSize(14)
              .backgroundColor('#FF33414D')
              .onClick((): void => {
                this.closeSelf();
              })
          }
          .width('100%')
          .height(44)
          .padding({ left: 12, right: 8 })
          .backgroundColor('#FF22303C')

          Column() {
            Text(`window #${this.resolvedId}`)
              .fontSize(12)
              .fontColor('#FF8FA6B8')
            Text(`touches ${this.touches}`)
              .fontSize(30)
              .fontColor('#FF6EC1FF')
              .margin({ top: 10 })
            Text(`drags ${this.drags}`)
              .fontSize(12)
              .fontColor('#FF8FA6B8')
              .margin({ top: 6 })
            Text(this.dragEnabled ? 'drag the body to move the subwindow' : 'drag disabled (window id mismatch)')
              .fontSize(11)
              .fontColor('#FF6B7C8C')
              .margin({ top: 10 })
          }
          .layoutWeight(1)
          .width('100%')
          .justifyContent(FlexAlign.Center)
        }
        .width('100%')
        .height('100%')
        .backgroundColor('#FF11161C')
        .onTouch((event: TouchEvent): void => {
          this.reportTouch(event);
        })
        .gesture(
          PanGesture()
            .onActionStart((): void => {
              this.beginDrag();
            })
            .onActionUpdate((event: GestureEvent): void => {
              this.updateDrag(event.offsetX, event.offsetY);
            })
        )
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#FF11161C')
  }
}
