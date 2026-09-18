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
import host from 'libopenharmonyhost.so';

@Entry
@Component
struct Index {
  private content: NodeContent = new NodeContent();

  @State inputText: string = '';
  private controller: TextInputController = new TextInputController();

  aboutToAppear(): void {
    // 2 = foreground; the native host forwards it to the managed bridge.
    host.notifyLifecycle(2);
    host.setNodeContent(this.content);
    // Essentials (vibration/permissions/geolocation/pickers/connectivity/launcher) need the
    // matching SDK kits, which are not part of this minimal shell project's compilation set yet
    // (see docs/plans/2026-09-18-ohos-arkts-essentials-bridge-plan.md). The sinks stay
    // registered and report "unavailable" so the managed side behaves deterministically.
    // Essentials: vibration / keystore sinks.
    // The SDK's system modules (@ohos.vibrator, @ohos.security.huks via @kit.*) do not resolve
    // in this minimal hvigor project yet: the loader registers the SDK's api/arkts/kits as
    // system module paths (verified in ets-loader/main.js) and the kit_configs map the names
    // correctly, but the bindings still come back unresolved, so the sink reports
    // "unavailable" and the managed side uses its documented fallback. See the HUKS plan and
    // the ArkTS Essentials plan for the exact findings and next step (compare against a
    // DevEco-generated project's loader/plugin versions).
    host.registerVibrationSink((durationMs: number) => {
    });

    // SecureStorage: the managed side asks HUKS to generate/encrypt/decrypt.
    // The keystore kit is not part of this minimal shell project's dependencies/syscap yet, so
    // every request is answered with rc=-1 and the managed side uses its documented file
    // fallback. Enabling the real path means adding the universal keystore kit to the shell
    // project (see docs/plans/2026-09-18-ohos-secure-storage-huks-plan.md).
    host.registerKeystoreSink((requestId: number, op: string, alias: string, data: string) => {
      try {
        const options = {
          properties: [
            { tag: huks.HuksTag.HUKS_TAG_ALGORITHM, value: huks.HuksKeyAlg.HUKS_ALG_AES },
            { tag: huks.HuksTag.HUKS_TAG_KEY_SIZE, value: huks.HuksKeySize.HUKS_AES_KEY_SIZE_256 },
            { tag: huks.HuksTag.HUKS_TAG_PURPOSE, value: huks.HuksKeyPurpose.HUKS_KEY_PURPOSE_ENCRYPT | huks.HuksKeyPurpose.HUKS_KEY_PURPOSE_DECRYPT },
            { tag: huks.HuksTag.HUKS_TAG_PADDING, value: huks.HuksKeyPadding.HUKS_PADDING_NONE },
            { tag: huks.HuksTag.HUKS_TAG_BLOCK_MODE, value: huks.HuksCipherMode.HUKS_MODE_GCM },
          ],
        };
        if (op === 'generate') {
          huks.generateKeyItem(alias, options, (err) => { host.notifyKeystoreResult(requestId, err ? -1 : 0, ''); });
        } else if (op === 'encrypt') {
          huks.encryptData(alias, options, (err, result) => { host.notifyKeystoreResult(requestId, err ? -1 : 0, ''); });
        } else if (op === 'decrypt') {
          huks.decryptData(alias, options, (err, result) => { host.notifyKeystoreResult(requestId, err ? -1 : 0, ''); });
        } else {
          host.notifyKeystoreResult(requestId, -1, '');
        }
      } catch (error) {
        host.notifyKeystoreResult(requestId, -1, '');
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
  }

  build() {
    Stack() {
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
