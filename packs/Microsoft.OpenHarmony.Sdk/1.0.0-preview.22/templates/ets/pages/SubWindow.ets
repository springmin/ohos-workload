// Shell content for the application subwindow: MULTIWINDOW-M drawn page + MULTIWINDOW-L M3
// managed surface.
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
  private inputController: TextInputController = new TextInputController();
  // MULTIWINDOW-L2 a: the child's own accessibility content slot. The host creates a CUSTOM
  // node inside it and registers a per-instance ArkUI accessibility provider
  // (attachAccessibilityNodeFor), so the child's shadow tree is served by its own provider.
  private content: NodeContent = new NodeContent();
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
      // MULTIWINDOW-L2 a: the ContentSlot exists once build() has mounted the page (this
      // promise resolves after that), so the per-instance accessibility provider can attach now.
      this.attachAccessibility();
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

      // MULTIWINDOW-L2 a: the child's accessibility ContentSlot (the host adds the per-instance
      // CUSTOM node to it), declared after the XComponent like the main page. The CUSTOM node is
      // non-visual, so it never intercepts the managed surface's input.
      ContentSlot(this.content)

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
