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
import cameraPicker from '@ohos.multimedia.cameraPicker';
import camera from '@ohos.multimedia.camera';
import fileIo from '@ohos.file.fs';
import notificationManager from '@ohos.notificationManager';
import host from 'libopenharmonyhost.so';
import picker from '@ohos.file.picker';
import fs from '@ohos.file.fs';
import util from '@ohos.util';
import web_webview from '@ohos.web.webview';
import window from '@ohos.window';

@Entry
@Component
struct Index {
  private content: NodeContent = new NodeContent();

  @State inputText: string = '';
  @State webVisible: boolean = false;
  private webController: web_webview.WebviewController = new web_webview.WebviewController();
  private controller: TextInputController = new TextInputController();

  aboutToAppear(): void {
    // 2 = foreground; the native host forwards it to the managed bridge.
    host.notifyLifecycle(2);
    host.setNodeContent(this.content);
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

    // The managed Entry asks for the soft keyboard through this sink.
    host.registerTextInputSink((show: number) => {
      if (show === 1) {
        this.controller.caretPosition(0);
        focusControl.requestFocus('ohos_dotnet_input');
      } else {
        focusControl.requestFocus('ohos_dotnet_surface');
      }
    });
  }

  build() {
    Stack() {
      // ArkWeb: hidden until the managed WebView asks for it.
      Web({ src: '', controller: this.webController })
        .visibility(this.webVisible ? Visibility.Visible : Visibility.None)
        .onPageBegin((event) => {
          host.notifyWebEvent('started', event ? event.url : '');
        })
        .onPageEnd((event) => {
          host.notifyWebEvent('finished', event ? event.url : '');
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
    }
    .width('100%')
    .height('100%')
  }
}
