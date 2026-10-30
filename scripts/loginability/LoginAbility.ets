// LoginAbility: a pure ArkUI login surface hosted by a second UIAbility. It shares the bundle
// and module with EntryAbility but has its own srcEntry/page, so it does not need the MAUI host
// (the shared host binds the main EntryAbility surface).
import { UIAbility } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN: number = 0x0000;
const TAG: string = 'LOGIN_ABILITY';

export default class LoginAbility extends UIAbility {
  onWindowStageCreate(windowStage: window.WindowStage): void {
    hilog.info(DOMAIN, TAG, 'onWindowStageCreate');
    windowStage.loadContent('pages/Login', (err) => {
      if (err.code) {
        hilog.error(DOMAIN, TAG, 'loadContent failed: %{public}s', JSON.stringify(err));
      }
    });
  }
}
