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

const LIFECYCLE_CREATE = 0;
const LIFECYCLE_DESTROY = 1;
const LIFECYCLE_FOREGROUND = 2;
const LIFECYCLE_BACKGROUND = 3;

interface AppConfig {
  assembly: string;
}

// Payload marker (P17): pins the zip identity (rawfile byte length + mtime) and the entry
// count of a completed unpack, so a matching marker skips the 16 MB copy and the inflate.
interface UnpackMarker {
  zipSize: number;
  mtime: number;
  fileCount: number;
}

function countEntries(dir: string): number {
  return fs.listFileSync(dir, { recursion: true }).length;
}

function readMarker(markerPath: string): UnpackMarker | undefined {
  try {
    return JSON.parse(fs.readTextSync(markerPath)) as UnpackMarker;
  } catch (readError) {
    return undefined;
  }
}

// Reusable only when the marker pins the current zip and every recorded entry is still there:
// a missing or half-written tree (interrupted first unpack, wiped dir) is rebuilt from scratch.
function markerMatches(markerPath: string, payloadDir: string, zipSize: number, mtime: number): boolean {
  if (mtime < 0 || !fs.accessSync(payloadDir)) {
    return false;
  }
  const marker = readMarker(markerPath);
  if (marker === undefined) {
    return false;
  }
  return marker.zipSize === zipSize && marker.mtime === mtime && marker.fileCount === countEntries(payloadDir);
}

function deleteTree(path: string): void {
  if (!fs.accessSync(path)) {
    return;
  }
  for (const name of fs.listFileSync(path)) {
    const child = `${path}/${name}`;
    if (fs.statSync(child).isDirectory()) {
      deleteTree(child);
    } else {
      fs.unlinkSync(child);
    }
  }
  fs.rmdirSync(path);
}

