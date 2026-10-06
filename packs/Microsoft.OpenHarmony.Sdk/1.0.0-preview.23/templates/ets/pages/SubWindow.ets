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
import { webview as web_webview } from '@kit.ArkWeb';
import { hilog } from '@kit.PerformanceAnalysisKit';
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
// it back, and it is the drag guard's identity check (see aboutToAppear).
const SUB_WINDOW_NAME: string = 'ohos_dotnet_subwindow';
// M4: the AppStorage key the main page writes a focus/keyboard request to (the child's own
// LocalStorage is not propagated); the @StorageLink below watches it.
const SUB_WINDOW_FOCUS_REQUEST_KEY: string = 'ohos_dotnet_subwindow_focus_request';

// MULTIWINDOW-L2: the subwindow's own ArkWeb host (the second web host). The pool is small and
// fully dynamic: a slot's ArkWeb is instantiated by the first tagged command that needs it and
// destroyed when the managed pool releases the slot, so a subwindow without web content never
// starts an ArkWeb engine (the AOT-STARTUP lesson from the main page). Commands arrive through
// the native child sink (host.registerChildWebSink) and use the same "s<slot>" wire the main
// page uses. Page events travel back through host.notifyWebEvent tagged with this window
// ("w:<surfaceId>|s<slot>|<state>"; capacity is "w:<surfaceId>|capacity|<n>") so the primary
// pool and this pool can never consume each other's events. The hybrid/Blazor asset bridges
// stay primary-window-only in this wave: their registration explicitly disables the slot
// instead of leaving a half-served document behind (see disableChildWebSlot).
const SUB_WEB_SLOT_MAX: number = 2;
const SUB_WEB_SLOT_PENDING_MAX: number = 32;
const SUB_WEB_STATE_PREFIX: string = 'w:';

// One deferred child-web command: replayed from onControllerAttached when the ArkWeb of its
// slot was still being created (mirrors the main page's WebPendingOp, without the eval case:
// a child eval is answered immediately when no page exists).
interface SubWebPendingOp {
  op: string;
  arg: string;
}

// The hybrid/Blazor registration payload's slot field (the child host only reads the slot).
interface SubWebAssetsConfig {
  slot?: number;
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

// The focus/keyboard request written by pages/Index.ets (mirrors its interface).
interface SubWindowFocusRequest {
  surfaceId: string;
  show: number;
  caret: number;
  text?: string;
  seq: number;
}

@Entry({ routeName: 'ohos_dotnet_subwindow' })
@Component
struct SubWindow {
  // The child's own window id, stamped by pages/Index.ets through the LocalStorage of
  // loadContentByName; -1 when the runtime does not propagate it (the name check then carries
  // the guard).
  @LocalStorageProp('subWindowId') subWindowId: number = -1;
  // MULTIWINDOW-L M3: the managed surface id (the managed OpenWindow command's window id, used
  // as the XComponent component id and the host registry id). It travels in the child window's
  // name (see aboutToAppear) because the loadContentByName LocalStorage is not reliably
  // propagated; the LocalStorage value stays as a secondary source. Empty selects the drawn M
  // path.
  @LocalStorageProp('subWindowSurfaceId') storedSurfaceId: string = '';
  // State (not a plain field): the id is assigned in aboutToAppear, and the XComponent branch
  // must mount on the render that follows that assignment.
  @State surfaceId: string = '';
  @State touches: number = 0;
  @State drags: number = 0;
  @State resolvedId: number = -1;
  @State dragEnabled: boolean = false;
  // True once the host confirmed the XComponent claim; the drawn fallback stays (and stays
  // interactive) until then, and hides once the managed surface owns the child.
  @State surfaceBound: boolean = false;
  // MULTIWINDOW-L M4: the managed focus/keyboard request channel from pages/Index.ets. The
  // @Watch runs on every change (the payload carries a sequence number, so a repeated request
  // still notifies).
  @StorageLink('ohos_dotnet_subwindow_focus_request') @Watch('onFocusRequest') focusRequest: string = '';
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
  // A slot whose hybrid/blazor registration was refused (the asset bridge is primary-only in
  // this wave): no component is created and its commands are dropped with one bounded log.
  private subWebUnsupported: boolean[] = [false, false];
  private subWebControllers: (web_webview.WebviewController | null)[] = [null, null];
  private subWebPending: SubWebPendingOp[][] = [[], []];
  private subWebHostRegistered: boolean = false;
  private inputController: TextInputController = new TextInputController();
  private win: window.Window | null = null;
  private startLeft: number = 0;
  private startTop: number = 0;

