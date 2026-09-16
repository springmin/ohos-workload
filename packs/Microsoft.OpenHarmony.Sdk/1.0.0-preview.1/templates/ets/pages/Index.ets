// ArkUI page hosting native (.NET-rendered) content.
//
// This page uses the ArkTS declarative syntax (@Entry/@Component/struct), which the
// es2abc-only shell build in this repo cannot compile: it needs the ArkTS toolchain
// (ets-loader under hvigor / DevEco Studio). The headless shell (EntryAbility only)
// works without it; enable this page in a UI build by:
//   1. compiling ets/**/*.ets with ets-loader into ets/modules.abc (records:
//      entryability/EntryAbility, pages/Index),
//   2. setting resources/base/profile/main_pages.json to { "src": ["pages/Index"] },
//   3. calling windowStage.loadContent('pages/Index', ...) from EntryAbility.
// The page hands its NodeContent to the native host, which forwards it to the managed
// app (Microsoft.OpenHarmony.Hosting.OpenHarmonyBridge.NodeContent) so managed code can
// attach ArkUI nodes (XComponent/canvas for MAUI) to the page.
import { NodeContent } from '@ohos.arkui.node';
import host from 'libopenharmonyhost.so';

@Entry
@Component
struct Index {
  private content: NodeContent = new NodeContent();

  aboutToAppear(): void {
    // 2 = foreground; the native host forwards it to the managed bridge.
    host.notifyLifecycle(2);
    host.setNodeContent(this.content);
  }

  build() {
    Column() {
      ContentSlot(this.content)
        .width('100%')
        .height('100%')
    }
    .width('100%')
    .height('100%')
  }
}
