// L8-PROBE entry ability (scratch branch feat/l8-popup-probe): a pure-ArkTS probe, so only
// pages/Index is loaded and the host hap's managed payload is deliberately not started (the
// probe page registers no NodeContent/host bridge; starting the managed app would only log
// host-unavailable noise). Product EntryAbility.ui.ets is unchanged on master.
import { UIAbility } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN = 0x0002;
const TAG = 'L8PROBE';

export default class EntryAbility extends UIAbility {
  onWindowStageCreate(windowStage: window.WindowStage): void {
    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        hilog.error(DOMAIN, TAG, 'loadContent failed: %{public}s', JSON.stringify(err));
      }
    });
  }
}
