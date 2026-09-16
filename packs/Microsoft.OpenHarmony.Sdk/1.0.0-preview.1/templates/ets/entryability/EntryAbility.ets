// Thin ArkTS shell for a .NET OpenHarmony app.
// The packaging target ships the published .NET output as resources/rawfile/dotnet.zip
// plus resources/rawfile/app.json; this ability unpacks the payload into the app's
// files dir, starts it through libopenharmonyhost.so and forwards lifecycle events.
import { UIAbility, AbilityConstant, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import zlib from '@ohos.zlib';
import fs from '@ohos.file.fs';
import util from '@ohos.util';
import host from 'libopenharmonyhost.so';

const DOMAIN = 0x0002;
const TAG = 'OHOS_DOTNET';

const LIFECYCLE_DESTROY = 1;
const LIFECYCLE_FOREGROUND = 2;
const LIFECYCLE_BACKGROUND = 3;

interface AppConfig {
  assembly: string;
}

export default class EntryAbility extends UIAbility {
  private started: boolean = false;

  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    hilog.info(DOMAIN, TAG, 'EntryAbility onCreate');
    this.bootstrap().catch((error: Error) => {
      hilog.error(DOMAIN, TAG, 'bootstrap failed: %{public}s', error.message);
    });
  }

  onDestroy(): void {
    if (this.started) {
      host.notifyLifecycle(LIFECYCLE_DESTROY);
    }
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
    hilog.info(DOMAIN, TAG, 'managed app %{public}s started from %{public}s', config.assembly, payloadDir);
  }
}
