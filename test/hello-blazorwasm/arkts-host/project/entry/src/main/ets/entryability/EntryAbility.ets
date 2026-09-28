// Minimal ArkWeb host for the Blazor WASM publish output (see ../README.md).
// The page (pages/Index.ets) serves the embedded site from resources/rawfile through
// Web.onInterceptRequest; no local HTTP server is involved.
import { UIAbility } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN = 0x0002;
const TAG = 'BlazorWebHost';

export default class EntryAbility extends UIAbility {
  onWindowStageCreate(windowStage: window.WindowStage): void {
    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        hilog.error(DOMAIN, TAG, 'loadContent failed: %{public}s', JSON.stringify(err));
        return;
      }
      hilog.info(DOMAIN, TAG, 'Blazor Web page loaded');
    });
  }
}
