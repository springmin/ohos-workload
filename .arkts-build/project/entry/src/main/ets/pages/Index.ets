// ArkUI page hosting native (.NET-rendered) content.
//
// Compiled by the ArkTS toolchain (see integration/arkts-shell in the workload repo or
// the packaging properties OpenHarmonyArktsModulesAbc / OpenHarmonyUIPage).
// The page hands its NodeContent to the native host, which forwards it to the managed app
// (Microsoft.OpenHarmony.Hosting.OpenHarmonyBridge.NodeContent) so managed code can attach
// native ArkUI nodes (e.g. an XComponent/canvas for MAUI rendering).
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
    // ContentSlot has no size attributes of its own; the container carries the layout.
    Column() {
      ContentSlot(this.content)
    }
    .width('100%')
    .height('100%')
  }
}
