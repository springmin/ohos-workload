// UI-enabled shell variant. Use this instead of EntryAbility.ets when the app has an
// ArkUI page (compiled by the ArkTS toolchain: ets-loader/hvigor or DevEco Studio).
// The page receives a NodeContent, which the native host forwards to the managed app
// (Microsoft.OpenHarmony.Hosting.OpenHarmonyBridge.NodeContent) so managed code can
// attach native ArkUI nodes (e.g. an XComponent for Skia/MAUI rendering).
import { UIAbility, AbilityConstant, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import zlib from '@ohos.zlib';
import fs from '@ohos.file.fs';
import util from '@ohos.util';
import host from 'libopenharmonyhost.so';

const DOMAIN = 0x0002;
const TAG = 'OHOS_DOTNET';
const LIFECYCLE_FOREGROUND = 2;
const LIFECYCLE_BACKGROUND = 3;
const LIFECYCLE_DESTROY = 1;

interface AppConfig {
  assembly: string;
}

export default class EntryAbility extends UIAbility {
  private started: boolean = false;

  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    this.bootstrap().catch((error: Error) => {
      hilog.error(DOMAIN, TAG, 'bootstrap failed: %{public}s', error.message);
    });
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        hilog.error(DOMAIN, TAG, 'loadContent failed: %{public}s', JSON.stringify(err));
      }
    });
  }

  onForeground(): void {
    if (this.started) {
      host.notifyLifecycle(LIFECYCLE_FOREGROUND);
    }
  }

  onBackground(): void {
    if (this.started) {
      host.notifyLifecycle(LIFECYCLE_BACKGROUND);
    }
  }

  onDestroy(): void {
    if (this.started) {
      host.notifyLifecycle(LIFECYCLE_DESTROY);
    }
  }

  private async bootstrap(): Promise<void> {
    const payloadDir = `${this.context.filesDir}/dotnet`;
    const raw = await this.context.resourceManager.getRawFileContent('app.json');
    const config = JSON.parse(new util.TextDecoder('utf-8').decodeWithStream(raw)) as AppConfig;
    const cached = `${this.context.cacheDir}/dotnet.zip`;
    const zip = await this.context.resourceManager.getRawFd('dotnet.zip');
    fs.copyFile(zip.fd, cached);
    await zlib.decompressFile(cached, payloadDir);
    const context = JSON.stringify({
      appDir: payloadDir,
      filesDir: this.context.filesDir,
      cacheDir: this.context.cacheDir,
      bundleName: this.context.abilityInfo.bundleName,
      abilityName: this.context.abilityInfo.name,
      nodeContent: 0,
    });
    host.startApp(payloadDir, config.assembly, context);
    this.started = true;
    hilog.info(DOMAIN, TAG, 'managed app %{public}s started (UI shell)', config.assembly);
  }
}
