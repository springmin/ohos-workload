// Thin ArkTS shell for a .NET OpenHarmony app.
// The packaging target ships the published .NET output as resources/rawfile/dotnet.zip
// plus resources/rawfile/app.json; this ability unpacks the payload into the app's
// files dir and starts it through libopenharmonyhost.so.
import { UIAbility, AbilityConstant, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import zlib from '@ohos.zlib';
import fs from '@ohos.file.fs';
import util from '@ohos.util';
import host from 'libopenharmonyhost.so';

const DOMAIN = 0x0002;
const TAG = 'OHOS_DOTNET';

interface AppConfig {
  assembly: string;
}

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    hilog.info(DOMAIN, TAG, 'EntryAbility onCreate');
    this.bootstrap().catch((error: Error) => {
      hilog.error(DOMAIN, TAG, 'bootstrap failed: %{public}s', error.message);
    });
  }

  private async bootstrap(): Promise<void> {
    const payloadDir = `${this.context.filesDir}/dotnet`;
    const zip = await this.context.resourceManager.getRawFileContent('app.json');
    const config = JSON.parse(new util.TextDecoder('utf-8').decodeWithStream(zip)) as AppConfig;

    const cached = `${this.context.cacheDir}/dotnet.zip`;
    const raw = await this.context.resourceManager.getRawFd('dotnet.zip');
    fs.copyFile(raw.fd, cached);
    await zlib.decompressFile(cached, payloadDir);

    host.startApp(payloadDir, config.assembly);
    hilog.info(DOMAIN, TAG, 'managed app %{public}s started', config.assembly);
  }
}
