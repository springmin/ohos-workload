// Shell-drawn content for the application subwindow (MULTIWINDOW-M).
//
// Loaded with Window.loadContentByName('ohos_dotnet_subwindow', storage) by pages/Index.ets
// after Window.createSubWindowWithOptions. The page is deliberately self-contained: it draws
// its own content, resolves its own window to drag itself, and reports touches/ready/close to
// the managed side through host.notifySubWindowEvent. The application still has ONE managed
// surface/renderer, so this content is ArkUI-drawn, not a second MAUI visual tree - the honest
// degradation for M; per-window surface/renderer state is the L remainder (see the multiwindow
// plan, docs/plans/2026-10-05-ohos-multiwindow-prestudy.md).
//
// The window guard matters: window.getLastWindow() returns the top window of the application,
// which can be the main window while the child is not focused. The page may only move the window
// whose WindowProperties.name matches the name pages/Index.ets passed to
// createSubWindowWithOptions (the id pages/Index.ets also puts in the LocalStorage is the
// secondary check, when the runtime propagates it), so a wrong lookup degrades to "content still
// interactive, drag disabled" instead of moving the wrong window.
import { common } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import host from 'libopenharmonyhost.so';

const DOMAIN = 0x0002;
const TAG = 'OHOS_MAUI_SUB';

// Shell -> managed event ops (mirror OpenHarmonySubWindowEventKind).
const SUB_EVENT_CLOSED: number = 5;
const SUB_EVENT_TOUCH: number = 6;
const SUB_EVENT_PAGE_READY: number = 8;
// The name pages/Index.ets hands to createSubWindowWithOptions; WindowProperties.name carries
// it back, and it is the drag guard's identity check (see aboutToAppear).
const SUB_WINDOW_NAME: string = 'ohos_dotnet_subwindow';

@Entry({ routeName: 'ohos_dotnet_subwindow' })
@Component
struct SubWindow {
  // The child's own window id, stamped by pages/Index.ets through the LocalStorage of
  // loadContentByName; -1 when the runtime does not propagate it (the name check then carries
  // the guard).
  @LocalStorageProp('subWindowId') subWindowId: number = -1;
  @State touches: number = 0;
  @State drags: number = 0;
  @State resolvedId: number = -1;
  @State dragEnabled: boolean = false;
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
      // Only the subwindow page may move a window: window.getLastWindow can return the main
      // window while the child is not focused, and moving the main window from here would be
      // wrong. The window name stamped at creation is the primary identity; the LocalStorage id
      // (when the runtime propagates it) is the secondary check. A mismatch disables dragging
      // instead of moving the wrong window; the content stays interactive either way.
      this.dragEnabled = resolvedName === SUB_WINDOW_NAME || (this.subWindowId >= 0 && props.id === this.subWindowId);
      hilog.info(DOMAIN, TAG, 'subwindow page ready: expected=%{public}d resolved=%{public}d name=%{public}s drag=%{public}s',
        this.subWindowId, this.resolvedId, resolvedName, this.dragEnabled ? 'on' : 'off');
      this.notifyHost(SUB_EVENT_PAGE_READY, `{"id":${this.resolvedId}}`);
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

  aboutToDisappear(): void {
    // The child dies with the page; report the state so the managed side does not keep an open
    // subwindow (the main page's windowEvent observer usually reports first).
    this.notifyHost(SUB_EVENT_CLOSED, `{"id":${this.resolvedId}}`);
  }

  build() {
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