function writeMarker(markerPath: string, marker: UnpackMarker): void {
  try {
    const tempPath = `${markerPath}.tmp`;
    const file = fs.openSync(tempPath, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
    try {
      fs.writeSync(file.fd, JSON.stringify(marker));
      fs.fsyncSync(file.fd);
    } finally {
      fs.closeSync(file);
    }
    fs.renameSync(tempPath, markerPath);
  } catch (markerError) {
    // A lost marker only costs one more unpack next launch; never fail startup for it.
    hilog.warn(DOMAIN, TAG, 'unpack marker not written: %{public}s', (markerError as Error).message);
  }
}

// Unpacks dotnet.zip unless an earlier launch left a matching payload; true when it unpacked.
// A stale (upgrade) or half-written payload is deleted before the new unpack starts.
async function unpackIfNeeded(zipFd: number, zipSize: number, mtime: number, cached: string, payloadDir: string, markerPath: string): Promise<boolean> {
  if (markerMatches(markerPath, payloadDir, zipSize, mtime)) {
    return false;
  }
  fs.copyFile(zipFd, cached);
  deleteTree(payloadDir);
  await zlib.decompressFile(cached, payloadDir);
  writeMarker(markerPath, { zipSize, mtime, fileCount: countEntries(payloadDir) });
  return true;
}

export default class EntryAbility extends UIAbility {
  private started: boolean = false;
  // Host-availability guard (device-compat): a libopenharmonyhost.so that fails to load (for
  // example an unresolved DT_NEEDED the HAP loader cannot satisfy) leaves the static import
  // undefined, so every host call is routed through this guard and degrades to a logged
  // unavailability instead of throwing TypeError out of a lifecycle callback.
  private hostUnavailable: Set<string> = new Set();

  private reportHostUnavailable(api: string, error: Error | undefined): void {
    if (this.hostUnavailable.has(api)) {
      return;
    }
    this.hostUnavailable.add(api);
    const detail: string = error !== undefined ? ` (${error.message})` : '';
    hilog.error(DOMAIN, TAG, 'host export unavailable: %{public}s%{public}s', api, detail);
  }

  private hostCall(api: string, available: boolean, call: () => void): boolean {
    if (!available) {
      this.reportHostUnavailable(api, undefined);
      return false;
    }
    try {
      call();
      return true;
    } catch (hostError) {
      this.reportHostUnavailable(api, hostError as Error);
      return false;
    }
  }

  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    hilog.info(DOMAIN, TAG, 'EntryAbility onCreate');
    // 0 = create: the ability now exists. The native host queues lifecycle events that arrive
    // before the managed app is up, so sending it here makes Created/Activated (and the later
    // Foreground) reach the managed window in order.
    this.hostCall('notifyLifecycle', typeof host !== 'undefined' && typeof host.notifyLifecycle === 'function', (): void => {
      host.notifyLifecycle(LIFECYCLE_CREATE);
    });
    this.bootstrap().catch((error: Error) => {
      hilog.error(DOMAIN, TAG, 'bootstrap failed: %{public}s', error.message);
    });
  }

  onDestroy(): void {
    if (this.started) {
      this.hostCall('notifyLifecycle', typeof host !== 'undefined' && typeof host.notifyLifecycle === 'function', (): void => {
        host.notifyLifecycle(LIFECYCLE_DESTROY);
      });
    }
  }

  onForeground(): void {
    if (this.started) {
      this.hostCall('notifyLifecycle', typeof host !== 'undefined' && typeof host.notifyLifecycle === 'function', (): void => {
        host.notifyLifecycle(LIFECYCLE_FOREGROUND);
      });
    }
  }

  onBackground(): void {
    if (this.started) {
      this.hostCall('notifyLifecycle', typeof host !== 'undefined' && typeof host.notifyLifecycle === 'function', (): void => {
        host.notifyLifecycle(LIFECYCLE_BACKGROUND);
      });
    }
  }

  private async bootstrap(): Promise<void> {
    const payloadDir = `${this.context.filesDir}/dotnet`;
    const raw = await this.context.resourceManager.getRawFileContent('app.json');
    const config = JSON.parse(new util.TextDecoder('utf-8').decodeWithStream(raw)) as AppConfig;

    const markerPath = `${this.context.filesDir}/dotnet.marker`;
    const cached = `${this.context.cacheDir}/dotnet.zip`;
    const zip = await this.context.resourceManager.getRawFd('dotnet.zip');
    // The marker pins the rawfile bytes; when fstat is unavailable the -1 identity never
    // matches, which degrades to the old unconditional unpack instead of skipping wrongly.
    let zipMtime = -1;
    try {
      zipMtime = fs.statSync(zip.fd).mtime;
    } catch (statError) {
      hilog.warn(DOMAIN, TAG, 'dotnet.zip stat failed: %{public}s', (statError as Error).message);
    }
    const unpacked: boolean = await unpackIfNeeded(zip.fd, zip.length, zipMtime, cached, payloadDir, markerPath);
    if (unpacked) {
      hilog.info(DOMAIN, TAG, 'unpacked payload into %{public}s', payloadDir);
    } else {
      hilog.info(DOMAIN, TAG, 'reused payload in %{public}s', payloadDir);
    }

    const context = JSON.stringify({
      appDir: payloadDir,
      filesDir: this.context.filesDir,
      cacheDir: this.context.cacheDir,
      bundleName: this.context.abilityInfo.bundleName,
      abilityName: this.context.abilityInfo.name,
      nodeContent: 0,
    });
    const started: boolean = this.hostCall('startApp', typeof host !== 'undefined' && typeof host.startApp === 'function', (): void => {
      host.startApp(payloadDir, config.assembly, context);
    });
    if (!started) {
      hilog.error(DOMAIN, TAG, 'managed app %{public}s not started: host unavailable', config.assembly);
      return;
    }
    this.started = true;
    hilog.info(DOMAIN, TAG, 'managed app %{public}s started from %{public}s', config.assembly, payloadDir);
  }
}
