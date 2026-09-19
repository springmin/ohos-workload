// ArkUI page hosting native (.NET-rendered) content.
//
// Compiled by the ArkTS toolchain (scripts/build-arkts-shell.sh -> dist/ets/modules.abc)
// and packaged with -p:OpenHarmonyUIPage=pages/Index -p:OpenHarmonyArktsModulesAbc=...
//
// The XComponent (surface type) is bound to libopenharmonyhost.so: the framework delivers
// its OHNativeWindow* through the native XComponent callbacks, which the host forwards to
// the managed app (Microsoft.OpenHarmony.Hosting.OpenHarmonyBridge.SurfaceChanged) as the
// rendering target for Skia/MAUI. The ContentSlot next to it hosts native ArkUI nodes that
// managed code attaches through OpenHarmonyBridge.NodeContent.
import { NodeContent } from '@ohos.arkui.node';
import abilityAccessCtrl, { Permissions } from '@ohos.abilityAccessCtrl';
import cameraPicker from '@ohos.multimedia.cameraPicker';
import camera from '@ohos.multimedia.camera';
import { calendarManager } from '@kit.CalendarKit';
import { contact } from '@kit.ContactsKit';
import common from '@ohos.app.ability.common';
import Want from '@ohos.app.ability.Want';
import fileIo from '@ohos.file.fs';
import notificationManager from '@ohos.notificationManager';
import host from 'libopenharmonyhost.so';
import picker from '@ohos.file.picker';
import fs from '@ohos.file.fs';
import util from '@ohos.util';
import web_webview from '@ohos.web.webview';
import window from '@ohos.window';

// Menu bridge: the managed side publishes the current page's menu bars (MenuBarItem/MenuFlyout)
// as a flat table through the host. registerMenuChangedSink fires after every commit - including
// the empty table that hides the menu - and the table is pulled back with menuCount/menuItem.
// The rows are rendered by an ArkUI bindMenu below and a tap goes back to the managed item
// through host.notifyMenuAction(index).
interface HostMenuItem {
  text: string;
  enabled: boolean;
}

@Entry
@Component
struct Index {
  private content: NodeContent = new NodeContent();

  @State inputText: string = '';
  @State webVisible: boolean = false;
  @State menuItems: HostMenuItem[] = [];
  // JavaScript bridge: set once the dotnetHost proxy was registered on the attached controller.
  private dotNetHostRegistered: boolean = false;
  // App theme: 'colorMode' is an ArkUI environment property that the framework keeps in
  // AppStorage and refreshes when the device switches between light and dark. The watch
  // forwards every change to the managed side through host.notifyTheme(isDark).
  @StorageProp('colorMode') @Watch('onColorModeChanged') colorMode: ColorMode = ColorMode.LIGHT;
  private webController: web_webview.WebviewController = new web_webview.WebviewController();
  private controller: TextInputController = new TextInputController();

  // Forwards the current device colour mode (1 = dark, 0 = light) to the managed app.
  private reportTheme(): void {
    try {
      const mode: ColorMode | undefined = AppStorage.get<ColorMode>('colorMode');
      host.notifyTheme(mode === ColorMode.DARK ? 1 : 0);
    } catch (themeError) {
      // A host library without the theme export leaves the managed default in place.
    }
  }

  private onColorModeChanged(): void {
    this.reportTheme();
  }

  // Reads the host's current menu table into @State (empty when the sink is unavailable).
  private pullMenu(): void {
    try {
      const count: number = host.menuCount() as number;
      const items: HostMenuItem[] = [];
      for (let i = 0; i < count; i++) {
        items.push(host.menuItem(i) as HostMenuItem);
      }
      this.menuItems = items;
    } catch (menuError) {
      this.menuItems = [];
    }
  }

  // Maps the table to ArkUI menu elements; the managed enabled flag is carried over so ArkUI
  // greys out disabled rows and does not run their action.
  private buildMenuElements(): MenuElement[] {
    const elements: MenuElement[] = [];
    for (let i = 0; i < this.menuItems.length; i++) {
      const index: number = i;
      const item: HostMenuItem = this.menuItems[i];
      const element: MenuElement = {
        value: item.text,
        enabled: item.enabled,
        action: (): void => {
          host.notifyMenuAction(index);
        }
      };
      elements.push(element);
    }
    return elements;
  }

