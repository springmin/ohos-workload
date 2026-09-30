// Thin ArkTS shell for a .NET OpenHarmony app.
// The packaging target ships the published .NET output twice: in place under the hap's signed
// libs/<abi>/ (payload-in-libs, the namespace-allowed copy this ability starts from) and as
// resources/rawfile/dotnet.zip, the fallback it unpacks into the app's files dir when the
// staged payload is absent. Either way the app starts through libopenharmonyhost.so and this
// ability forwards lifecycle events.
import { UIAbility, AbilityConstant, Want, Configuration } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { zlib } from '@kit.BasicServicesKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import host from 'libopenharmonyhost.so';

const DOMAIN = 0x0002;
const TAG = 'OHOS_DOTNET';

const LIFECYCLE_CREATE = 0;
const LIFECYCLE_DESTROY = 1;
const LIFECYCLE_FOREGROUND = 2;
const LIFECYCLE_BACKGROUND = 3;

interface AppConfig {
  assembly: string;
  // https app-link hosts the packaging declared (OpenHarmonyAppLinkHosts -> app.json
  // linkHosts). The shell forwards the list with every activation; the managed side refuses an
  // https link whose host is not on it. Absent (older packaging) means no https links.
  linkHosts?: string[];
}

// App descriptor decoding (audit ARKTS-S2): the rawfile bytes are UTF-8 JSON. decodeToString is
// the one-shot decoder for a whole buffer (decodeWithStream is the streaming form and is not
// needed here); TextDecoder.create validates the encoding name once instead of per call.
function decodeUtf8(bytes: Uint8Array): string {
  return util.TextDecoder.create('utf-8').decodeToString(bytes);
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

// NativeAOT payloads compile the managed entry into lib<stem>.so (the host's lib<assembly
// stem>.so launch-image rule) and ship no <assembly>; the marker still names the assembly, so
// a staged AOT image next to the marker is a complete payload-in-libs staging too (W10: the
// rawfile zip excludes the root *.so by design, so an AOT app that missed this probe landed on
// a fallback with no AOT image at all).
function libsAotEntryName(assembly: string): string {
  const dot = assembly.lastIndexOf('.');
  const stem = dot > 0 ? assembly.substring(0, dot) : assembly;
  return `lib${stem}.so`;
}

// Returns the bundle libs directory when it carries a complete payload-in-libs staging: the
// marker file, the entry (the managed <assembly> or its NativeAOT launch image lib<stem>.so)
// and a marker that names that assembly. Any error (missing directory, unreadable bundle) is
// the zip fallback's business and returns undefined.
function findLibsPayloadDir(bundleCodeDir: string, assembly: string): string | undefined {
  if (bundleCodeDir.length === 0) {
    return undefined;
  }
  const aotEntry = libsAotEntryName(assembly);
  for (const abi of LIBS_ABI_DIRS) {
    const dir = `${bundleCodeDir}/libs/${abi}`;
    try {
      if (!fs.accessSync(dir) || !fs.accessSync(`${dir}/${PAYLOAD_MARKER_NAME}`)) {
        continue;
      }
      if (!fs.accessSync(`${dir}/${assembly}`) && !fs.accessSync(`${dir}/${aotEntry}`)) {
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
  // Deep links / activation: the want of this launch captured in onCreate, the latest want that
  // has not been handed to the host yet, and the activation bookkeeping. The host buffers an
  // activation that arrives before the managed callback registers, so publishActivation() can
  // run before startApp and the cold-start want still arrives exactly once.
  private pendingWant: Want | null = null;
  private activationReady: boolean = false;
  private launchSequence: number = 0;
  // Delivery stage of the next activation (see publishActivation); starts hot so a direct
  // call site without bootstrap still reads correctly.
  private activationStage: string = 'hot';
  private linkHosts: string[] = [];
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
    // Deep link: remember the launch want before anything asynchronous runs; bootstrap()
    // hands it to the host before startApp, and onNewWant takes over once it is running.
    this.pendingWant = want;
    // 0 = create: the ability now exists. The native host queues lifecycle events that arrive
    // before the managed app is up, so sending it here makes Created/Activated (and the later
    // Foreground) reach the managed window in order.
    this.hostCall('notifyLifecycle', typeof host !== 'undefined' && typeof host.notifyLifecycle === 'function', (): void => {
      host.notifyLifecycle(LIFECYCLE_CREATE);
    });
    // The initial system font scale (Configuration.fontSizeScale): the managed text pipeline
    // starts at 1 and applies this before the first frame; the host replays the value when the
    // managed listener registers later.
    try {
      const initialFontScale: number | undefined = this.context.config.fontSizeScale;
      if (typeof initialFontScale === 'number') {
        this.reportFontScale(initialFontScale);
      }
    } catch {
      // A context without a configuration leaves the managed default in place.
    }
    this.bootstrap().catch((error: Error) => {
      hilog.error(DOMAIN, TAG, 'bootstrap failed: %{public}s', error.message);
    });
  }

  // Warm activation: the ability already runs and the system delivered a new want (app link,
  // viewData, ...). The payload travels through host.notifyActivation like the cold-start one;
  // the host delivers it to the managed side (or queues it while the bridge registers), and the
  // managed layer guarantees order and drops duplicate sequences. A want that lands before
  // bootstrap() published the cold one replaces the pending slot instead, so the app still sees
  // exactly one activation.
  onNewWant(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    if (!this.activationReady) {
      this.pendingWant = want;
      return;
    }
    this.publishActivation(want);
  }

  // Builds the activation JSON the host forwards to the managed side. The payload is opaque to
  // the host: uri/action come straight from the want, parameters is the want's parameter record
  // serialized as a JSON string (empty when absent or not serializable) and linkHosts is the
  // packaging's https allow-list. sequence increases per handed-over want, so a re-delivered or
  // out-of-order activation is recognizable on the managed side.
  private buildActivation(want: Want): string {
    const uri: string = typeof want.uri === 'string' ? want.uri : '';
    const action: string = typeof want.action === 'string' ? want.action : '';
    let parameters: string = '';
    if (want.parameters !== undefined && want.parameters !== null) {
      try {
        parameters = JSON.stringify(want.parameters);
      } catch (parameterError) {
        hilog.warn(DOMAIN, TAG, 'want parameters are not serializable: %{public}s', (parameterError as Error).message);
      }
    }
    this.launchSequence++;
    return JSON.stringify({
      uri: uri,
      action: action,
      parameters: parameters,
      linkHosts: this.linkHosts,
      sequence: this.launchSequence,
    });
  }

  private publishActivation(want: Want): void {
    const payload: string = this.buildActivation(want);
    // Activation evidence (T19): the want that reached the ability is logged with its delivery
    // stage (cold = the onCreate want bootstrap hands over before startApp, hot = every onNewWant
    // while the app runs), the sequence the managed side deduplicates on and the host's answer
    // (1 = delivered to the managed listener, 0 = queued, no listener yet), so a device log
    // shows both delivery paths and whether the runtime had registered its callback.
    const uri: string = typeof want.uri === 'string' ? want.uri : '';
    const action: string = typeof want.action === 'string' ? want.action : '';
    hilog.info(DOMAIN, TAG, 'activation %{public}s seq=%{public}d uri=%{public}s action=%{public}s',
      this.activationStage, this.launchSequence, uri.length > 256 ? uri.substring(0, 256) : uri,
      action.length > 128 ? action.substring(0, 128) : action);
    this.hostCall('notifyActivation', typeof host !== 'undefined' && typeof host.notifyActivation === 'function', (): void => {
      const rc: number = host.notifyActivation(payload) as number;
      hilog.info(DOMAIN, TAG, 'activation %{public}s seq=%{public}d delivered=%{public}d',
        this.activationStage, this.launchSequence, rc);
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

  // Forwards the system font-size scale (the user's font size setting) to the managed side,
  // which applies it to every text metric and re-arranges. The host replays the last value to a
  // managed listener that registers later, so the startup report cannot be lost.
  private reportFontScale(scale: number): void {
    this.hostCall('notifyFontScale', typeof host !== 'undefined' && typeof host.notifyFontScale === 'function', (): void => {
      host.notifyFontScale(scale);
    });
  }

  // System configuration changes: the font size setting is the one the managed text pipeline
  // follows (the colour mode has its own AppStorage watch in the page).
  onConfigurationUpdated(config: Configuration): void {
    if (typeof config.fontSizeScale === 'number') {
      this.reportFontScale(config.fontSizeScale);
    }
  }

  private async bootstrap(): Promise<void> {
    const raw = await this.context.resourceManager.getRawFileContent('app.json');
    const config = JSON.parse(decodeUtf8(raw)) as AppConfig;
    this.linkHosts = Array.isArray(config.linkHosts) ? config.linkHosts : [];

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
    // Deep link: hand the cold-start want to the host before startApp. The host queues the
    // payload when the managed activation callback is not registered yet (the runtime is only
    // starting) and flushes it on registration, so onCreate's want cannot race the launch. Once
    // this point is passed, onNewWant delivers directly.
    if (this.pendingWant !== null) {
      this.activationStage = 'cold';
      this.publishActivation(this.pendingWant);
      this.pendingWant = null;
    }
    this.activationReady = true;
    const started: boolean = this.hostCall('startApp', typeof host !== 'undefined' && typeof host.startApp === 'function', (): void => {
      host.startApp(appDir, config.assembly, context);
    });
    if (!started) {
      hilog.error(DOMAIN, TAG, 'managed app %{public}s not started: host unavailable', config.assembly);
      return;
    }
    this.started = true;
    hilog.info(DOMAIN, TAG, 'managed app %{public}s started from %{public}s', config.assembly, appDir);
  }
}
