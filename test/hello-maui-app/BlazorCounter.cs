// S1: the BlazorWebView demo component, written against ComponentBase/RenderTreeBuilder instead
// of Razor markup. The project has no Razor SDK (it compiles the platform slice sources directly
// on Microsoft.NET.Sdk), so a .razor file would not compile; the EventCallback created here is
// exactly what @onclick generates, so a button click exercises the same round trip:
//   ArkWeb click -> window.external.sendMessage -> dotnetHost -> OpenHarmonyWebViewHandler.JsMessage
//   -> OpenHarmonyWebViewManager.MessageReceived -> event callback -> render batch ->
//   window.__dispatchMessageCallback -> DOM update (the count below the button changes).
using Microsoft.AspNetCore.Components;
using Microsoft.AspNetCore.Components.Rendering;

namespace HelloMauiApp;

/// <summary>
/// Tiny Blazor component attached to <c>#app</c> in <c>wwwroot/index.html</c> by the demo's
/// <see cref="Microsoft.AspNetCore.Components.WebView.Maui.BlazorWebView"/> (see App.cs).
/// </summary>
public sealed class BlazorCounter : ComponentBase
{
    private int _count;

    protected override void BuildRenderTree(RenderTreeBuilder builder)
    {
        builder.OpenElement(0, "h2");
        builder.AddContent(1, "BlazorWebView component");
        builder.CloseElement();

        builder.OpenElement(2, "p");
        builder.AddContent(3, $"count: {_count} (each click round-trips through the shell)");
        builder.CloseElement();

        builder.OpenElement(4, "button");
        builder.AddAttribute(5, "onclick", EventCallback.Factory.Create(this, Increment));
        builder.AddContent(6, "Blazor click");
        builder.CloseElement();
    }

    private void Increment() => _count++;
}
