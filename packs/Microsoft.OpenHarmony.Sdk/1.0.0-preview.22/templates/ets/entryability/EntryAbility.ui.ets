// UI-enabled shell variant. Use this instead of EntryAbility.ets when the app has an
// ArkUI page (compiled by the ArkTS toolchain: ets-loader/hvigor or DevEco Studio).
// The page receives a NodeContent, which the native host forwards to the managed app
// (Microsoft.OpenHarmony.Hosting.OpenHarmonyBridge.NodeContent) so managed code can
// attach native ArkUI nodes (e.g. an XComponent for Skia/MAUI rendering). The packaging
// target ships the published .NET output twice: in place under the hap's signed libs/<abi>/
// (payload-in-libs, the namespace-allowed copy this ability starts from) and as
// resources/rawfile/dotnet.zip, the fallback it unpacks into the app's files dir when the
// staged payload is absent.
import { UIAbility, AbilityConstant, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import zlib from '@ohos.zlib';
import fs from '@ohos.file.fs';
import util from '@ohos.util';
import host from 'libopenharmonyhost.so';

const DOMAIN = 0x0002;
const TAG = 'OHOS_DOTNET';
const LIFECYCLE_CREATE = 0;
const LIFECYCLE_FOREGROUND = 2;
const LIFECYCLE_BACKGROUND = 3;
const LIFECYCLE_DESTROY = 1;

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

// Payload-in-libs: the packaging stages the whole managed payload into the hap's signed
// libs/<abi>/ directory and writes the .dotnet-payload.json marker there. That bundle
// directory is the only one the device namespace policy allows the runtime to dlopen from, so
// a complete staged payload is started in place and the dotnet.zip copy/inflate is skipped; a
// hap packed without the marker (or with a partial staging) falls back to the zip below. The
// marker names the entry assembly and the staged file count.
interface PayloadMarker {
  schema: number;
  assembly: string;
  entries: number;
}

// HAP libs/<abi>/ directory names on device: the packaging ABI ids map to the loader's names
// (arm64-v8a -> arm64). Probing the known set keeps the shell template ABI-agnostic.
const LIBS_ABI_DIRS = ['arm64', 'arm', 'x86_64'];
const PAYLOAD_MARKER_NAME = '.dotnet-payload.json';

// Returns the bundle libs directory when it carries a complete payload-in-libs staging: the
// marker file, the entry assembly and a marker that names that assembly. Any error (missing
// directory, unreadable bundle) is the zip fallback's business and returns undefined.
function findLibsPayloadDir(bundleCodeDir: string, assembly: string): string | undefined {
  if (bundleCodeDir.length === 0) {
    return undefined;
  }
  for (const abi of LIBS_ABI_DIRS) {
    const dir = `${bundleCodeDir}/libs/${abi}`;
    try {
      if (!fs.accessSync(dir) || !fs.accessSync(`${dir}/${PAYLOAD_MARKER_NAME}`) || !fs.accessSync(`${dir}/${assembly}`)) {
        continue;
      }
      const marker = JSON.parse(fs.readTextSync(`${dir}/${PAYLOAD_MARKER_NAME}`)) as PayloadMarker;
      if (marker.assembly === assembly && marker.entries > 0) {
        return dir;
      }
    } catch (probeError) {
      // keep probing: an unreadable or malformed candidate is not a payload-in-libs staging
    }
  }
  return undefined;
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

// A payload extracted by an earlier (pre-payload-in-libs) kit stays in filesDir after an
// upgrade; drop it, its marker and the cached zip so the runtime never falls back to the stale
// tree and the space is reclaimed. Best effort: a failure only leaves the old files behind and
// never fails the launch.
function removeStaleExtraction(payloadDir: string, markerPath: string, cachedZip: string): void {
  try {
    if (fs.accessSync(payloadDir)) {
      deleteTree(payloadDir);
      hilog.info(DOMAIN, TAG, 'removed the stale extracted payload %{public}s', payloadDir);
    }
    if (fs.accessSync(markerPath)) {
      fs.unlinkSync(markerPath);
    }
    if (fs.accessSync(cachedZip)) {
      fs.unlinkSync(cachedZip);
    }
  } catch (cleanupError) {
    hilog.warn(DOMAIN, TAG, 'stale payload cleanup failed: %{public}s', (cleanupError as Error).message);
  }
}

// One chunk per read/write: the copy is bounded by the member length, so the buffer stays at
// 64 KiB whatever the payload size.
const ZIP_COPY_CHUNK = 64 * 1024;

// Copies the rawfile member [zipOffset, zipOffset + zipSize) out of the HAP descriptor into
// cached. getRawFd hands back a descriptor of the whole HAP plus the member's coordinates, so
// copying the descriptor directly (fs.copyFile starts at byte 0) gives the inflater a
// truncated archive; on the device that surfaced as BusinessError 900003 "ZIP entry data
// extraction failed". A read shorter than the requested chunk means the descriptor does not
// cover the member, so the copy fails closed instead of writing a silently truncated zip.
function copyZipRange(zipFd: number, zipOffset: number, zipSize: number, cached: string): void {
  const target = fs.openSync(cached, fs.OpenMode.WRITE_ONLY | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
  try {
    const buffer = new ArrayBuffer(ZIP_COPY_CHUNK);
    let remaining = zipSize;
    let position = zipOffset;
    while (remaining > 0) {
      const wanted = Math.min(remaining, buffer.byteLength);
      // offset addresses the descriptor's file position and length the chunk size; the bytes
      // land at the start of the buffer. Both are validated below.
      const readLength = fs.readSync(zipFd, buffer, { length: wanted, offset: position });
      if (readLength !== wanted) {
        throw new Error(`rawfile copy of dotnet.zip stopped at ${position - zipOffset}/${zipSize} bytes (read ${readLength} of ${wanted} at ${position})`);
      }
      const written = fs.writeSync(target.fd, buffer, { length: readLength });
      if (written !== readLength) {
        throw new Error(`rawfile copy of dotnet.zip wrote ${written} of ${readLength} bytes (${position - zipOffset}/${zipSize})`);
      }
      remaining -= readLength;
      position += readLength;
    }
    // The inflater and the marker must only see the cached zip once its bytes are on disk.
    fs.fsyncSync(target.fd);
  } finally {
    fs.closeSync(target);
  }
}

// Unpacks dotnet.zip unless an earlier launch left a matching payload; true when it unpacked.
// The cached zip is copied at the rawfile coordinates getRawFd reports; a stale (upgrade) or
// half-written payload is deleted before the new unpack starts.
async function unpackIfNeeded(zipFd: number, zipOffset: number, zipSize: number, mtime: number, cached: string, payloadDir: string, markerPath: string): Promise<boolean> {
  if (markerMatches(markerPath, payloadDir, zipSize, mtime)) {
    return false;
  }
  copyZipRange(zipFd, zipOffset, zipSize, cached);
  deleteTree(payloadDir);
  // decompressFile refuses a destination that does not exist yet (device finding:
  // BusinessError 900002 "destination path is not an existing directory"), so create the
  // payload dir after the stale tree is gone and before the inflate starts.
  fs.mkdirSync(payloadDir, true);
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
    // 0 = create: the ability now exists. The native host queues lifecycle events that arrive
    // before the managed app is up, so sending it here makes Created/Activated (and the page's
    // Foreground on first appearance) reach the managed window in order.
    this.hostCall('notifyLifecycle', typeof host !== 'undefined' && typeof host.notifyLifecycle === 'function', (): void => {
      host.notifyLifecycle(LIFECYCLE_CREATE);
    });
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

  onDestroy(): void {
    if (this.started) {
      this.hostCall('notifyLifecycle', typeof host !== 'undefined' && typeof host.notifyLifecycle === 'function', (): void => {
        host.notifyLifecycle(LIFECYCLE_DESTROY);
      });
    }
  }

  private async bootstrap(): Promise<void> {
    const raw = await this.context.resourceManager.getRawFileContent('app.json');
    const config = JSON.parse(new util.TextDecoder('utf-8').decodeWithStream(raw)) as AppConfig;
    const payloadDir = `${this.context.filesDir}/dotnet`;
    const markerPath = `${this.context.filesDir}/dotnet.marker`;
    const cached = `${this.context.cacheDir}/dotnet.zip`;

    // Payload-in-libs (see findLibsPayloadDir): a staged bundle payload is the namespace-allowed
    // copy, so it is used in place and the rawfile zip stays the fallback. Otherwise the zip is
    // unpacked into filesDir exactly as before (P17 marker logic included).
    const libsDir = findLibsPayloadDir(this.context.bundleCodeDir, config.assembly);
    let appDir: string;
    if (libsDir !== undefined) {
      appDir = libsDir;
      hilog.info(DOMAIN, TAG, 'payload-in-libs: running from %{public}s (dotnet.zip not unpacked)', libsDir);
      removeStaleExtraction(payloadDir, markerPath, cached);
    } else {
      const zip = await this.context.resourceManager.getRawFd('dotnet.zip');
      // The marker pins the rawfile bytes; when fstat is unavailable the -1 identity never
      // matches, which degrades to the old unconditional unpack instead of skipping wrongly.
      let zipMtime = -1;
      try {
        zipMtime = fs.statSync(zip.fd).mtime;
      } catch (statError) {
        hilog.warn(DOMAIN, TAG, 'dotnet.zip stat failed: %{public}s', (statError as Error).message);
      }
      const unpacked: boolean = await unpackIfNeeded(zip.fd, zip.offset, zip.length, zipMtime, cached, payloadDir, markerPath);
      if (unpacked) {
        hilog.info(DOMAIN, TAG, 'unpacked payload into %{public}s', payloadDir);
      } else {
        hilog.info(DOMAIN, TAG, 'reused payload in %{public}s', payloadDir);
      }
      appDir = payloadDir;
    }
    const context = JSON.stringify({
      appDir: appDir,
      filesDir: this.context.filesDir,
      cacheDir: this.context.cacheDir,
      bundleName: this.context.abilityInfo.bundleName,
      abilityName: this.context.abilityInfo.name,
      nodeContent: 0,
    });
    const started: boolean = this.hostCall('startApp', typeof host !== 'undefined' && typeof host.startApp === 'function', (): void => {
      host.startApp(appDir, config.assembly, context);
    });
    if (!started) {
      hilog.error(DOMAIN, TAG, 'managed app %{public}s not started (UI shell): host unavailable', config.assembly);
      return;
    }
    this.started = true;
    hilog.info(DOMAIN, TAG, 'managed app %{public}s started (UI shell) from %{public}s', config.assembly, appDir);
  }
}