  // JavaScript bridge: registers the dotnetHost proxy that page scripts call to reach the
  // managed side. registerJavaScriptProxy needs the controller attached to the Web component
  // (BusinessError 17100001 otherwise), so onControllerAttached calls this.
  private registerDotNetHost(): void {
    if (this.dotNetHostRegistered) {
      return;
    }
    try {
      this.webController.registerJavaScriptProxy({
        postMessage: (payload: string): void => {
          host.notifyJsMessage(payload);
        }
      }, 'dotnetHost', ['postMessage']);
      this.dotNetHostRegistered = true;
    } catch (proxyError) {
      console.error(`[maui] dotnetHost proxy registration failed: ${(proxyError as Error).message}`);
    }
  }

  // Registered proxies appear on the next page load, so the documented window.__ohosDotNet
  // alias is (re)published after every load (best effort; a page that cannot run it still
  // keeps the dotnetHost global provided by the proxy registration).
  private injectDotNetHostAlias(): void {
    try {
      this.webController.runJavaScript('window.__ohosDotNet = window.dotnetHost;', () => {
        // The alias is best-effort; an error leaves the page without the alias only.
      });
    } catch (aliasError) {
      // A page that rejects the injection script must not take the app down.
    }
  }

  aboutToAppear(): void {
    // 2 = foreground; the native host forwards it to the managed bridge.
    host.notifyLifecycle(2);
    host.setNodeContent(this.content);
    // App theme: bind the device colour mode into AppStorage (idempotent; the recommended
    // startup point is the first page's aboutToAppear in this shell) and report the initial
    // light/dark state to the managed side. Later changes arrive through onColorModeChanged.
    Environment.envProp<ColorMode>('colorMode', ColorMode.LIGHT);
    this.reportTheme();
    // Essentials (vibration/permissions/geolocation/pickers/connectivity/launcher) need the
    // matching SDK kits, which are not part of this minimal shell project's compilation set yet
    // (see docs/plans/2026-09-18-ohos-arkts-essentials-bridge-plan.md). The sinks stay
    // registered and report "unavailable" so the managed side behaves deterministically.
    // Essentials: vibration / keystore sinks stay degradable until the SDK declarations are
    // surfaced to this project's compilation. Official reference for the remaining step:
    // applications_app_samples (OpenHarmony-v6.1-Release) uses numeric SDK versions
    // (compileSdkVersion: 23, compatibleSdkVersion: 20, targetSdkVersion: 23) and
    // buildOption.strictMode { caseSensitiveCheck: true, useNormalizedOHMUrl: true } - the
    // strictMode block is now emitted, the numeric-version + matching staged SDK layout is the
    // next candidate. Verified snippet lives in the ArkTS Essentials plan.
    // Safe area: report the system avoid area so the managed layout can inset its content.
    window.getLastWindow(getContext(this)).then((win) => {
      const area = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
      host.notifyAvoidArea(area.topRect.height, area.bottomRect.height,
                           area.leftRect.width, area.rightRect.width);
    }).catch(() => {
      // Window information is optional.
    });

    // WebView: a hidden ArkWeb component that the managed WebView handler drives.
    host.registerWebSink((op: string, arg: string) => {
      try {
        if (op === 'show') {
          this.webVisible = true;
        } else if (op === 'hide') {
          this.webVisible = false;
        } else if (op === 'load') {
          this.webVisible = true;
          this.webController.loadUrl(arg);
        } else if (op === 'data') {
          this.webVisible = true;
          this.webController.loadData(arg, 'text/html', 'UTF-8');
        } else if (op === 'back') {
          if (this.webController.accessBackward()) {
            this.webController.backward();
          }
        }
      } catch (error) {
        // Web errors never take the app down.
      }
    });

    // JavaScript bridge: the managed side evaluates scripts through ohos_host_web_eval; the
    // runJavaScript result (or its error) travels back to the awaiting request.
    host.registerWebEvalSink((script: string, requestId: number): void => {
      try {
        this.webController.runJavaScript(script, (err, result) => {
          host.notifyWebEvalResult(requestId, result || '', err ? 1 : 0);
        });
      } catch (evalError) {
        host.notifyWebEvalResult(requestId, '', 1);
      }
    });

    // File/media pickers: the managed side asks for the system picker; the chosen file's name
    // and bytes travel back as base64 (all kinds use the document picker, so the shell needs no
    // extra UI component).
    host.registerPickerSink(async (requestId: number, kind: number) => {
      if (kind === 3 || kind === 4) {
        try {
          const mediaType = kind === 3 ? cameraPicker.PickerMediaType.PHOTO : cameraPicker.PickerMediaType.VIDEO;
          const picked = await cameraPicker.pick(getContext(this), [mediaType], {
            cameraPosition: camera.CameraPosition.CAMERA_POSITION_BACK,
          });
          const captureUri: string = picked.resultUri;
          const captureName: string = captureUri.substring(captureUri.lastIndexOf('/') + 1);
          const captureFile = fileIo.openSync(captureUri, fileIo.OpenMode.READ_ONLY);
          const captureBuffer = new ArrayBuffer(fileIo.statSync(captureUri).size);
          fileIo.readSync(captureFile.fd, captureBuffer);
          fileIo.closeSync(captureFile);
          const captureBase64 = new util.Base64Helper().encodeToStringSync(new Uint8Array(captureBuffer));
          host.notifyPickerResult(requestId, 0, captureName, captureBase64);
        } catch (captureError) {
          console.error(`camera capture failed: ${captureError.message}`);
          host.notifyPickerResult(requestId, -1, '', '');
        }
        return;
      }
        host.registerNotificationSink((notificationId: number, notificationTitle: string, notificationText: string): void => {
            notificationManager.publish({
                id: notificationId,
                content: {
                    notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
                    normal: { title: notificationTitle, text: notificationText, additionalText: '' }
                }
            }).catch((publishError: Error): void => {
                console.error(`notification publish failed: ${publishError.message}`);
            });
        });
      try {
        const documentPicker = new picker.DocumentViewPicker();
        const uris = await documentPicker.select({ maxSelectNumber: 1 });
        if (!uris || uris.length === 0) {
          host.notifyPickerResult(requestId, -1, '', '');
          return;
        }
        const uri = uris[0];
        const file = fs.openSync(uri, fs.OpenMode.READ_ONLY);
        const stat = fs.statSync(file.fd);
        const buffer = new ArrayBuffer(stat.size);
        fs.readSync(file.fd, buffer);
        fs.closeSync(file);
        const helper = new util.Base64Helper();
        const encoded = helper.encodeToStringSync(new Uint8Array(buffer));
        const name = uri.substring(uri.lastIndexOf('/') + 1);
        host.notifyPickerResult(requestId, 0, name, encoded);
      } catch (error) {
        host.notifyPickerResult(requestId, -1, '', '');
      }
    });

    host.registerVibrationSink((durationMs: number) => {
    });

    // SecureStorage: the managed side asks HUKS to generate/encrypt/decrypt.
    // The keystore kit is not part of this minimal shell project's dependencies/syscap yet, so
    // every request is answered with rc=-1 and the managed side uses its documented file
    // fallback. Enabling the real path means adding the universal keystore kit to the shell
    // project (see docs/plans/2026-09-18-ohos-secure-storage-huks-plan.md).
    host.registerKeystoreSink((requestId: number, op: string, alias: string, data: string) => {
      host.notifyKeystoreResult(requestId, -1, '');
    });

    // TextToSpeech: speak requests arrive from the managed side (ohos_host_tts_speak). The
    // OpenHarmony SDK this shell compiles against has no speech synthesis module: both
    // '@kit.CoreSpeechKit' and '@ohos.ai.tts' fail with "Cannot find module ... or its
    // corresponding type declarations", so - like the keystore sink above - the request is
    // answered with "unavailable" (rc=-1) and the managed side degrades (it never throws).
    // With a Speech Kit SDK: create the engine once (textToSpeech.createEngine), call
    // engine.speak(text, ...) and answer host.notifyTtsResult(requestId, 0) when it finishes.
    host.registerTtsSink((requestId: number, text: string, locale: string): void => {
      host.notifyTtsResult(requestId, -1);
    });

    // Contacts (platform extra): the managed side asks through ohos_host_contacts_query. The
    // sink requires ohos.permission.READ_CONTACTS, queries the Contacts Kit
    // (@kit.ContactsKit -> contact.queryContacts) and answers with "name\tphone" lines, capped
    // at the managed limit. A missing kit or a denied permission answers code -1, which the
    // managed side reports as IsSupported == false instead of guessing.
    host.registerContactsSink(async (requestId: number, namePrefix: string, limit: number): Promise<void> => {
      try {
        const context = getContext(this) as common.UIAbilityContext;
        const permissions: Permissions[] = ['ohos.permission.READ_CONTACTS'];
        const atManager = abilityAccessCtrl.createAtManager();
        const granted = await atManager.requestPermissionsFromUser(context, permissions);
        if (granted.authResults.length === 0 || granted.authResults[0] !== 0) {
          host.notifyContactsResult(requestId, -1, '');
          return;
        }
        const all = await contact.queryContacts(context);
        const rows: string[] = [];
        for (const item of all) {
          const name: string = item.name && item.name.fullName ? item.name.fullName : '';
          if (namePrefix.length > 0 && !name.startsWith(namePrefix)) {
            continue;
          }
          const phone: string = item.phoneNumbers && item.phoneNumbers.length > 0
            ? item.phoneNumbers[0].phoneNumber : '';
          rows.push(`${name}\t${phone}`);
          if (rows.length >= limit) {
            break;
          }
        }
        host.notifyContactsResult(requestId, 0, rows.join('\n'));
      } catch (contactsError) {
        console.error(`[maui] contacts query failed: ${(contactsError as Error).message}`);
        host.notifyContactsResult(requestId, -1, '');
      }
    });

    // Calendar (platform extra): the managed side asks through ohos_host_calendar_list (op 0,
    // arg1 = days) or ohos_host_calendar_add (op 1, arg1 = title, arg2/arg3 = ISO start/end).
    // Both require the runtime calendar permissions and run through the Calendar Kit
    // (@kit.CalendarKit -> calendarManager.getCalendar -> getEvents / addEvent). A missing kit
    // or a denied permission answers code -1 (managed IsSupported == false).
    host.registerCalendarSink(async (requestId: number, op: number, arg1: string, arg2: string, arg3: string): Promise<void> => {
      try {
        const context = getContext(this) as common.UIAbilityContext;
        const permissions: Permissions[] = op === 0
          ? ['ohos.permission.READ_CALENDAR']
          : ['ohos.permission.READ_CALENDAR', 'ohos.permission.WRITE_CALENDAR'];
        const atManager = abilityAccessCtrl.createAtManager();
        const granted = await atManager.requestPermissionsFromUser(context, permissions);
        for (let i = 0; i < granted.authResults.length; i++) {
          if (granted.authResults[i] !== 0) {
            host.notifyCalendarResult(requestId, -1, '');
            return;
          }
        }
        const manager = calendarManager.getCalendarManager(context);
        const calendar = await manager.getCalendar();
        if (op === 0) {
          const days: number = Number.parseInt(arg1, 10) || 0;
          const now: number = Date.now();
          const end: number = now + days * 24 * 60 * 60 * 1000;
          const events = await calendar.getEvents(calendarManager.EventFilter.filterByTime(now, end));
          const rows: string[] = [];
          for (const item of events) {
            const title: string = item.title ? item.title : '';
            rows.push(`${title}\t${new Date(item.startTime).toISOString()}\t${new Date(item.endTime).toISOString()}`);
          }
          host.notifyCalendarResult(requestId, 0, rows.join('\n'));
          return;
        }
        const event: calendarManager.Event = {
          type: calendarManager.EventType.NORMAL,
          title: arg1,
          startTime: Date.parse(arg2),
          endTime: Date.parse(arg3),
        };
        await calendar.addEvent(event);
        host.notifyCalendarResult(requestId, 0, '');
      } catch (calendarError) {
        console.error(`[maui] calendar request failed: ${(calendarError as Error).message}`);
        host.notifyCalendarResult(requestId, -1, '');
      }
    });

    // Launcher/Browser/Share: managed requests arrive through ohos_host_ability_start. kind 0
    // opens a uri (implicit viewData Want), kind 1 shares plain text (implicit sendData Want),
    // kind 2 is the availability probe (never launches). The UIAbilityContext owns the actual
    // startAbility call; a rejected launch is logged, and only the dispatch status (true when the
    // request was handed to the system) is reported back to the managed side.
    // Plain text has no wantConstant key in this SDK (Share Kit/systemShare is not part of it),
    // so the text travels under 'ohos.extra.param.key.content', the key used by the
    // pre-Share-Kit samples for ohos.want.action.sendData.
    host.registerAbilitySink((kind: number, uri: string, text: string): boolean => {
      try {
        const context = getContext(this) as common.UIAbilityContext;
        if (kind === 2) {
          return context !== undefined && context !== null;
        }
        const want: Want = new Want();
        if (kind === 1) {
          want.action = 'ohos.want.action.sendData';
          want.type = 'text/plain';
          want.parameters = { 'ohos.extra.param.key.content': text };
        } else {
          want.action = 'ohos.want.action.viewData';
          want.uri = uri;
        }
        context.startAbility(want).then((): void => {
          console.info(`[maui] ability start dispatched: kind=${kind}`);
        }).catch((startError: Error): void => {
          console.error(`[maui] ability start failed: kind=${kind} ${startError.message}`);
        });
        return true;
      } catch (startError) {
        console.error(`[maui] ability start threw: ${(startError as Error).message}`);
        return false;
      }
    });

    // The managed Entry asks for the soft keyboard through this sink.
    host.registerTextInputSink((show: number) => {
      if (show === 1) {
        this.controller.caretPosition(0);
        focusControl.requestFocus('ohos_dotnet_input');
      } else {
        focusControl.requestFocus('ohos_dotnet_surface');
      }
    });

    // Menus: pull the initial table, then refresh on every commit from the managed side.
    // A host library without the menu exports degrades to no menu instead of failing the page.
    try {
      host.registerMenuChangedSink((count: number): void => {
        console.info(`[maui] menu table changed: ${count} rows`);
        this.pullMenu();
      });
      this.pullMenu();
    } catch (menuError) {
      this.menuItems = [];
    }
  }

