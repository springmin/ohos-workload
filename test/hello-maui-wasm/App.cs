// B2 demo application: one page whose WebView loads a staged Blazor WebAssembly site.
//
// Flow on device:
//   1. the pack staged the site under <AppDir>/wasmsite (pack target _OpenHarmonyStageWasmSite);
//   2. CreateWindow arms the shell for the site origin: RegisterWasmSite sends the "blazor"
//      registration with mode "wasm", so the shell serves https://blazorwasm.local/ from that
//      payload root with the normal MIME types and injects no Blazor Hybrid bootstrap;
//   3. the WebView's Source is that origin; the shell's onInterceptRequest answers every request
//      (index.html, _framework/blazor.webassembly*.js, dotnet.js, the .wasm payloads) from the
//      staged root and the site boots itself.
//
// The console markers the site logs (BLZ_BOOT on window load, BLZ_RENDERED after the first
// Blazor render) are forwarded by the shell's Web onConsole to hilog under the BlazorWebHost
// tag, which is the machine verdict the device run greps.
using Microsoft.Maui;
using Microsoft.Maui.Controls;
using Microsoft.Maui.Platform;

namespace HelloMauiWasm;

public sealed class App : Application
{
    protected override Window CreateWindow(IActivationState? activationState)
    {
        // Arm the shell before the WebView connects. On device this returns true; off-device
        // (no app context) it returns false and the page still builds for the suite.
        bool registered = OpenHarmonyWebViewHandler.RegisterWasmSite();
        var status = new Label
        {
            Text = registered
                ? $"wasm site registered; loading {OpenHarmonyWebViewHandler.WasmSiteOrigin}"
                : "wasm site registration skipped (no app payload context)",
            FontSize = 20,
        };
        var web = new WebView
        {
            Source = OpenHarmonyWebViewHandler.WasmSiteOrigin,
            HeightRequest = 720,
        };
        return new Window(new ContentPage
        {
            Title = "MAUI + Blazor WASM on OpenHarmony",
            Content = new VerticalStackLayout
            {
                Padding = 24,
                Spacing = 12,
                Children =
                {
                    new Label { Text = "MAUI WebView + Blazor WASM", FontSize = 36 },
                    status,
                    web,
                },
            },
        });
    }
}