  aboutToAppear(): void {
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    window.getLastWindow(context).then((win: window.Window): void => {
      this.win = win;
      const props = win.getWindowProperties();
      this.resolvedId = props.id;
      const resolvedName: string = props.name !== undefined ? props.name : '';
      // M3: the managed surface id is stamped into the window name as
      // '<SUB_WINDOW_NAME>__<surfaceId>' (pages/Index.ets); the LocalStorage prop is a fallback
      // for a runtime that propagates it. The name check doubles as the drag guard below.
      const managedPrefix: string = `${SUB_WINDOW_NAME}__`;
      if (resolvedName.startsWith(managedPrefix)) {
        this.surfaceId = resolvedName.substring(managedPrefix.length);
      } else if (this.storedSurfaceId.length > 0) {
        this.surfaceId = this.storedSurfaceId;
      }
      // Only the subwindow page may move a window: window.getLastWindow can return the main
      // window while the child is not focused, and moving the main window from here would be
      // wrong. The window name stamped at creation is the primary identity; the LocalStorage id
      // (when the runtime propagates it) is the secondary check. A mismatch disables dragging
      // instead of moving the wrong window; the content stays interactive either way.
      this.dragEnabled = resolvedName === SUB_WINDOW_NAME || resolvedName.startsWith(managedPrefix) ||
        (this.subWindowId >= 0 && props.id === this.subWindowId);
      hilog.info(DOMAIN, TAG, 'subwindow page ready: expected=%{public}d resolved=%{public}d name=%{public}s surface=%{public}s drag=%{public}s',
        this.subWindowId, this.resolvedId, resolvedName, this.surfaceId, this.dragEnabled ? 'on' : 'off');
      // M4: when this window loses focus, drop the IME with it (the keyboard follows the
      // focused window; the managed side re-focuses the child input when an Entry focuses).
      try {
        win.on('windowEvent', (evt: window.WindowEventType): void => {
          if (evt === window.WindowEventType.WINDOW_INACTIVE) {
            this.blurInput();
          }
        });
      } catch (eventError) {
        hilog.error(DOMAIN, TAG, 'subwindow window events unavailable: %{public}s', (eventError as Error).message);
      }
      this.notifyHost(SUB_EVENT_PAGE_READY, this.readyPayload());
      // A request may have arrived while the page was loading (the main page writes AppStorage
      // before the child exists); apply the current value once the surface id is known.
      this.onFocusRequest();
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
    const base = `{"id":${this.resolvedId}`;
    return this.surfaceId.length > 0 ? `${base},"surfaceId":"${this.surfaceId}"}` : `${base}}`;
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
  // the Home-note in pages/Index.ets).
  private blurInput(): void {
    if (this.surfaceId.length === 0) {
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
  // child XComponent (typing/keys, keyboard closed).
  private onFocusRequest(): void {
    if (this.surfaceId.length === 0 || this.focusRequest.length === 0) {
      return;
    }
    try {
      const request = JSON.parse(this.focusRequest) as SubWindowFocusRequest;
      if (request.surfaceId !== this.surfaceId) {
        return;
      }
      if (request.show === 1) {
        if (request.text !== undefined && request.text.length > 0) {
          this.inputText = request.text;
        }
        this.inputController.caretPosition(request.caret >= 0 ? request.caret : 0);
        this.getUIContext().getFocusController().requestFocus(this.inputControlId());
        hilog.info(DOMAIN, TAG, 'subwindow text input focused: caret=%{public}d textLen=%{public}d',
          request.caret, this.inputText.length);
      } else {
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
        this.onChildWebCommand(op, arg);
      });
      if (typeof host.registerChildWebEvalSink === 'function') {
        host.registerChildWebEvalSink((script: string, requestId: number): void => {
          this.onChildWebEval(script, requestId);
        });
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

  // "w:<surfaceId>|capacity|<n>": marks the managed child pool ready and flushes its queue.
  private advertiseChildWebCapacity(): void {
    if (!this.subWebHostRegistered) {
      return;
    }
    this.notifyWebHostState('capacity', `${SUB_WEB_SLOT_MAX}`);
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
      }
    } catch (notifyError) {
      hilog.error(DOMAIN, TAG, 'child web event failed: %{public}s', (notifyError as Error).message);
    }
  }

  private childWebEventState(slot: number, state: string): string {
    return `s${slot}|${state}`;
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
      if (slot < 0 || !this.childWebSlotReady(slot) || this.subWebUnsupported[slot]) {
        // No page to run on (an engine still being created or a refused bridge slot): answer
        // immediately so the managed caller never waits out its eval timeout.
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
    if (op === 'hybrid' || op === 'blazor') {
      // HybridWebView/BlazorWebView asset bridges are primary-window-only in this wave: the
      // registration refuses its slot instead of creating an engine that could never be served
      // (no half-loaded document, no primary-window interaction).
      this.disableChildWebSlot(this.childWebRegistrationSlot(arg), op);
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
    if (this.subWebUnsupported[slot]) {
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
      this.subWebVisible[slot] = true;
      this.noteChildWebActivation(slot);
      this.childWebController(slot).loadUrl(this.childWebSlotPayload(arg));
      hilog.info(DOMAIN, TAG, 'child web load (slot %{public}d): %{public}s', slot, this.childWebSlotPayload(arg));
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
    if (this.subWebCreated[slot] || this.subWebUnsupported[slot]) {
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
    // A release always ends a refused registration too: the next claim of the slot starts
    // clean (the refusal is scoped to the claim, not to the slot number).
    this.subWebUnsupported[slot] = false;
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
  }

  // A slot whose hybrid/blazor registration cannot be served in this wave. Any component that
  // was already created (a frame before the registration) is torn down, and every later
  // command for the slot is dropped until its release.
  private disableChildWebSlot(slot: number, op: string): void {
    if (slot < 0 || slot >= SUB_WEB_SLOT_MAX) {
      return;
    }
    if (this.subWebCreated[slot]) {
      this.destroyChildWebSlot(slot);
    }
    this.subWebUnsupported[slot] = true;
    hilog.info(DOMAIN, TAG, 'child web %{public}s refused: the asset bridge is primary-window-only in this wave (slot %{public}d)', op, slot);
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
  // 0 exactly like the main page (the registration is refused either way).
  private childWebRegistrationSlot(arg: string): number {
    try {
      const config = JSON.parse(arg) as SubWebAssetsConfig;
      if (config.slot !== undefined && config.slot >= 0 && config.slot < SUB_WEB_SLOT_MAX) {
        return config.slot;
      }
    } catch {
      // A malformed registration falls back to slot 0; the refusal is logged by the caller.
    }
    return 0;
  }

  // WebView PlatformArrange: "s<slot>\nx\ny\nw\nh" in device pixels, converted to vp like the
  // main page (a degenerate frame is ignored). A frame also shows the overlay.
  private applyChildWebFrame(arg: string): void {
    const slot: number = this.childWebSlotDigit(arg);
    if (slot < 0 || this.subWebUnsupported[slot]) {
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
        this.flushChildWebOps(slot);
      })
      .onPageBegin((event) => {
        this.notifyWebHostState(this.childWebEventState(slot, 'started'), event ? event.url : '');
      })
      .onPageEnd((event) => {
        const pageUrl: string = event ? event.url : '';
        hilog.info(DOMAIN, TAG, 'child web page (slot %{public}d): %{public}s', slot, pageUrl);
        this.notifyWebHostState(this.childWebEventState(slot, 'finished'), pageUrl);
        this.reportChildWebHistory(slot);
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
      // this window's surface id, so the two windows never share keyboard state.
      if (this.surfaceId.length > 0) {
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
      // focus are forwarded tagged with this window's id.
      if (this.surfaceId.length > 0) {
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