  build() {
    Stack() {
      // ArkWeb: hidden until the managed WebView asks for it.
      Web({ src: '', controller: this.webController })
        .visibility(this.webVisible ? Visibility.Visible : Visibility.None)
        // The controller is attached here; registering the dotnetHost proxy any earlier fails
        // with BusinessError 17100001 (controller not associated with a Web component).
        .onControllerAttached(() => {
          this.registerDotNetHost();
        })
        .onPageBegin((event) => {
          host.notifyWebEvent('started', event ? event.url : '');
        })
        .onPageEnd((event) => {
          host.notifyWebEvent('finished', event ? event.url : '');
          this.injectDotNetHostAlias();
        })

      // Text entry bridge: the managed Entry reads what is typed here.
      TextInput({ text: this.inputText, placeholder: 'type here', controller: this.controller })
        .id('ohos_dotnet_input')
        .height(56)
        .position({ x: 0, y: 0 })
        .onChange((value: string) => {
          this.inputText = value;
          host.notifyTextInput(value);
        })
        .onSubmit(() => {
          // The managed Entry/SearchBar raises Completed/SearchButtonPressed.
          host.notifyTextSubmitted(this.inputText);
        })

      XComponent({
        id: 'ohos_dotnet_surface',
        type: XComponentType.SURFACE,
        libraryname: 'openharmonyhost',
      })
        .onLoad(() => {
          // Binds the native XComponent so libopenharmonyhost receives surface callbacks.
          host.registerXComponent();
        })
        .width('100%')
        .height('100%')

      ContentSlot(this.content)

      // Menu handle: only present while the managed page publishes menu bars. The ArkUI menu is
      // bound to the flat element array; choosing a row calls host.notifyMenuAction(index).
      if (this.menuItems.length > 0) {
        Button('Menu')
          .align(Alignment.TopEnd)
          .margin({ top: 8, right: 8 })
          .height(40)
          .fontSize(18)
          .bindMenu(this.buildMenuElements())
      }
    }
    .width('100%')
    .height('100%')
  }
}
