/*
 * Companion ability. The accessibility extension (ets/a11y/A11yExtAbility.ets) is started by
 * the system when the service is enabled; this ability runs on a plain `aa start` and probes
 * the public accessibility API so a device run shows the client artifact works even where the
 * extension cannot be enabled by a third-party app (no Settings page / no CLI).
 */
import { UIAbility } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { accessibility } from '@kit.AccessibilityKit';

const DOMAIN: number = 0x3200;
const TAG: string = 'A11yClient';

export default class EntryAbility extends UIAbility {
  onCreate(): void {
    hilog.info(DOMAIN, TAG, 'A11YCLIENT EntryAbility onCreate (no UI)');
    setTimeout(() => {
      this.probe();
    }, 500);
  }

  private probe(): void {
    try {
      const open = accessibility.isOpenAccessibilitySync();
      const screenReader = accessibility.isScreenReaderOpenSync();
      const touchGuide = accessibility.isOpenTouchGuideSync();
      hilog.info(DOMAIN, TAG,
        'A11YCLIENT probe open=%{public}s screenReader=%{public}s touchGuide=%{public}s',
        String(open), String(screenReader), String(touchGuide));
      const installed = accessibility.getAccessibilityExtensionListSync('all', 'install');
      hilog.info(DOMAIN, TAG, 'A11YCLIENT probe installedExtensions=%{public}d', installed.length);
      for (let i = 0; i < installed.length; i++) {
        const info = installed[i];
        hilog.info(DOMAIN, TAG,
          'A11YCLIENT EXTENSION id=%{public}s label=%{public}s bundle=%{public}s types=%{public}s caps=%{public}s',
          String(info.id), String(info.label), String(info.bundleName),
          JSON.stringify(info.abilityTypes), JSON.stringify(info.capabilities));
      }
      const enabled = accessibility.getAccessibilityExtensionListSync('all', 'enable');
      hilog.info(DOMAIN, TAG, 'A11YCLIENT probe enabledExtensions=%{public}d', enabled.length);
    } catch (err) {
      const message = (err as Error).message;
      hilog.error(DOMAIN, TAG, 'A11YCLIENT probe failed err=%{public}s',
        typeof message === 'string' ? message : JSON.stringify(err));
    }
  }
}
